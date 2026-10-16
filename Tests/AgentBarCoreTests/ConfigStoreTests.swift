import Foundation
import Testing
@testable import AgentBarCore

@Suite struct ConfigStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-cfg-\(UUID().uuidString)/config.json")
    }

    @Test func missingFileLoadsDefaults() {
        let store = ConfigStore(url: tempURL())
        let cfg = store.load()
        #expect(cfg == AppConfig.default)
        #expect(cfg.refreshIntervalSeconds == 120)
        #expect(cfg.alerts.enabled)
        #expect(cfg.alerts.sessionThresholdPercent == 80)
    }

    @Test func corruptFileLoadsDefaults() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(ConfigStore(url: url).load() == AppConfig.default)
    }

    @Test func roundTripsAndPreservesUnknownKeys() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"futureFeature":{"x":true}}"#.utf8).write(to: url)

        let store = ConfigStore(url: url)
        var cfg = store.load()
        cfg.refreshIntervalSeconds = 300
        cfg.accounts["claude:/Users/x/.claude"] = AccountOverride(label: "work", hidden: false)
        cfg.manualPaths = [ManualPath(provider: .codex, path: "/Users/x/.codex-alt")]
        try store.save(cfg)

        let reloaded = store.load()
        #expect(reloaded.refreshIntervalSeconds == 300)
        #expect(reloaded.accounts["claude:/Users/x/.claude"]?.label == "work")
        #expect(reloaded.manualPaths.first?.path == "/Users/x/.codex-alt")

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(raw?["futureFeature"] != nil)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func saveCreatesParentDirectory() throws {
        let store = ConfigStore(url: tempURL())
        try store.save(.default)
        #expect(FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func decodesPinAndOrder() throws {
        let json = #"{"pinnedAccountID":"claude:/x","accountOrder":["claude:/x","codex:/y"]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.pinnedAccountID == "claude:/x")
        #expect(config.accountOrder == ["claude:/x", "codex:/y"])
    }

    @Test func missingPinAndOrderDefault() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config.pinnedAccountID == nil)
        #expect(config.accountOrder.isEmpty)
    }

    @Test func badNestedOverrideDropsEntryNotWholeMap() throws {
        let json = #"{"accounts":{"good":{"label":"ok"},"bad":{"hidden":"not-a-bool"}}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.accounts["good"]?.label == "ok")
        #expect(config.accounts["bad"] == nil)
    }

    @Test func clearingPinRemovesKeyOnSave() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-cfg-\(UUID().uuidString)/config.json")
        let store = ConfigStore(url: url)
        var config = AppConfig.default
        config.pinnedAccountID = "claude:/x"
        try store.save(config)
        config.pinnedAccountID = nil
        try store.save(config)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(root?["pinnedAccountID"] == nil)
    }

    @Test func decodingConfigWithoutWeeklyThresholdPreservesSessionAndEnabled() throws {
        // An old config written before weeklyThresholdPercent existed.
        let json = #"{"alerts":{"enabled":false,"sessionThresholdPercent":75}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.alerts.enabled == false)
        #expect(config.alerts.sessionThresholdPercent == 75)
        #expect(config.alerts.weeklyThresholdPercent == 90)
    }

    @Test func alertsConfigRoundTripsAllThreeFields() throws {
        let original = AlertsConfig(enabled: false, sessionThresholdPercent: 65, weeklyThresholdPercent: 88)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AlertsConfig.self, from: data)
        #expect(decoded == original)
    }
}
