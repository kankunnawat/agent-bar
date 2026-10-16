import Foundation

public struct DiscoveredAccount: Equatable, Sendable {
    public var provider: Provider
    public var path: String
    public init(provider: Provider, path: String) {
        self.provider = provider
        self.path = path
    }
}

public enum AccountDiscovery {
    /// Files whose presence marks a directory as a real Claude config dir.
    /// A bare settings.json is NOT sufficient — tool data dirs like
    /// ~/.claude-mem carry their own settings.json but are not accounts.
    private static let claudeFileMarkers = [".credentials.json", "__store.db"]

    public static func discover(home: URL) -> [DiscoveredAccount] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: home.path) else { return [] }
        var results: [DiscoveredAccount] = []
        for entry in entries {
            let url = home.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if entry.hasPrefix(".claude") {
                var projectsIsDir: ObjCBool = false
                let hasProjectsDir = fm.fileExists(
                    atPath: url.appendingPathComponent("projects").path, isDirectory: &projectsIsDir)
                    && projectsIsDir.boolValue
                let isConfigDir = hasProjectsDir
                    || claudeFileMarkers.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
                if isConfigDir { results.append(DiscoveredAccount(provider: .claude, path: url.path)) }
            } else if entry.hasPrefix(".codex") {
                if fm.fileExists(atPath: url.appendingPathComponent("auth.json").path) {
                    results.append(DiscoveredAccount(provider: .codex, path: url.path))
                }
            }
        }
        // Cursor keeps one login per Mac under Application Support, not a
        // home dot-dir. Grok Bot signs in with the same Cursor account.
        let cursorDir = home.appendingPathComponent("Library/Application Support/Cursor")
        if fm.fileExists(atPath: cursorDir.appendingPathComponent(CursorCredentials.databaseSubpath).path) {
            results.append(DiscoveredAccount(provider: .cursor, path: cursorDir.path))
        }
        return results.sorted { $0.path < $1.path }
    }
}
