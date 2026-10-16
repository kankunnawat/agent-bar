import AgentBarCore
import AppKit

enum StatusIcon {
    @MainActor
    static func image(state: IconState) -> NSImage {
        let text: String
        let color: NSColor
        switch state {
        case .normal(let percent, let tint):
            text = "◆ \(Int(percent))%"
            color = switch tint {
            case .normal: .labelColor
            case .warning: .systemOrange
            case .critical: .systemRed
            }
        case .allErrored:
            text = "◆ !"
            color = .systemRed
        case .noAccounts:
            text = "◆ ?"
            color = .secondaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
            .kern: 0.2,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: 18), flipped: false) { rect in
            string.draw(at: NSPoint(x: 0, y: ((rect.height - size.height) / 2).rounded()))
            return true
        }
        image.isTemplate = false
        return image
    }
}
