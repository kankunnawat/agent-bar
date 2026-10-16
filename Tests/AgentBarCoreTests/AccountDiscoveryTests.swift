import Foundation
import Testing
@testable import AgentBarCore

@Suite struct AccountDiscoveryTests {
    /// Builds a fake home dir mirroring the real machine: real config dirs
    /// have a projects/ directory and/or credential files; tool data dirs
    /// like .claude-mem carry only their own settings.json and are excluded.
    private func makeFakeHome() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("agentbar-home-\(UUID().uuidString)")
        func mk(_ dir: String, files: [String] = [], subdirs: [String] = []) throws {
            let d = home.appendingPathComponent(dir)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            for f in files { try Data("{}".utf8).write(to: d.appendingPathComponent(f)) }
            for s in subdirs { try fm.createDirectory(at: d.appendingPathComponent(s), withIntermediateDirectories: true) }
        }
        try mk(".claude", files: ["settings.json"], subdirs: ["projects"])
        try mk(".claude-personal", files: [".credentials.json"])
        try mk(".claude-experimental", subdirs: ["projects"])
        try mk(".claude-mem", files: ["settings.json", "index.sqlite"])
        try mk(".claude-fakeprojects", files: ["projects"]) // plain FILE named projects -> excluded
        try mk(".codex", files: ["auth.json"])
        try mk(".codexbar", files: ["config.json"])
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        return home
    }

    @Test func discoversOnlyRealConfigDirs() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let found = AccountDiscovery.discover(home: home)
        let paths = found.map(\.path)

        #expect(paths.contains(home.appendingPathComponent(".claude").path))
        #expect(paths.contains(home.appendingPathComponent(".claude-personal").path))
        #expect(paths.contains(home.appendingPathComponent(".claude-experimental").path))
        #expect(paths.contains(home.appendingPathComponent(".codex").path))
        #expect(!paths.contains(home.appendingPathComponent(".claude-mem").path))
        #expect(!paths.contains(home.appendingPathComponent(".claude-fakeprojects").path))
        #expect(!paths.contains(home.appendingPathComponent(".codexbar").path))
        #expect(!paths.contains(home.appendingPathComponent(".claude.json").path))

        #expect(found.first { $0.path.hasSuffix(".codex") }?.provider == .codex)
        #expect(found.first { $0.path.hasSuffix(".claude") }?.provider == .claude)
        #expect(found == found.sorted { $0.path < $1.path })
    }

    @Test func emptyHomeYieldsNothing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AccountDiscovery.discover(home: home).isEmpty)
    }

    @Test func discoversCursorWhenStateDBExists() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cursorDir = home.appendingPathComponent("Library/Application Support/Cursor")
        #expect(!AccountDiscovery.discover(home: home).contains { $0.provider == .cursor })

        let db = cursorDir.appendingPathComponent(CursorCredentials.databaseSubpath)
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: db)
        let cursor = AccountDiscovery.discover(home: home).filter { $0.provider == .cursor }
        #expect(cursor == [DiscoveredAccount(provider: .cursor, path: cursorDir.path)])
    }
}
