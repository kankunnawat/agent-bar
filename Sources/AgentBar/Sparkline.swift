import SwiftUI

/// History drawing in the instrument idiom: uncolored secondary ink, flat,
/// no axes. Bars scale to the series max; the line spans 0–100.
struct Sparkline: View {
    enum Style { case bars, line }
    let values: [Double]
    let style: Style

    var body: some View {
        GeometryReader { geo in
            switch style {
            case .bars: bars(size: geo.size)
            case .line: line(size: geo.size)
            }
        }
    }

    private func bars(size: CGSize) -> some View {
        let top = max(values.max() ?? 0, 0.001)
        let slot = size.width / CGFloat(values.count)
        return ZStack(alignment: .bottomLeading) {
            ForEach(values.indices, id: \.self) { index in
                if values[index] > 0 {
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: max(slot - 1, 1),
                               height: max(size.height * values[index] / top, 1))
                        .offset(x: CGFloat(index) * slot)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func line(size: CGSize) -> some View {
        Path { path in
            let stepX = size.width / CGFloat(values.count - 1)
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * stepX,
                                    y: size.height * (1 - min(value, 100) / 100))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        .stroke(Color.secondary, lineWidth: 1)
    }
}
