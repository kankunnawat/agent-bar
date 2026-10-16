import Foundation

public struct AccountOverride: Codable, Equatable, Sendable {
    public var label: String?
    public var hidden: Bool?
    public init(label: String? = nil, hidden: Bool? = nil) {
        self.label = label
        self.hidden = hidden
    }
}

public struct AlertsConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var sessionThresholdPercent: Double
    public var weeklyThresholdPercent: Double
    public init(enabled: Bool = true,
                sessionThresholdPercent: Double = 80,
                weeklyThresholdPercent: Double = 90) {
        self.enabled = enabled
        self.sessionThresholdPercent = sessionThresholdPercent
        self.weeklyThresholdPercent = weeklyThresholdPercent
    }

    /// The mark a window must cross before the app treats it as a warning —
    /// the same line the notification fires on, so the row, the hover card
    /// and the alert all agree on what "close to the limit" means.
    public func threshold(for kind: WindowKind) -> Double {
        switch kind {
        case .session: sessionThresholdPercent
        case .weekly: weeklyThresholdPercent
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled, sessionThresholdPercent, weeklyThresholdPercent
    }

    // Lenient decode: a missing key falls back to its default, so adding a
    // field never wipes an existing config's other values on upgrade
    // (mirrors AppConfig.init(from:)).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertsConfig()
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        self.sessionThresholdPercent =
            (try? c.decode(Double.self, forKey: .sessionThresholdPercent)) ?? d.sessionThresholdPercent
        self.weeklyThresholdPercent =
            (try? c.decode(Double.self, forKey: .weeklyThresholdPercent)) ?? d.weeklyThresholdPercent
    }
}

public struct ManualPath: Codable, Equatable, Sendable {
    public var provider: Provider
    public var path: String
    public init(provider: Provider, path: String) {
        self.provider = provider
        self.path = path
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var refreshIntervalSeconds: Int
    public var alerts: AlertsConfig
    public var accounts: [String: AccountOverride]
    public var manualPaths: [ManualPath]
    public var pinnedAccountID: String?
    public var accountOrder: [String]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, refreshIntervalSeconds, alerts, accounts, manualPaths, pinnedAccountID, accountOrder
    }

    public static let `default` = AppConfig(
        version: 1, refreshIntervalSeconds: 120, alerts: AlertsConfig(), accounts: [:],
        manualPaths: [], pinnedAccountID: nil, accountOrder: [])

    public init(version: Int, refreshIntervalSeconds: Int, alerts: AlertsConfig,
                accounts: [String: AccountOverride], manualPaths: [ManualPath],
                pinnedAccountID: String? = nil, accountOrder: [String] = []) {
        self.version = version
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.alerts = alerts
        self.accounts = accounts
        self.manualPaths = manualPaths
        self.pinnedAccountID = pinnedAccountID
        self.accountOrder = accountOrder
    }

    // Lenient decode: any missing key falls back to the default; a malformed
    // nested entry drops that entry only, never the whole collection.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.default
        self.version = (try? c.decode(Int.self, forKey: .version)) ?? d.version
        self.refreshIntervalSeconds = (try? c.decode(Int.self, forKey: .refreshIntervalSeconds)) ?? d.refreshIntervalSeconds
        self.alerts = (try? c.decode(AlertsConfig.self, forKey: .alerts)) ?? d.alerts
        let lossyAccounts = (try? c.decode([String: Lossy<AccountOverride>].self, forKey: .accounts)) ?? [:]
        self.accounts = lossyAccounts.compactMapValues(\.value)
        let lossyPaths = (try? c.decode([Lossy<ManualPath>].self, forKey: .manualPaths)) ?? []
        self.manualPaths = lossyPaths.compactMap(\.value)
        self.pinnedAccountID = try? c.decode(String.self, forKey: .pinnedAccountID)
        self.accountOrder = (try? c.decode([String].self, forKey: .accountOrder)) ?? d.accountOrder
    }
}

/// Decodes to nil instead of failing, so one bad entry can be dropped.
private struct Lossy<T: Codable>: Codable {
    let value: T?
    init(from decoder: Decoder) { value = try? T(from: decoder) }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

public struct ConfigStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentBar/config.json")
    }

    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return .default }
        return config
    }

    /// Merges known keys over the existing raw JSON so unknown top-level
    /// keys written by future versions survive a save from this version.
    public func save(_ config: AppConfig) throws {
        var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let known = try JSONSerialization.jsonObject(with: encoder.encode(config)) as? [String: Any] ?? [:]
        // Derived from CodingKeys so a new AppConfig field can't be forgotten
        // here; keys outside CodingKeys are foreign and preserved as-is.
        for key in AppConfig.CodingKeys.allCases {
            root[key.stringValue] = known[key.stringValue] // nil value removes the key
        }

        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".config.json.tmp-\(UUID().uuidString)")
        try data.write(to: tempURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        _ = try fm.replaceItemAt(url, withItemAt: tempURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
