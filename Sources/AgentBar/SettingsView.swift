import AgentBarCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var store: UsageStoreSettingsAdapter

    var body: some View {
        Form {
            Section("Accounts") {
                if store.store.rows.isEmpty {
                    emptyAccounts
                }
                ForEach(store.store.rows) { row in
                    SettingsAccountRow(row: row, store: store)
                }
                Button { store.addAccountFolder() } label: {
                    Label("Add account folder…", systemImage: "plus")
                }
            }
            Section("General") {
                Picker("Show in menu bar", selection: store.pinnedSelection) {
                    Text("Highest usage (auto)").tag(String?.none)
                    ForEach(store.store.rows) { row in
                        Text(pickerLabel(row.account)).tag(Optional(row.account.id))
                    }
                }
                Picker("Refresh every", selection: store.refreshIntervalBinding) {
                    Text("1 min").tag(60)
                    Text("2 min").tag(120)
                    Text("5 min").tag(300)
                }
                .pickerStyle(.segmented)
                Toggle("Launch at login", isOn: store.launchAtLoginBinding)
            }
            Section("Alerts") {
                Toggle("Notify when an account nears a limit", isOn: store.alertsEnabledBinding)
                if store.store.config.alerts.enabled {
                    thresholdSlider("Session (5h / Cursor mo)", value: store.thresholdBinding, range: 50...95,
                                    current: store.store.config.alerts.sessionThresholdPercent)
                    thresholdSlider("Weekly", value: store.weeklyThresholdBinding, range: 50...100,
                                    current: store.store.config.alerts.weeklyThresholdPercent)
                }
            }
            Section("Service status") {
                ForEach(Provider.allCases, id: \.rawValue) { provider in
                    LabeledContent(provider.statusName) {
                        Text(statusDescription(for: provider))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
    }

    private var emptyAccounts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No accounts found").foregroundStyle(.secondary)
            Text("AgentBar looks for Claude, Codex, and Cursor sign-ins.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickerLabel(_ account: Account) -> String {
        "\(account.label) (\(account.provider.displayName))"
    }

    private func statusDescription(for provider: Provider) -> String {
        guard let status = store.store.statuses[provider], status.indicator != .unknown else {
            return "Status unavailable"
        }
        return status.description
    }

    private func thresholdSlider(_ title: String, value: Binding<Double>,
                                 range: ClosedRange<Double>, current: Double) -> some View {
        HStack(spacing: 12) {
            Slider(value: value, in: range, step: 5) { Text(title) }
            Text("\(Int(current))%")
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// Bridges UsageStore.updateConfig into SwiftUI bindings.
@MainActor
@Observable
final class UsageStoreSettingsAdapter {
    let store: UsageStore
    init(store: UsageStore) { self.store = store }

    func commitLabel(_ newValue: String, for account: Account) {
        let current = store.config.accounts[account.id]?.label ?? account.label
        guard newValue != current, !newValue.isEmpty else { return }
        store.updateConfig { cfg in
            var override = cfg.accounts[account.id] ?? AccountOverride()
            override.label = newValue
            cfg.accounts[account.id] = override
        }
    }

    /// The single app-level "which account does the menu bar show" choice;
    /// nil means the worst session percent across accounts.
    var pinnedSelection: Binding<String?> {
        Binding(
            get: { self.store.config.pinnedAccountID },
            set: { id in self.store.setPinned(id: id) })
    }

    func toggleHidden(_ account: Account) {
        store.updateConfig { cfg in
            var override = cfg.accounts[account.id] ?? AccountOverride()
            override.hidden = !account.hidden
            cfg.accounts[account.id] = override
        }
    }

    func isManual(_ account: Account) -> Bool {
        store.config.manualPaths.contains { $0.path == account.path }
    }

    func removeManualFolder(_ account: Account) {
        store.updateConfig { cfg in
            cfg.manualPaths.removeAll { $0.path == account.path }
        }
    }

    var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { self.store.config.refreshIntervalSeconds },
            set: { v in self.store.updateConfig { $0.refreshIntervalSeconds = v } })
    }

    var alertsEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.store.config.alerts.enabled },
            set: { v in
                self.store.updateConfig { $0.alerts.enabled = v }
                if v { Notifier.requestAuthorization() }
            })
    }

    var thresholdBinding: Binding<Double> {
        Binding(
            get: { self.store.config.alerts.sessionThresholdPercent },
            set: { v in self.store.updateConfig { $0.alerts.sessionThresholdPercent = v } })
    }

    var weeklyThresholdBinding: Binding<Double> {
        Binding(
            get: { self.store.config.alerts.weeklyThresholdPercent },
            set: { v in self.store.updateConfig { $0.alerts.weeklyThresholdPercent = v } })
    }

    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enable in
                do {
                    if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    // Registration only works from a bundled .app; ignore when run bare.
                }
            })
    }

    func addAccountFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Add"
        panel.message = "Choose an account folder — a Claude config dir (like ~/.claude) or a Codex home (like ~/.codex)"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let provider: Provider =
            FileManager.default.fileExists(atPath: url.appendingPathComponent("auth.json").path)
            ? .codex : .claude
        store.updateConfig { cfg in
            let manual = ManualPath(provider: provider, path: url.path)
            if !cfg.manualPaths.contains(manual) { cfg.manualPaths.append(manual) }
        }
    }
}
