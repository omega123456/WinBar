import AppKit
import SnapshotTesting
import Testing
@testable import WinBar

/// Offscreen renders of every TaskbarButton state, compared with the PNGs in __Snapshots__.
/// Nothing is shown on screen: the button's layer tree is rendered with `CALayer.render(in:)`.
@MainActor
@Suite struct TaskbarButtonSnapshotTests {
    enum Case: String, CaseIterable {
        case window, windowActive, iconOnly, launcher, appItem
        case badgeCount, badge99Plus, badgeDot, badgeAlert
        case progress, progressPaused, attention, overflow, longTitle

        @MainActor var content: TaskbarButton.Content {
            let window = BarItem(kind: .window(1, 1), group: .other)
            func button(_ item: BarItem? = window, label: String = "README.md — Notes", width: CGFloat = 160,
                        iconOnly: Bool = false) -> TaskbarButton.Content {
                .init(item: item, icon: TaskbarButtonSnapshotTests.icon, label: label, width: width, iconOnly: iconOnly, voiceOver: label)
            }
            switch self {
            case .window: return button()
            case .windowActive: var c = button(); c.active = true; return c
            case .iconOnly: return button(width: BarController.slot, iconOnly: true)
            case .launcher: return button(BarItem(kind: .launcher("x"), group: .pinned), width: BarController.slot, iconOnly: true)
            case .appItem: return button(BarItem(kind: .appItem("x"), group: .pinned), width: BarController.slot, iconOnly: true)
            case .badgeCount: var c = button(); c.badge = .count("3"); return c
            case .badge99Plus: var c = button(); c.badge = .count("99+"); return c
            case .badgeDot: var c = button(); c.badge = .dot; return c
            case .badgeAlert: var c = button(); c.badge = .alert; return c
            case .progress: var c = button(); c.progress = ProgressState(fraction: 0.4, paused: false); return c
            case .progressPaused: var c = button(); c.progress = ProgressState(fraction: 0.4, paused: true); return c
            case .attention: var c = button(); c.attention = .holding; return c
            case .overflow:
                var c = button(nil, label: "", width: BarController.slot, iconOnly: true)
                c.icon = TaskbarButton.dots(color: Theme().text)
                return c
            case .longTitle: return button(label: "A very long window title that cannot fit in the button — Safari")
            }
        }
    }

    /// Fixed artwork: real app icons and SF Symbols change between macOS versions.
    static let icon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in
        NSColor(srgbRed: 0.23, green: 0.59, blue: 0.87, alpha: 1).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6).fill()
        return true
    }

    init() { _ = fontsRegistered }

    @Test(arguments: Case.allCases)
    func state(_ c: Case) {
        let content = c.content
        #expect(Fonts.label.fontName == "Selawik-Regular")
        let button = TaskbarButton()
        button.update(content, theme: Theme())
        button.frame = NSRect(x: 0, y: 0, width: content.width + TaskbarPanel.gap, height: TaskbarPanel.height) // as TaskbarPanel.place

        let container = CALayer()
        container.frame = button.bounds
        container.backgroundColor = Theme().solidBackground
        container.addSublayer(button.layer!)
        Self.display(container)
        assertSnapshot(of: container, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: c.rawValue,
                       testName: "TaskbarButton")
    }

    /// `render(in:)` draws contents that exist; layers drawn in `draw(in:)` (the label) need a display pass first.
    private static func display(_ layer: CALayer) {
        layer.displayIfNeeded()
        layer.sublayers?.forEach(display)
    }
}
