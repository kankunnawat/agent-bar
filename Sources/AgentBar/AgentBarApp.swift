import AgentBarCore
import SwiftUI

@main
struct AgentBarApp: App {
    @State private var store: UsageStore
    @State private var settingsAdapter: UsageStoreSettingsAdapter

    init() {
        let store = UsageStore()
        store.onAlerts = { events in Notifier.deliver(events) }
        if store.config.alerts.enabled { Notifier.requestAuthorization() }
        _store = State(initialValue: store)
        _settingsAdapter = State(initialValue: UsageStoreSettingsAdapter(store: store))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Image(nsImage: StatusIcon.image(state: store.iconState))
                .task { store.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: settingsAdapter)
        }
    }
}
