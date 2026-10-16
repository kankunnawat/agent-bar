import AgentBarCore
import SwiftUI

/// One account in Settings: rename-in-place name over the folder path, a
/// state flag when degraded, provider badge, and hover-revealed controls.
/// Hidden accounts render dimmed and restore to full strength while hovered.
struct SettingsAccountRow: View {
    let row: AccountRow
    let store: UsageStoreSettingsAdapter

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                nameLine
                Text((row.account.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let flag = stateFlagWord {
                StateFlag(word: flag)
            }
            providerBadge
            controls
        }
        .padding(.vertical, 2)
        .opacity(row.account.hidden && !hovering ? 0.45 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: row.account.hidden)
        .onHover { hovering = $0 }
        .help(row.account.path)
    }

    @ViewBuilder private var nameLine: some View {
        if editing {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .fontWeight(.medium)
                .focused($nameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { editing = false } // Esc cancels: the guard in commitRename skips the focus-loss commit
                .onChange(of: nameFocused) { _, focused in
                    if !focused { commitRename() }
                }
        } else {
            Text(row.account.label)
                .fontWeight(.medium)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginRename() }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button { beginRename() } label: { Image(systemName: "pencil") }
                .opacity(hovering && !editing ? 1 : 0)
                .allowsHitTesting(hovering && !editing)
                .help("Rename (or double-click the name)")
            Button { store.toggleHidden(row.account) } label: {
                Image(systemName: row.account.hidden ? "eye.slash" : "eye")
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .help(row.account.hidden ? "Show in the dropdown" : "Hide from the dropdown and totals")
            if store.isManual(row.account) {
                Button { store.removeManualFolder(row.account) } label: {
                    Image(systemName: "xmark.circle")
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .help("Remove this folder from AgentBar")
            }
        }
        .buttonStyle(.borderless)
    }

    /// No-Identity-Hue Rule: provider badges are neutral ink so state hues
    /// stay unambiguous.
    private var providerBadge: some View {
        Text(row.account.provider.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private var stateFlagWord: String? {
        switch row.state {
        case .stale: "HOLD"
        case .error: "NO SIGNAL"
        case .signedOut: "SIGNED OUT"
        case .ok, .loading: nil
        }
    }

    private func beginRename() {
        draft = row.account.label
        editing = true
        nameFocused = true
    }

    private func commitRename() {
        guard editing else { return }
        editing = false
        store.commitLabel(draft, for: row.account)
    }
}
