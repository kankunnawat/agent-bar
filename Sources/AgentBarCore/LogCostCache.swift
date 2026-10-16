import Foundation

/// One priced log line — the unit the scanner dedupes and buckets.
/// `key` is Claude's `message.id|requestId` dedupe key; `nil` = always counts (Codex).
public struct PricedRecord: Sendable {
    public let key: String?
    public let date: Date
    public let usd: Double

    public init(key: String?, date: Date, usd: Double) {
        self.key = key
        self.date = date
        self.usd = usd
    }
}

/// A file's parsed records plus the `(mtime, size)` that produced them.
/// The cache is valid for this file only while both still match on disk.
public struct FileCacheEntry: Sendable {
    public let mtime: Date
    public let size: Int
    public let records: [PricedRecord]

    public init(mtime: Date, size: Int, records: [PricedRecord]) {
        self.mtime = mtime
        self.size = size
        self.records = records
    }
}

/// Absolute path → cached entry. A plain `Sendable` value: snapshotted into
/// each off-main scan task and merged back on the main actor. No actor needed.
public typealias FileRecordCache = [String: FileCacheEntry]
