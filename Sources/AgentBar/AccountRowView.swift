import AgentBarCore
import SwiftUI

// THESIS: a bench instrument row — readings against printed marks, quiet
// until a limit approaches. OWN-WORLD: ink on system material; amber ≥70,
// red ≥90, no green anywhere; tabular numerals; graticule ticks; word-flags
// for degraded states. STORY: the user reads the level like a meter and only
// sees color when action nears. FIRST VIEWPORT: name · graticule meter ·
// percent reading, aligned as a readout bank. FORM: fused "bench
// oscilloscope" (assigned, seed 33ea1a4a) × "ligne claire" restraint,
// user-pinned 2026-07-25.
struct AccountRowView: View {
    let row: AccountRow
    let now: Date
    let cost: UsageCost?
    let isPinned: Bool
    let isRecommendedAlternative: Bool
    /// The user's warning marks: printed on the meter, and the gate on every
    /// projected-full cue in the row and its hover card.
    let alerts: AlertsConfig
    /// Stored usage history for the hover sparkline; empty before first record.
    let history: [HistoryEntry]
    let onTogglePin: () -> Void
    let onRetry: () -> Void

    @State private var hovering = false

    var body: some View {
        Group {
            switch row.state {
            case .ok(let snap): okRow(snap)
            case .loading: loadingRow
            case .stale(let message): messageRow(message, flag: "HOLD")
            case .error(let message): messageRow(message, flag: "NO SIGNAL")
            // MenuView filters these out; kept for exhaustiveness.
            case .signedOut: messageRow("not signed in — open the app and sign in", flag: "SIGNED OUT")
            }
        }
        .onHover { hovering = $0 }
        // Pinning lives in a right-click menu, not an in-row button: the hover
        // popover is transient, so a click on the row is swallowed as a
        // dismiss and never reaches a button. Right-click is a distinct event
        // the popover can't intercept.
        .contextMenu {
            Button(isPinned ? "Unpin from menu bar" : "Pin to menu bar", action: onTogglePin)
        }
    }

    /// One meter bank per row: session meter over a thin always-on weekly
    /// track, a compact reset countdown before it, and a two-line reading
    /// (percent over today's cost). Hues follow the existing rules: the
    /// session meter carries worst-of-both, the weekly track and each number
    /// wear only their own window's severity. Depth stays in the hover card.
    private func okRow(_ snap: UsageSnapshot) -> some View {
        let session = snap.worstSession
        let percent = session?.usedPercent ?? 0
        let weekly = snap.worstWeekly?.usedPercent ?? 0
        let pace = PaceProjection.elapsedFraction(
            resetsAt: session?.resetsAt, startsAt: session?.startsAt, now: now, kind: .session)
        return HStack(spacing: 10) {
            nameAndPin
            if isRecommendedAlternative {
                StateFlag(word: "NEXT")
            }
            if weekly >= 70, weekly > percent {
                StateFlag(word: "WK", tint: weekly >= 90 ? .red : .orange)
            }
            Spacer(minLength: 8)
            if let risk = RiskPresentation.caption(for: snap, alerts: alerts, now: now) {
                Text(risk)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else if let reset = RowPresentation.resetCaption(
                resetsAt: session?.resetsAt,
                now: now
            ) {
                Text(reset)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(spacing: 3) {
                UsageMeter(percent: percent, severity: max(percent, weekly), paceFraction: pace,
                           thresholdFraction: alerts.sessionThresholdPercent / 100)
                if snap.worstWeekly != nil {
                    WeeklyTrack(percent: weekly)
                }
            }
            .frame(width: 96)
            readingColumn(percent: percent)
        }
        .popover(isPresented: $hovering, arrowEdge: .trailing) {
            hoverCard(snap)
        }
    }

    /// Percent reading with today's cost beneath it — the row's readout bank.
    private func readingColumn(percent: Double) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(Int(percent))%")
                .font(.system(size: 16))
                .monospacedDigit()
                .fontWeight(percent >= 90 ? .bold : percent >= 70 ? .semibold : .regular)
                .foregroundStyle(readingColor(percent))
            if let costCaption = RowPresentation.rowCostCaption(cost) {
                Text(costCaption)
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 54, alignment: .trailing)
    }

    private func hoverCard(_ snap: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(row.account.label).font(.title3).fontWeight(.semibold)
                if isPinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Leading-aligned columns: the values are compound strings, so the
            // percents the eye scans for line up only from the left.
            // hoverReadout omits the cost line when there is no data.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(RowPresentation.hoverReadout(snap, cost: cost, alerts: alerts, now: now), id: \.self) { line in
                    GridRow {
                        Text(line.label).font(.body).foregroundStyle(.secondary)
                        Text(line.value).font(.body).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let daily = RowPresentation.dailyCostSeries(cost, now: now) {
                    GridRow {
                        Text("30d $").font(.body).foregroundStyle(.secondary)
                        Sparkline(values: daily, style: .bars).frame(width: 96, height: 14)
                    }
                }
                if let weekly = RowPresentation.weeklySeries(history) {
                    GridRow {
                        Text("wk %").font(.body).foregroundStyle(.secondary)
                        Sparkline(values: weekly, style: .line).frame(width: 96, height: 14)
                    }
                }
            }
        }
        .padding(14)
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            nameAndPin
            Spacer()
            ProgressView().controlSize(.small)
        }
    }

    /// stale/error: instrument flag on the name line, message on its own
    /// caption line; the whole row is tappable to retry. The retry glyph
    /// brightens on hover so the affordance is discoverable.
    private func messageRow(_ message: String, flag: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                nameAndPin
                Spacer()
                StateFlag(word: flag)
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onTapGesture { onRetry() }
        .help("Click to retry")
    }

    private var nameAndPin: some View {
        HStack(spacing: 5) {
            Text(row.account.label)
                .font(.system(size: 16, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if isPinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                    .help("pinned — shown in the menu bar; right-click to change")
            }
        }
    }

    /// Quiet-when-healthy: ink below 70, amber to 90, red past it.
    private func readingColor(_ severity: Double) -> Color {
        severity >= 90 ? .red : severity >= 70 ? .orange : .primary
    }
}

/// The graticule meter: a flat instrument window with division ticks at
/// 25/50/75 so a level is read against marks, not guessed. `percent` sets
/// the fill geometry; `severity` (worst window) sets its hue.
struct UsageMeter: View {
    let percent: Double
    let severity: Double
    /// Fraction of the window elapsed in time; nil draws no tick.
    /// Fill past the cursor means usage is running ahead of the clock.
    let paceFraction: Double?
    /// Alert threshold as a fraction — a printed limit mark, drawn whether or
    /// not alerts are armed, the way a scale stays printed on a dead gauge.
    let thresholdFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let fillWidth = max(2, geo.size.width * min(percent, 100) / 100)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(fillStyle)
                    .frame(width: fillWidth)
                // Ticks covered by the fill render as dark notches so the
                // marks stay readable over an amber/red fill in both modes.
                ForEach([0.25, 0.5, 0.75], id: \.self) { tick in
                    let x = geo.size.width * tick
                    Rectangle()
                        .fill(x <= fillWidth ? Color.black.opacity(0.3) : Color.primary.opacity(0.18))
                        .frame(width: 1)
                        .offset(x: x - 0.5)
                }
                // After the ticks, before the pace cursor: pace is the live
                // needle and stays on top of the printed marks.
                if let thresholdFraction {
                    let x = geo.size.width * thresholdFraction
                    Rectangle()
                        .fill(x <= fillWidth ? Color.black.opacity(0.3) : Color.red.opacity(0.5))
                        .frame(width: 1)
                        .offset(x: x - 0.5)
                }
                if let paceFraction {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * paceFraction - 0.75)
                }
            }
        }
        .frame(height: 8)
    }

    private var fillStyle: AnyShapeStyle {
        severity >= 90 ? AnyShapeStyle(Color.red)
            : severity >= 70 ? AnyShapeStyle(Color.orange)
            : AnyShapeStyle(.secondary)
    }
}

/// Thin always-on weekly companion under the session meter: the same
/// instrument window at 3pt, no ticks — the WK annunciator still names
/// weekly when it binds; this track just keeps the level readable. Hue
/// follows the weekly window itself, never the session's.
struct WeeklyTrack: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fillStyle)
                    .frame(width: max(2, geo.size.width * min(percent, 100) / 100))
            }
        }
        .frame(height: 3)
    }

    private var fillStyle: AnyShapeStyle {
        percent >= 90 ? AnyShapeStyle(Color.red)
            : percent >= 70 ? AnyShapeStyle(Color.orange)
            : AnyShapeStyle(.secondary)
    }
}
