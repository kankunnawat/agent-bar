import Foundation

/// Shared scan engine for the log cost readers. Recursively walks `.jsonl`
/// files under the given roots, skips files whose mtime is older than the
/// 30-day window (never opening them), and prices each line via `priceLine`.
///
/// Memoized: a file whose `(mtime, size)` match the passed-in cache reuses its
/// previously-parsed `[PricedRecord]` with no I/O and no JSON work. The union of
/// cached + freshly-parsed records is deduped (Claude's cross-file key) and
/// bucketed into today / trailing-30-day against the current `now`, so totals
/// are identical to a cold scan. The updated cache is returned for the next cycle.
enum LogCostScanner {
    static let windowSeconds: TimeInterval = 30 * 86_400

    static func scan(
        roots: [URL], now: Date, fileManager: FileManager,
        cache: FileRecordCache,
        priceLine: ([String: Any]) -> (key: String?, date: Date, usd: Double)? // swiftlint:disable:this large_tuple
    ) -> (cost: UsageCost, cache: FileRecordCache) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        var updated = FileRecordCache()
        var parsed = 0
        var cached = 0
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]),
                    let mtime = values.contentModificationDate else { continue }
                if mtime < cutoff { continue }
                let size = values.fileSize ?? -1
                if let hit = cache[url.path], hit.mtime == mtime, hit.size == size {
                    updated[url.path] = hit
                    cached += 1
                } else if let records = parseRecords(url: url, priceLine: priceLine) {
                    updated[url.path] = FileCacheEntry(mtime: mtime, size: size, records: records)
                    parsed += 1
                }
            }
        }
        Log.cost.notice("cost scan parsed=\(parsed) cached=\(cached)")
        return (bucket(updated, now: now, cutoff: cutoff), updated)
    }

    private static func parseRecords(
        url: URL,
        priceLine: ([String: Any]) -> (key: String?, date: Date, usd: Double)? // swiftlint:disable:this large_tuple
    ) -> [PricedRecord]? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var records: [PricedRecord] = []
        for lineText in contents.split(separator: "\n") {
            guard let data = lineText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let priced = priceLine(object) else { continue }
            records.append(PricedRecord(key: priced.key, date: priced.date, usd: priced.usd))
        }
        return records
    }

    private static func bucket(_ cache: FileRecordCache, now: Date, cutoff: Date) -> UsageCost {
        let calendar = Calendar.current
        var cost = UsageCost.zero
        var seen = Set<String>()
        for entry in cache.values {
            for record in entry.records where record.date >= cutoff {
                if let key = record.key {
                    if seen.contains(key) { continue } // same API call already counted
                    seen.insert(key)
                }
                cost.thirtyDay += record.usd
                cost.daily[calendar.startOfDay(for: record.date), default: 0] += record.usd
                if calendar.isDate(record.date, inSameDayAs: now) { cost.today += record.usd }
            }
        }
        return cost
    }
}
