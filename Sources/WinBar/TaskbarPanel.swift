import AppKit

/// sRGB colour from a 0xRRGGBB literal.
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

private func white(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
private func black(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }

enum Fonts {
    /// PostScript names verified from the bundled TTFs (registered via ATSApplicationFontsPath).
    static let label = NSFont(name: "Selawik-Regular", size: 12) ?? .systemFont(ofSize: 12)
    static let semibold = NSFont(name: "Selawik-Semibold", size: 12) ?? .systemFont(ofSize: 12, weight: .semibold)
}

/// Every colour of the bar, resolved once per accent / accessibility-option change. One theme only: the
/// Win11 dark taskbar, whatever the macOS light/dark setting (UI/UX Wireframes: dark column + Increase Contrast).
struct Theme: Equatable {
    var contrast = false        // Increase Contrast
    var solid = false           // Reduce Transparency
    var reduceMotion = false
    var accent = rgb(0x0067C0)

    /// Win11 acrylic recipe: blur → luminosity layer (keeps the backdrop's hue/saturation, replaces its
    /// lightness) → tint → noise. Here: `.fullScreenUI` blur, then a solid layer with the public Core Animation
    /// `luminosityBlendMode` compositing filter (verified live: CA blend filters blend with the effect view's
    /// behind-window backdrop), then the tint. Luminosity alpha is 1: lower lets the blur's own lightness through.
    /// Calibration knobs (owner checkpoint C, retuned 2026-10-03). Measured on screen, macOS 26, stripes
    /// white / black / #0050D0 / #20A040 / owner's wallpaper #253134 / #77AFB0:
    ///   old, lum #202020 @ 1 + #1C1C1C @ 0.7: #262626 / #252628 / #192746 / #192F19 / #232728 / #1D2A2A
    ///   lum #202020 @ 1 + #1C1C1C @ 0.55:      #262728 / #25282A / #132955 / #103312 / #222A29 / #182D2E
    /// The 0.55 tint washed colour out (Calculator orange #FF9200 behind → #291D11; @ 0.2 → #321D08). Now no tint:
    /// orange → #361D02, the most chroma the luminosity blend allows at this lightness, as on the Win11 dark
    /// taskbar (owner's reference reds ~#46141A at the same luminance). Raise the tint to calm it again.
    static let luminosityAlpha: CGFloat = 1
    static let tintAlpha: CGFloat = 0
    static let appearance = NSAppearance(named: .darkAqua)!

    static func current() -> Theme {
        let ws = Env.workspace
        var t = Theme()
        t.contrast = ws.accessibilityDisplayShouldIncreaseContrast
        t.solid = ws.accessibilityDisplayShouldReduceTransparency
        t.reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        appearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor { t.accent = c }
        }
        return t
    }

    var appearance: NSAppearance { Self.appearance }

    var luminosity: CGColor { rgb(0x202020, Self.luminosityAlpha) }
    var tint: CGColor { rgb(0x1C1C1C, Self.tintAlpha) }
    var solidBackground: CGColor { rgb(0x202020) }
    var topBorder: CGColor { white(contrast ? 0.25 : 0.06) }
    var divider: CGColor { white(contrast ? 0.25 : 0.15) } // pinned | other, owner-picked from 6–15% previews
    var text: CGColor { white(1) }
    var hover: CGColor { white(contrast ? 0.16 : 0.09) }
    var pressed: CGColor { white(0.05) }
    var active: CGColor { white(contrast ? 0.24 : 0.15) }
    var activeHover: CGColor { white(contrast ? 0.24 : 0.18) }
    var activeEdge: CGColor { white(contrast ? 0.50 : 0.14) }
    var activeShadowOpacity: Float { 0 }
    var runIndicator: CGColor { white(contrast ? 0.80 : 0.55) }

    // Signals and preview (UI/UX wireframes: Badges, Progress, Attention flashing, Hover preview)
    var badge: CGColor { rgb(0xFF453A) }
    func progressFill(paused: Bool) -> CGColor { paused ? rgb(0xFFC800, 0.50) : rgb(0x06B025, 0.55) }
    func progressLine(paused: Bool) -> CGColor { paused ? rgb(0xFFC800) : rgb(0x2BD14C) }
    var attentionPlate: CGColor { rgb(0x442726) }
    var attentionEdge: CGColor { rgb(0xFF99A4, 0.2) }
    var attentionIndicator: CGColor { rgb(0xFF99A4) }
    /// Hover preview: same acrylic stack as the bar, lighter luminosity (Win11 flyout #2C2C2C), no tint.
    /// Over the reference's blue wallpaper the Win11 preview keeps a visible hue; lower it to darken the body.
    var flyoutLuminosity: CGColor { rgb(0x2C2C2C) }
    var flyout: CGColor { solid ? rgb(0x2C2C2C) : BarBackgroundView.noiseFill }
    var flyoutStroke: CGColor { white(0.09) }
}

/// One bar: borderless non-activating panel just below main-menu level, screen width × 48 pt at the bottom.
/// Joins all Spaces but is not full-screen auxiliary, so it stays off full-screen Spaces.
final class TaskbarPanel: NSPanel {
    static let height: CGFloat = 48
    /// gap: between plates in a group. Win11 reference (images/3.png, icons 24 px = scale 1): icon-only pitch 42 px,
    /// "Settings" label end → "wallpapers" icon 18 px = ~7 pad + 8 inset + ~3 gap. Each button's hit rect takes half
    /// of it on either side, so the row has no dead strip (TaskbarButton.hitRect).
    static let edge: CGFloat = 12, gap: CGFloat = 2, groupGap: CGFloat = 12
    /// Row content is centred in the 47 pt below the 1 pt top border (mockup: border-box bar, centred flex row).
    static let rowMidY: CGFloat = (height - 1) / 2
    #if DEBUG
    /// WinBar Dev stamp, drawn by BarBackgroundView at the right end (clicks on it are bar clicks).
    /// Buttons and the call to action stop `edge` before it.
    static let devStamp = NSAttributedString(string: "DEV", attributes: [.font: Fonts.semibold, .foregroundColor: NSColor.white])
    static let devStampWidth = ceil(devStamp.size().width) + 16
    static let rightReserve = devStampWidth + edge
    #else
    static let rightReserve: CGFloat = 0
    #endif

    weak var controller: BarController?
    private let effect = NSVisualEffectView()
    private let luminosity = NSView() // luminosityBlendMode layer over the blur: see Theme.luminosityAlpha
    private let background = BarBackgroundView()
    private var buttons: [ItemKey: TaskbarButton] = [:]
    private var groups: (pinned: [ItemKey], other: [ItemKey]) = ([], [])
    private var ctaLabel: NSTextField?
    private var ctaButton: CTAButton?
    private var theme = Theme()
    private var drag: Drag?

    var isDragging: Bool { drag != nil }

    init(screen: NSScreen, controller: BarController) {
        super.init(contentRect: Self.frame(for: screen), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.controller = controller
        // Above the Dock (20) and floating windows, below the screenshot thumbnail (24, measured on macOS 26).
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle] // no .fullScreenAuxiliary
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        for v in [effect, luminosity, background] as [NSView] {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }
        luminosity.wantsLayer = true
        luminosity.layer?.compositingFilter = "luminosityBlendMode"
        effect.material = .fullScreenUI   // least built-in fill: see Theme.luminosityAlpha
        effect.blendingMode = .behindWindow
        effect.state = .active            // a never-key panel would otherwise render flat
        background.panel = self
        contentView = root
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func frame(for screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
    }

    func reframe(to screen: NSScreen) {
        let f = Self.frame(for: screen)
        if f != frame { setFrame(f, display: true) }
    }

    func apply(_ theme: Theme) {
        guard theme != self.theme || appearance == nil else { return } // appearance is nil until the first apply
        self.theme = theme
        appearance = theme.appearance
        effect.appearance = theme.appearance
        effect.isHidden = theme.solid
        luminosity.isHidden = theme.solid
        luminosity.layer?.backgroundColor = theme.luminosity
        background.theme = theme
        if let ctaLabel { ctaLabel.textColor = NSColor(cgColor: theme.text) }
        ctaButton?.apply(theme)
    }

    // MARK: Row layout

    /// Diffs buttons by key (created, updated property by property, or removed; never rebuilt wholesale)
    /// and lays out: edge · pinned (gap apart) · groupGap · other + "…" (gap apart) | call to action.
    /// Each button's frame is its hit rect: the full bar height and gap / 2 beyond the plate on both sides.
    func update(pinned: [TaskbarButton.Content], other: [TaskbarButton.Content], overflow: TaskbarButton.Content?,
                cta: (text: String, showsButton: Bool)?) {
        let rest = other + (overflow.map { [$0] } ?? [])
        let keys = Set((pinned + rest).map(\.key))
        for (k, b) in buttons where !keys.contains(k) {
            b.removeFromSuperview()
            buttons[k] = nil
        }
        var x = Self.edge
        func place(_ c: TaskbarButton.Content) {
            let b = buttons[c.key] ?? {
                let b = TaskbarButton()
                b.controller = controller
                contentView?.addSubview(b)
                buttons[c.key] = b
                return b
            }()
            b.update(c, theme: theme)
            let f = NSRect(x: x - Self.gap / 2, y: 0, width: c.width + Self.gap, height: Self.height)
            if b.frame != f { b.frame = f }
            x += c.width + Self.gap
        }
        pinned.forEach(place)
        if !pinned.isEmpty { x += Self.groupGap - Self.gap }
        background.dividerX = pinned.isEmpty || rest.isEmpty ? nil : x - Self.groupGap / 2
        rest.forEach(place)
        groups = (pinned.map(\.key), other.map(\.key))
        layoutCTA(cta, x: x)
    }

    private func layoutCTA(_ cta: (text: String, showsButton: Bool)?, x: CGFloat) {
        guard let cta, let root = contentView else {
            ctaLabel?.isHidden = true
            ctaButton?.isHidden = true
            return
        }
        let label = ctaLabel ?? {
            let l = NSTextField(labelWithString: "")
            l.font = Fonts.label
            l.lineBreakMode = .byTruncatingTail
            l.textColor = NSColor(cgColor: theme.text)
            root.addSubview(l)
            ctaLabel = l
            return l
        }()
        let button = ctaButton ?? {
            let b = CTAButton()
            b.apply(theme)
            b.onPress = { Env.workspace.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
            root.addSubview(b)
            ctaButton = b
            return b
        }()
        label.isHidden = false
        button.isHidden = !cta.showsButton
        label.stringValue = cta.text
        let size = label.intrinsicContentSize
        let buttonSize = button.intrinsicContentSize
        let room = frame.width - Self.edge - Self.rightReserve - x - (cta.showsButton ? buttonSize.width + 10 : 0)
        let width = max(0, min(ceil(size.width), room))
        label.frame = NSRect(x: x, y: Self.rowMidY - size.height / 2, width: width, height: size.height)
        button.frame = NSRect(x: x + width + 10, y: Self.rowMidY - buttonSize.height / 2,
                              width: buttonSize.width, height: buttonSize.height)
    }

    // MARK: Drag to reorder (requirement 20; visuals per the wireframes)

    private struct Drag {
        let button: TaskbarButton
        let group: BarGroup
        let keys: [ItemKey]
        let from: Int
        var to: Int
        let originX: [CGFloat]
    }

    func dragBegan(_ b: TaskbarButton) {
        let (group, keys): (BarGroup, [ItemKey]) = groups.pinned.contains(b.key) ? (.pinned, groups.pinned) : (.other, groups.other)
        guard let from = keys.firstIndex(of: b.key) else { return }
        drag = Drag(button: b, group: group, keys: keys, from: from, to: from,
                    originX: keys.map { buttons[$0]?.frame.minX ?? 0 })
        b.setLifted(true)
    }

    func dragMoved(_ b: TaskbarButton, dx: CGFloat) {
        guard var d = drag, d.button === b, let lastKey = d.keys.last, let last = buttons[lastKey] else { return }
        let meX = d.originX[d.from], w = b.frame.width
        let cdx = max(d.originX[0] - meX, min(d.originX[d.keys.count - 1] + last.frame.width - (meX + w), dx))
        b.setFrameOrigin(NSPoint(x: meX + cdx, y: b.frame.minY))
        let to = Self.dropIndex(originX: d.originX, widths: d.keys.map { buttons[$0]?.frame.width ?? 0 },
                                from: d.from, x: meX + cdx)
        guard to != d.to else { return }
        d.to = to
        drag = d
        let shift = w // frame width = plate + gap
        for (i, k) in d.keys.enumerated() where i != d.from {
            guard let other = buttons[k] else { continue }
            var t: CGFloat = 0
            if d.from < to && i > d.from && i <= to { t = -shift }
            if d.from > to && i >= to && i < d.from { t = shift }
            let p = NSPoint(x: d.originX[i] + t, y: other.frame.minY)
            if theme.reduceMotion {
                other.setFrameOrigin(p)
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .default) // CSS `ease`
                    other.animator().setFrameOrigin(p)
                }
            }
        }
    }

    /// Slot the dragged button (`from`, now at `x`) drops into: it passes a neighbour once its leading edge
    /// crosses that neighbour's centre. The leading edge, not the centre: the drag is clamped to the group's
    /// ends, where the centre can't get past an equal-width or narrower end button.
    static func dropIndex(originX: [CGFloat], widths: [CGFloat], from: Int, x: CGFloat) -> Int {
        var to = from
        for i in originX.indices where i != from {
            let mid = originX[i] + widths[i] / 2
            if i < from && x < mid { to = min(to, i) }
            if i > from && x + widths[from] > mid { to = max(to, i) }
        }
        return to
    }

    func dragEnded(_ b: TaskbarButton) {
        guard let d = drag, d.button === b else { return }
        drag = nil
        b.setLifted(false)
        var keys = d.keys
        keys.insert(keys.remove(at: d.from), at: d.to)
        controller?.reorder(d.group, keys) // re-renders with the final layout
    }
}

/// Bar clicks without activating WinBar (Design decision 1). On macOS 26 a mouse-down on any window
/// activates its app, `.nonactivatingPanel` (WindowServer tag verified set), `.prohibited` policy and every
/// level included: verified with a minimal panel. So mouse buttons over a bar's buttons and empty space are
/// taken out of the session event stream before window routing and delivered to the bar directly.
/// Menus opened this way still take the keyboard (Escape verified). Needs Accessibility (installed once trusted).
enum BarClickTap {
    /// Set while a WinBar menu tracks: clicks then go to the menu (an outside click dismisses it).
    static var isPaused = false
    /// While paused: a click landed on the open WinBar menu. The menu's owner picks the item itself.
    static var onMenuClick: (() -> Void)?
    private static var tap: CFMachPort?
    private static var target: (panel: NSWindow, view: NSView)? // the left mouse-down's view: gets drags and the up
    private static var swallowUps = Set<CGEventType.RawValue>() // ups whose down was taken (right / middle, menu clicks)

    static func install() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback, userInfo: nil) else {
            EventLog.write("bar click tap unavailable")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        tap = t
        EventLog.write("bar click tap installed")
    }

    static let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if route(type, event) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// true → the event belongs to a bar and was taken. Delivery is async so that a handler never runs
    /// inside the tap callback (a slow one would stall every mouse event until the tap times out).
    static func route(_ type: CGEventType, _ cg: CGEvent) -> Bool {
        switch type {
        case .leftMouseDragged, .leftMouseUp:
            guard let t = target else { return type == .leftMouseUp && swallowUps.remove(type.rawValue) != nil }
            if type == .leftMouseUp { target = nil }
            deliver(type, cg, t.panel, t.view)
            return true
        case .rightMouseUp, .otherMouseUp:
            return swallowUps.remove(type.rawValue) != nil
        default: // downs
            // A native click on the menu activates WinBar, which ends menu tracking before the item fires,
            // and a lone up does not select. So the click is taken and the owner fires the highlighted item.
            if isPaused {
                guard type == .leftMouseDown || type == .rightMouseDown, isOverOwnMenu(cg.location) else { return false }
                swallowUps.insert((type == .leftMouseDown ? CGEventType.leftMouseUp : .rightMouseUp).rawValue)
                onMenuClick?()
                return true
            }
            guard let (panel, view) = hit(cg.location) else { return false }
            switch type {
            case .leftMouseDown: target = (panel, view)
            case .rightMouseDown: swallowUps.insert(CGEventType.rightMouseUp.rawValue)
            default: swallowUps.insert(CGEventType.otherMouseUp.rawValue)
            }
            deliver(type, cg, panel, view)
            return true
        }
    }

    /// true if the frontmost on-screen window under a CG global point is a WinBar menu (WinBar-owned, not a bar or preview).
    private static func isOverOwnMenu(_ location: CGPoint) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let top = list.first(where: { info in
            guard let b = info[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return false }
            return r.contains(location)
        }), top[kCGWindowOwnerPID as String] as? pid_t == getpid(),
              let number = top[kCGWindowNumber as String] as? Int else { return false }
        let w = NSApp.window(withWindowNumber: number)
        return !(w is TaskbarPanel || w is PreviewPanel)
    }

    /// The bar or hover-preview view under a CG global point, if it is one the tap handles.
    /// The preview is a WinBar window too: a native click on its X would activate WinBar.
    private static func hit(_ location: CGPoint) -> (NSWindow, NSView)? {
        let p = NSPoint(x: location.x, y: (Env.screens().first?.frame.height ?? 0) - location.y)
        guard let panel = NSApp.windows.first(where: { ($0 is TaskbarPanel || $0 is PreviewPanel) && $0.isVisible && $0.frame.contains(p) }),
              let root = panel.contentView,
              let view = root.hitTest(root.convert(panel.convertPoint(fromScreen: p), from: nil)) else { return nil }
        // Call to action stays native. PreviewView.hitTest returns only itself or its close button.
        return view is TaskbarButton || view is BarBackgroundView || panel is PreviewPanel ? (panel, view) : nil
    }

    private static func deliver(_ type: CGEventType, _ cg: CGEvent, _ panel: NSWindow, _ view: NSView) {
        let p = panel.convertPoint(fromScreen: NSPoint(x: cg.location.x, y: (Env.screens().first?.frame.height ?? 0) - cg.location.y))
        guard let kind = NSEvent.EventType(rawValue: UInt(type.rawValue)), // mouse event types share raw values
              let e = NSEvent.mouseEvent(with: kind, location: p, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(cg.flags.rawValue)),
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                         context: nil, eventNumber: 0,
                                         clickCount: Int(cg.getIntegerValueField(.mouseEventClickState)), pressure: 1)
        else { return }
        DispatchQueue.main.async {
            // Requirement 24: any button down on a bar hides the hover preview at once (click, right-click, drag start).
            if type != .leftMouseDragged && type != .leftMouseUp { (panel as? TaskbarPanel)?.controller?.barMouseDown() }
            switch type {
            case .leftMouseDown: view.mouseDown(with: e)
            case .leftMouseDragged: view.mouseDragged(with: e)
            case .leftMouseUp: view.mouseUp(with: e)
            case .rightMouseDown: view.rightMouseDown(with: e)
            default: view.otherMouseDown(with: e)
            }
        }
    }
}

/// Tint + 3% noise (or the solid Reduce Transparency colour) + 1 pt top border + the 1 × 24 pt divider
/// centred in the pinned | other group gap, drawn once per size/theme/divider change. Also the target for
/// right-clicks on empty bar space.
final class BarBackgroundView: NSView {
    weak var panel: TaskbarPanel?
    var theme = Theme() { didSet { needsDisplay = true } }
    var dividerX: CGFloat? { didSet { if dividerX != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if theme.solid {
            ctx.setFillColor(theme.solidBackground)
            ctx.fill(bounds)
        } else {
            ctx.setFillColor(theme.tint)
            ctx.fill(bounds)
            ctx.draw(Self.noise, in: CGRect(x: 0, y: 0, width: 128, height: 128), byTiling: true)
        }
        ctx.setFillColor(theme.topBorder)
        ctx.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
        if let dividerX {
            ctx.setFillColor(theme.divider)
            ctx.fill(CGRect(x: dividerX - 0.5, y: TaskbarPanel.rowMidY - 12, width: 1, height: 24))
        }
        #if DEBUG
        let pill = CGRect(x: bounds.width - TaskbarPanel.edge - TaskbarPanel.devStampWidth, y: TaskbarPanel.rowMidY - 10,
                          width: TaskbarPanel.devStampWidth, height: 20)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.setFillColor(rgb(0xCA5010))
        ctx.fillPath()
        let s = TaskbarPanel.devStamp.size()
        TaskbarPanel.devStamp.draw(at: NSPoint(x: pill.midX - s.width / 2, y: pill.midY - s.height / 2))
        #endif
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { panel?.controller?.showBarMenu(event, in: self) }

    /// 128×128 tile of mid-grey noise at up to 3% alpha (the mockup's feTurbulence tile).
    private static let noise: CGImage = {
        let n = 128
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<(n * n) {
            let a = Double.random(in: 0...0.03, using: &rng)
            let g = UInt8((0.5 * a * 255).rounded()) // premultiplied grey
            px[i * 4] = g; px[i * 4 + 1] = g; px[i * 4 + 2] = g
            px[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()

    /// The noise tile as a pattern fill, for layers (hover preview).
    static let noiseFill = NSColor(patternImage: NSImage(cgImage: noise, size: NSSize(width: 128, height: 128))).cgColor
}

/// "Open Settings": Selawik Semibold 12, padding 5 × 12 inside a 1 pt edge, radius 4, active plate. Accepts the first click.
final class CTAButton: NSButton {
    var onPress: (() -> Void)?
    private var theme = Theme()

    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        target = self
        action = #selector(press)
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ theme: Theme) {
        self.theme = theme
        layer?.backgroundColor = theme.active
        layer?.borderColor = theme.topBorder
        attributedTitle = NSAttributedString(string: "Open Settings", attributes: [
            .font: Fonts.semibold, .foregroundColor: NSColor(cgColor: theme.text) ?? .labelColor])
    }

    override var intrinsicContentSize: NSSize {
        let s = attributedTitle.size()
        return NSSize(width: ceil(s.width) + 26, height: ceil(s.height) + 12) // padding + 1 pt edge each side
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func press() { onPress?() }
}
