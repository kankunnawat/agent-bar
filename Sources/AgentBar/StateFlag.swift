import SwiftUI

/// Instrument word-flag (HOLD, NO SIGNAL) or annunciator (WK, DOWN):
/// engraved uppercase caption in a hairline outline. Neutral by default;
/// annunciators may carry the state hue so a word, never color alone,
/// announces the condition. The design system's replacement for status dots.
struct StateFlag: View {
    let word: String
    var tint: Color?

    var body: some View {
        Text(word)
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(tint.map { AnyShapeStyle($0.opacity(0.5)) } ?? AnyShapeStyle(.quaternary),
                              lineWidth: 1))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}
