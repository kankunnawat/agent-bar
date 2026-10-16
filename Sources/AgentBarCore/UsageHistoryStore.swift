import Foundation

/// One hour-bucket of an account's usage history. `session`/`weekly` hold the
/// max worst-window percent observed within the hour; nil = never observed.
public struct HistoryEntry: Codable, Sendable, Equatable {
    public var hour: Date
    public var session: Double?
    public var weekly: Double?

    public init(hour: Date, session: Double?, weekly: Double?) {
        self.hour = hour
        self.session = session
        self.weekly = weekly
    }
}

/// Per-account usage-% history: one JSON file per account under Application
/// Support, hour buckets keeping the max per dimension, 30-day retention.
/// Lenient by design — a corrupt file reads as empty and heals on the next
/// record; write failures log and drop (history must never wedge a row).
public actor UsageHistoryStore {
    public static let retentionSeconds: TimeInterval = 30 * 86_400

    private let directory: URL
    private let fileManager: FileManager

    public init(home: URL, fileManager: FileManager = .default) {
        self.directory = home.appendingPathComponent("Library/Application Support/AgentBar/history")
        self.fileManager = fileManager
    }

    /// Upserts `now`'s hour bucket (max per dimension), prunes entries older
    /// than the retention window, persists, and returns the updated series.
    @discardableResult
    public func record(accountID: String, session: Double?, weekly: Double?, at now: Date) -> [HistoryEntry] {
        guard session != nil || weekly != nil else { return series(accountID: accountID) }
        var entries = load(accountID: accountID)
        let hour = Self.flooredToHour(now)
        if let index = entries.firstIndex(where: { $0.hour == hour }) {
            entries[index].session = Self.maxObserved(entries[index].session, session)
            entries[index].weekly = Self.maxObserved(entries[index].weekly, weekly)
        } else {
            entries.append(HistoryEntry(hour: hour, session: session, weekly: weekly))
        }
        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        entries = entries.filter { $0.hour >= cutoff }.sorted { $0.hour < $1.hour }
        save(entries, accountID: accountID)
        return entries
    }

    public func series(accountID: String) -> [HistoryEntry] {
        load(accountID: accountID).sorted { $0.hour < $1.hour }
    }

    /// Epoch-floored, not calendar-floored: buckets are fixed 3600s slots, so
    /// a DST shift moves bucket labels, never double-counts an hour.
    private static func flooredToHour(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate:
            (date.timeIntervalSinceReferenceDate / 3_600).rounded(.down) * 3_600)
    }

    private static func maxObserved(_ existing: Double?, _ new: Double?) -> Double? {
        [existing, new].compactMap { $0 }.max()
    }

    private func fileURL(accountID: String) -> URL {
        let name = accountID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("\(name).json")
    }

    private func load(accountID: String) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL(accountID: accountID)),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return [] } // missing or corrupt — start fresh, heals on next save
        return entries
    }

    private func save(_ entries: [HistoryEntry], accountID: String) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL(accountID: accountID), options: .atomic)
        } catch {
            Log.history.error("history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
