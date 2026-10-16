import Foundation
import Testing
@testable import AgentBar
@testable import AgentBarCore

@MainActor
@Suite struct UsageStoreLoopTests {
    /// A config dir that becomes an account after launch (first CLI session
    /// creates projects/) must appear on the next refresh tick, not only after
    /// a relaunch. Uses a Codex dir: a Claude row would read the real Keychain.
    @Test func refreshLoopPicksUpAccountFolderAddedAfterLaunch() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("agentbar-loop-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let store = UsageStore(
            configStore: ConfigStore(url: home.appendingPathComponent("config.json")),
            transport: MockTransport(status: 200, json: "{}"),
            home: home)
        #expect(store.rows.isEmpty)

        let codexDir = home.appendingPathComponent(".codex-work")
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: codexDir.appendingPathComponent("auth.json"))

        store.start()
        let deadline = Date().addingTimeInterval(2)
        while store.rows.isEmpty || store.lastRefreshed == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.rows.map(\.account.path) == [codexDir.path])
    }
}
