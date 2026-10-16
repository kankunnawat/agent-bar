import AgentBarCore
import Foundation
import Observation

struct AccountRow: Identifiable {
    let account: Account
    var state: AccountState
    var id: String { account.id }
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class UsageStore {
    private(set) var rows: [AccountRow] = []
    private(set) var statuses: [Provider: ProviderStatus] = [:]
    private(set) var lastRefreshed: Date?
    private(set) var isRefreshing = false
    private(set) var config: AppConfig
    private(set) var costByAccount: [String: UsageCost] = [:]
    private(set) var historyByAccount: [String: [HistoryEntry]] = [:]
    /// Per-account log-scan record cache, keyed by account id. Value type,
    /// snapshotted into each off-main scan task and merged back here.
    private var costCaches: [String: FileRecordCache] = [:]

    var onAlerts: (@Sendable @MainActor ([AlertEvent]) -> Void)?

    let configStore: ConfigStore
    private let transport: any HTTPTransport
    private let home: URL
    private let history: UsageHistoryStore
    private var alertEngine: AlertEngine
    private var retryAfterByAccount: [String: Date] = [:]
    private var loopTask: Task<Void, Never>?
    private var statusFetchedAt: Date?
    private var costFetchedAt: Date?
    private let tokenCache = ClaudeTokenCache()

    init(configStore: ConfigStore = ConfigStore(url: ConfigStore.defaultURL),
         transport: any HTTPTransport = URLSessionTransport(),
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.configStore = configStore
        self.transport = transport
        self.home = home
        self.history = UsageHistoryStore(home: home)
        let config = configStore.load()
        self.config = config
        self.alertEngine = AlertEngine(
            thresholdPercent: config.alerts.sessionThresholdPercent,
            weeklyThresholdPercent: config.alerts.weeklyThresholdPercent)
        reloadAccounts()
    }

    func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.reloadAccounts() // pick up account dirs created after launch
                await self.refreshNow()
                let interval = self.config.refreshIntervalSeconds
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func reloadAccounts() {
        var discovered = AccountDiscovery.discover(home: home)
        for manual in config.manualPaths
        where !discovered.contains(where: { $0.path == manual.path }) {
            discovered.append(DiscoveredAccount(provider: manual.provider, path: manual.path))
        }
        let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.state) })
        let accounts = discovered.map { d -> Account in
            let defaultLabel = (d.path as NSString).lastPathComponent
                .replacingOccurrences(of: ".\(d.provider.rawValue)-", with: "")
                .replacingOccurrences(of: ".\(d.provider.rawValue)", with: "default")
            var account = Account(provider: d.provider, path: d.path, label: defaultLabel, hidden: false)
            if let override = config.accounts[account.id] {
                if let label = override.label { account.label = label }
                if let hidden = override.hidden { account.hidden = hidden }
            }
            return account
        }
        .sorted { ($0.provider.rawValue, $0.label) < ($1.provider.rawValue, $1.label) } // stable base order
        rows = RowPresentation.ordered(accounts, order: config.accountOrder, pinned: config.pinnedAccountID)
            .map { AccountRow(account: $0, state: existing[$0.id] ?? Self.initialState(for: $0)) }
    }

    /// A signed-out Cursor row starts hidden rather than showing "loading"
    /// until the first refresh.
    private static func initialState(for account: Account) -> AccountState {
        account.provider == .cursor && CursorCredentials.isSignedOut(cursorDir: account.path) ? .signedOut : .loading
    }

    func updateConfig(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        alertEngine.thresholdPercent = config.alerts.sessionThresholdPercent
        alertEngine.weeklyThresholdPercent = config.alerts.weeklyThresholdPercent
        do { try configStore.save(config) } catch {
            Log.config.error("config save failed: \(error.localizedDescription, privacy: .public)")
        }
        reloadAccounts()
    }

    func refreshNow() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let now = Date()
        let visible = rows.filter { !$0.account.hidden }
        let homePath = home.path
        let transport = self.transport
        let cache = self.tokenCache
        retryAfterByAccount = retryAfterByAccount.filter { $0.value > now }
        let suppressed = retryAfterByAccount

        // Third tuple element: retry-after date when the account was rate limited.
        let results = await withTaskGroup(of: (String, AccountState, Date?).self) { group in
            for row in visible {
                if suppressed[row.id] != nil {
                    continue // keep previous state while rate-limit suppressed
                }
                let account = row.account
                group.addTask {
                    await Self.fetchState(
                        for: account, homePath: homePath, transport: transport, now: now, cache: cache)
                }
            }
            var collected: [String: (AccountState, Date?)] = [:]
            for await (id, state, retryAfter) in group { collected[id] = (state, retryAfter) }
            return collected
        }
        for index in rows.indices {
            guard let (state, retryAfter) = results[rows[index].id] else { continue }
            rows[index].state = state
            if let retryAfter { retryAfterByAccount[rows[index].id] = retryAfter }
        }
        await recordHistory(results: results, now: now)
        lastRefreshed = now
        Log.fetch.debug("refresh cycle: \(visible.count) accounts")

        // Status pages every 5 minutes.
        if statusFetchedAt.map({ now.timeIntervalSince($0) > 300 }) ?? true {
            statusFetchedAt = now
            for provider in Provider.allCases {
                statuses[provider] = await StatusFetcher.fetch(provider: provider, transport: transport)
            }
        }

        await scanCostsIfDue(visible: visible, now: now)

        if config.alerts.enabled {
            let alertRows = shownRows.map { (account: $0.account, state: $0.state) }
            let events = alertEngine.evaluate(alertRows, now: now)
            if !events.isEmpty { onAlerts?(events) }
        }
    }

    /// Persist worst-window percents for accounts this cycle actually refreshed
    /// (suppressed/stale rows record nothing; re-recording is max-idempotent).
    private func recordHistory(results: [String: (AccountState, Date?)], now: Date) async {
        for (id, result) in results {
            guard case .ok(let snap) = result.0 else { continue }
            historyByAccount[id] = await history.record(
                accountID: id,
                session: snap.worstSession?.usedPercent,
                weekly: snap.worstWeekly?.usedPercent,
                at: now)
        }
    }

    /// Local-log cost scan every 10 minutes — logs change slowly, and the
    /// scan is filesystem work that must never block the UI, so it runs
    /// in nonisolated child tasks off the main actor.
    private func scanCostsIfDue(visible: [AccountRow], now: Date) async {
        guard costFetchedAt.map({ now.timeIntervalSince($0) > 600 }) ?? true else { return }
        costFetchedAt = now
        let accounts = visible.map(\.account)
        let caches = costCaches
        let results = await withTaskGroup(of: (String, UsageCost, FileRecordCache).self) { group in
            for account in accounts {
                let cache = caches[account.id] ?? [:]
                group.addTask {
                    let result = UsageCostFetcher.cost(for: account, now: now, cache: cache)
                    return (account.id, result.cost, result.cache)
                }
            }
            // swiftlint:disable:next large_tuple
            var collected: [(String, UsageCost, FileRecordCache)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        for (id, cost, cache) in results {
            costByAccount[id] = cost
            costCaches[id] = cache
        }
    }

    /// Returns (account id, new state, retry-after date when rate limited).
    private nonisolated static func fetchState(
        for account: Account, homePath: String, transport: any HTTPTransport, now: Date, cache: ClaudeTokenCache
    ) async -> (String, AccountState, Date?) { // swiftlint:disable:this large_tuple
        let state = await fetchStateOnly(
            for: account, homePath: homePath, transport: transport, now: now, cache: cache)
        return (account.id, state.0, state.1)
    }

    /// Serves a Claude token from the in-memory cache, reading the keychain only
    /// on a miss. The primary keychain path shells out to `/usr/bin/security`
    /// for silent reads; failed reads are still cached briefly so SecItem
    /// fallback prompts cannot repeat on every refresh tick.
    private nonisolated static func claudeCredentials(
        service: String, configDir: String, homeDir: String, now: Date, cache: ClaudeTokenCache
    ) async throws -> ClaudeCredentials {
        if let cached = await cache.serve(service: service, now: now) {
            switch cached {
            case .credentials(let creds):
                return creds
            case .failedRead(let error):
                throw error
            }
        }
        do {
            let creds = try ClaudeCredentials.load(configDir: configDir, homeDir: homeDir)
            await cache.store(service: service, credentials: creds, readAt: now)
            return creds
        } catch let error as FetchError {
            await cache.recordFailedRead(service: service, at: now, failure: error)
            throw error
        } catch {
            await cache.recordFailedRead(
                service: service, at: now, failure: .credentialsMissing(error.localizedDescription))
            throw error
        }
    }

    private nonisolated static func claudeState(
        account: Account, homePath: String, transport: any HTTPTransport, now: Date, cache: ClaudeTokenCache
    ) async throws -> AccountState {
        let service = ClaudeKeychain.serviceName(forConfigDir: account.path, homeDir: homePath)
        let creds = try await claudeCredentials(
            service: service, configDir: account.path, homeDir: homePath, now: now, cache: cache)
        if creds.isExpired(now: now) { return .stale("token expired — open claude to refresh") }
        do {
            var snap = try await ClaudeUsageFetcher.fetch(accessToken: creds.accessToken, transport: transport, now: now)
            // Identity proof for the hover card: which plan the resolved
            // credential belongs to, not just which config dir the row labels.
            snap.planLabel = creds.subscriptionType
            return .ok(snap)
        } catch FetchError.unauthorized {
            await cache.invalidate(service: service) // token rotated — re-read next cycle
            throw FetchError.unauthorized
        }
    }

    private nonisolated static func codexState(
        account: Account, transport: any HTTPTransport, now: Date
    ) async throws -> AccountState {
        var creds = try CodexCredentials.load(homeDir: account.path)
        let authURL = URL(fileURLWithPath: account.path).appendingPathComponent("auth.json")
        if creds.needsRefresh(now: now) {
            creds = try await CodexTokenRefresher.refresh(
                authFileURL: authURL, credentials: creds, transport: transport, now: now)
        }
        do {
            return .ok(try await CodexUsageFetcher.fetch(
                accessToken: creds.accessToken, accountID: creds.accountID, transport: transport, now: now))
        } catch FetchError.unauthorized where !creds.isAPIKey {
            // One retry after forced refresh on 401.
            creds = try await CodexTokenRefresher.refresh(
                authFileURL: authURL, credentials: creds, transport: transport, now: now)
            return .ok(try await CodexUsageFetcher.fetch(
                accessToken: creds.accessToken, accountID: creds.accountID, transport: transport, now: now))
        }
    }

    /// Read-only, like Claude: Cursor refreshes its own token.
    private nonisolated static func cursorState(
        account: Account, transport: any HTTPTransport, now: Date
    ) async throws -> AccountState {
        let creds = try CursorCredentials.load(cursorDir: account.path)
        if creds.isExpired(now: now) { return .stale("token expired — open cursor to refresh") }
        return .ok(try await CursorUsageFetcher.fetch(credentials: creds, transport: transport, now: now))
    }

    // Central error dispatch; splitting the catch chain hurts cohesion.
    // swiftlint:disable:next cyclomatic_complexity
    private nonisolated static func fetchStateOnly(
        for account: Account, homePath: String, transport: any HTTPTransport, now: Date, cache: ClaudeTokenCache
    ) async -> (AccountState, Date?) {
        do {
            switch account.provider {
            case .claude:
                return (try await claudeState(
                    account: account, homePath: homePath, transport: transport, now: now, cache: cache), nil)
            case .codex:
                return (try await codexState(account: account, transport: transport, now: now), nil)
            case .cursor:
                return (try await cursorState(account: account, transport: transport, now: now), nil)
            }
        } catch FetchError.unauthorized {
            switch account.provider {
            case .claude: return (.stale("token rejected — open claude to refresh"), nil)
            case .codex: return (.error("unauthorized — run codex login"), nil)
            case .cursor: return (.stale("token rejected — open cursor to refresh"), nil)
            }
        } catch FetchError.signedOut {
            return (.signedOut, nil)
        } catch FetchError.rateLimited(let retryAfter) {
            let when = retryAfter.map { Aggregation.countdown(to: $0, from: now) } ?? "later"
            return (.error("rate limited — retrying \(when)"), retryAfter ?? now.addingTimeInterval(300))
        } catch FetchError.keychainDenied {
            Log.keychain.error("keychain access denied for \(account.id, privacy: .public)")
            return (.error("keychain access denied — click to retry"), nil)
        } catch FetchError.credentialsMissing(let message) {
            Log.fetch.error("credentials missing for \(account.id, privacy: .public): \(message, privacy: .public)")
            return (.error(message), nil)
        } catch FetchError.conflictingCredentials(let message) {
            Log.keychain.error("credential conflict for \(account.id, privacy: .public): \(message, privacy: .public)")
            return (.error(message), nil)
        } catch FetchError.server(let code) {
            Log.fetch.error("server error \(code) for \(account.id, privacy: .public)")
            return (.error("server error (\(code))"), nil)
        } catch FetchError.decoding(let message) {
            Log.fetch.error("decode failure for \(account.id, privacy: .public): \(message, privacy: .public)")
            return (.error("unexpected response: \(message)"), nil)
        } catch {
            Log.fetch.error("fetch failed for \(account.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (.error(error.localizedDescription), nil)
        }
    }

    var shownRows: [AccountRow] {
        rows.filter { RowPresentation.isShown($0.account, state: $0.state) }
    }

    /// Combined API-rate estimate across visible accounts, for the footer.
    var totalCost: UsageCost {
        shownRows
            .compactMap { costByAccount[$0.id] }
            .reduce(.zero, +)
    }

    var iconState: IconState {
        IconStateBuilder.build(
            states: shownRows.map { ($0.id, $0.state) },
            pinnedID: config.pinnedAccountID)
    }

    var pinnedAccountID: String? { config.pinnedAccountID }

    func setPinned(id: String?) {
        updateConfig { $0.pinnedAccountID = id }
    }

    /// Visually reorders rows while a drag hovers a target; nothing is
    /// persisted until commitMove (a cancelled drag leaves the preview order
    /// on screen until the next config-driven rescan — accepted tradeoff).
    func previewMove(fromID: String, toID: String) {
        guard fromID != toID,
              let from = rows.firstIndex(where: { $0.id == fromID }),
              let to = rows.firstIndex(where: { $0.id == toID }) else { return }
        rows.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// Persists the order produced by previewMove when the drag drops.
    func commitMove() {
        let order = RowPresentation.persistedOrder(
            visual: rows.map(\.id), pinned: config.pinnedAccountID, previousOrder: config.accountOrder)
        updateConfig { $0.accountOrder = order }
    }

    /// Single-account refresh (used by "click to retry" rows).
    func refreshAccount(id: String) async {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let account = rows[index].account
        rows[index].state = .loading
        // Manual retry forces a fresh keychain read (e.g. after the user opened
        // Claude to refresh, or granted keychain access).
        if account.provider == .claude {
            let service = ClaudeKeychain.serviceName(forConfigDir: account.path, homeDir: home.path)
            await tokenCache.invalidate(service: service)
        }
        let (state, retryAfter) = await Self.fetchStateOnly(
            for: account, homePath: home.path, transport: transport, now: Date(), cache: tokenCache)
        if let refreshedIndex = rows.firstIndex(where: { $0.id == id }) {
            rows[refreshedIndex].state = state
            retryAfterByAccount[id] = retryAfter // nil clears stale rate-limit suppression
        }
        await recordHistory(results: [id: (state, retryAfter)], now: Date())
    }
}
