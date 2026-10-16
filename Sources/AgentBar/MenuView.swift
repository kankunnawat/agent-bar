import AgentBarCore
import SwiftUI

struct MenuView: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Provider.allCases, id: \.rawValue) { provider in
                let rows = store.shownRows.filter { $0.account.provider == provider }
                if !rows.isEmpty {
                    section(provider: provider, rows: rows)
                }
            }
            if store.shownRows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No accounts found").foregroundStyle(.secondary)
                    Text("AgentBar looks for Claude, Codex, and Cursor sign-ins. Add a Claude or Codex folder manually in Settings.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 460)
    }

    private func section(provider: Provider, rows: [AccountRow]) -> some View {
        let now = Date()
        let states = store.rows.map { (account: $0.account, state: $0.state) }
        let recommendedID = RiskPresentation.recommendedAlternativeID(
            for: provider,
            among: states,
            alerts: store.config.alerts,
            now: now)
        return VStack(alignment: .leading, spacing: 8) {
            Text(provider.displayName.uppercased())
                .font(.caption).fontWeight(.semibold).tracking(0.8).foregroundStyle(.secondary)
            ForEach(rows) { row in
                AccountRowView(row: row, now: now, cost: store.costByAccount[row.id],
                               isPinned: store.pinnedAccountID == row.id,
                               isRecommendedAlternative: row.id == recommendedID,
                               alerts: store.config.alerts,
                               history: store.historyByAccount[row.id] ?? [],
                               onTogglePin: { store.setPinned(id: store.pinnedAccountID == row.id ? nil : row.id) },
                               onRetry: { Task { await store.refreshAccount(id: row.id) } })
                    .onDrag { NSItemProvider(object: row.id as NSString) }
                    .onDrop(of: [.text], delegate: RowDropDelegate(targetID: row.id, store: store))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if Provider.allCases.contains(where: { store.statuses[$0]?.indicator.incidentDescription != nil }) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Provider.allCases, id: \.rawValue) { provider in
                        if let status = store.statuses[provider],
                           let incident = status.indicator.incidentDescription {
                            Label("\(provider.statusName) \(incident)",
                                  systemImage: status.indicator == .critical
                                      ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(status.indicator == .critical ? .red : .orange)
                                .help(status.description)
                        }
                    }
                }
            }
            // Limits and cost are peers: the combined total reads at body
            // strength, not as footer telemetry.
            if let costLine = RowPresentation.footerCostLine(store.totalCost) {
                Text(costLine)
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                if let last = store.lastRefreshed {
                    Text("refreshed \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    Task { await store.refreshNow() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                    .buttonStyle(.borderless)
                    .disabled(store.isRefreshing)
                    .frame(width: 20)
                    .help("Refresh now")
                Button {
                    // LSUIElement apps are never "active", so the Settings
                    // window would open behind everything without this.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Quit AgentBar")
            }
        }
    }
}

/// Reorders visually on hover-during-drag (standard SwiftUI move-on-entered
/// pattern); the single config write happens at performDrop.
private struct RowDropDelegate: DropDelegate {
    let targetID: String
    let store: UsageStore

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let draggedID = object as? String, draggedID != targetID else { return }
            Task { @MainActor in
                store.previewMove(fromID: draggedID, toID: targetID)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        Task { @MainActor in store.commitMove() }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
