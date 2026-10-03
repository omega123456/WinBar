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

/// Every colour of the bar, resolved once per appearance / accent / accessibility-option change
/// (UI/UX Wireframes: background, state fills, indicators, Increase Contrast table).
struct Theme: Equatable {
    var dark = false
    var contrast = false        // Increase Contrast
    var solid = false           // Reduce Transparency
    var reduceMotion = false
    var accent = rgb(0x0067C0)

    /// Win11 acrylic recipe: blur → luminosity layer (keeps the backdrop's hue/saturation, replaces its
    /// lightness) → tint → noise. Here: `.fullScreenUI` blur, then a solid layer with the public Core Animation
    /// `luminosityBlendMode` compositing filter (verified live: CA blend filters blend with the effect view's
    /// behind-window backdrop), then in light mode a `colorBurnBlendMode` grey layer, then the tint.
    /// Colour burn with grey g gives 1 − (1 − c)/g: it scales every channel's distance from white by 1/g, so the
    /// backdrop's chroma is amplified in proportion while neutrals stay neutral (a `saturationBlendMode` layer
    /// was rejected: it turned white mint #E9FBF3 and warm grey yellow #FEF6D2). Luminosity alpha is 1 because
    /// the old 0.8 let 20% of the dark blur through, which is what made the bar read as grey.
    /// Calibration knobs (owner checkpoint C, retuned 2026-10-03). Measured on screen, macOS 26, stripes
    /// white / black / #0050D0 / #20A040 / owner's wallpaper #253134 / #77AFB0 (the Win11 reference wallpaper,
    /// whose taskbar samples #D2F4F3) / #C8C8C8:
    ///   old light, lum #F3F3F3 @ 0.8:        #F3F5F4 / #E0E2E6 / #DFE8FB / #D7F4D8 / #DDE8E8 / #D8F5F7 / #EEF1F0
    ///   light, lum #F6F6F6 @ 1 + burn #8C8C8C: #F0F3F3 / #EEF2F9 / #EDF2FF / #DEFDDF / #E3F7F7 / #D4FCFF / #EDF3F2
    ///     → #1B1B1B text ≥ 14:1
    ///   old dark, lum #202020 @ 1 + #1C1C1C @ 0.7: #262626 / #252628 / #192746 / #192F19 / #232728 / #1D2A2A
    ///   dark, lum #202020 @ 1 + #1C1C1C @ 0.55:   #262728 / #25282A / #132955 / #103312 / #222A29 / #182D2E
    /// A dark luminosity layer alone over-saturates (blue → #003085); the tint on top calms it.
    static let lightLuminosityAlpha: CGFloat = 1
    static let darkLuminosityAlpha: CGFloat = 1
    static let lightTintAlpha: CGFloat = 0
    static let darkTintAlpha: CGFloat = 0.55

    static func current() -> Theme {
        let ws = NSWorkspace.shared
        var t = Theme()
        t.dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        t.contrast = ws.accessibilityDisplayShouldIncreaseContrast
        t.solid = ws.accessibilityDisplayShouldReduceTransparency
        t.reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        t.appearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor { t.accent = c }
        }
        return t
    }

    var appearance: NSAppearance { NSAppearance(named: dark ? .darkAqua : .aqua)! }

    var luminosity: CGColor { dark ? rgb(0x202020, Self.darkLuminosityAlpha) : rgb(0xF6F6F6, Self.lightLuminosityAlpha) }
    /// colorBurnBlendMode layer (light only): ×1/0.55 chroma boost around white, see the recipe above.
    var chromaBurn: CGColor? { dark ? nil : rgb(0x8C8C8C) }
    var tint: CGColor { dark ? rgb(0x1C1C1C, Self.darkTintAlpha) : rgb(0xF3F3F3, Self.lightTintAlpha) }
    var solidBackground: CGColor { dark ? rgb(0x202020) : rgb(0xF0F0F2) }
    var topBorder: CGColor { contrast ? (dark ? white(0.25) : black(0.25)) : (dark ? white(0.06) : black(0.08)) }
    var text: CGColor { dark ? white(1) : rgb(0x1B1B1B) }
    var hover: CGColor { contrast ? (dark ? white(0.16) : white(0.70)) : (dark ? white(0.09) : white(0.45)) }
    var pressed: CGColor { dark ? white(0.05) : white(0.30) }
    var active: CGColor { dark ? white(contrast ? 0.24 : 0.15) : white(1) }
    var activeHover: CGColor { dark ? white(contrast ? 0.24 : 0.18) : white(1) }
    var activeEdge: CGColor { contrast ? (dark ? white(0.50) : black(0.40)) : (dark ? white(0.14) : black(0.12)) }
    var activeShadowOpacity: Float { dark ? 0 : 0.08 }
    var runIndicator: CGColor { contrast ? (dark ? white(0.80) : black(0.70)) : (dark ? white(0.55) : black(0.45)) }

    // Signals and preview (UI/UX wireframes: Badges, Progress, Attention flashing, Hover preview)
    var badge: CGColor { dark ? rgb(0xFF453A) : rgb(0xFF3B30) }
    func progressFill(paused: Bool) -> CGColor { paused ? rgb(0xFFC800, dark ? 0.50 : 0.55) : rgb(0x06B025, dark ? 0.55 : 0.45) }
    func progressLine(paused: Bool) -> CGColor { paused ? (dark ? rgb(0xFFC800) : rgb(0xE0A800)) : (dark ? rgb(0x2BD14C) : rgb(0x06B025)) }
    var attentionPlate: CGColor { dark ? rgb(0x442726) : rgb(0xFDE7E9) }
    var attentionEdge: CGColor { dark ? rgb(0xFF99A4, 0.2) : rgb(0xC42B1C, 0.2) }
    var attentionIndicator: CGColor { dark ? rgb(0xFF99A4) : rgb(0xC42B1C) }
    var flyout: CGColor { dark ? rgb(0x2C2C2C, solid ? 1 : 0.85) : rgb(0xF9F9F9, solid ? 1 : 0.85) }
    var flyoutStroke: CGColor { dark ? white(0.09) : black(0.07) }
}

/// One bar: borderless non-activating panel at status-bar level, screen width × 48 pt at the bottom.
/// Joins all Spaces but is not full-screen auxiliary, so it stays off full-screen Spaces.
final class TaskbarPanel: NSPanel {
    static let height: CGFloat = 48
    /// gap: between plates in a group. Win11 reference (images/3.png, icons 24 px = scale 1): icon-only pitch 42 px,
    /// "Settings" label end → "wallpapers" icon 18 px = ~7 pad + 8 inset + ~3 gap. Each button's hit rect takes half
    /// of it on either side, so the row has no dead strip (TaskbarButton.hitRect).
    static let edge: CGFloat = 12, gap: CGFloat = 2, groupGap: CGFloat = 12
    /// Row content is centred in the 47 pt below the 1 pt top border (mockup: border-box bar, centred flex row).
    static let rowMidY: CGFloat = (height - 1) / 2

    weak var controller: BarController?
    private let effect = NSVisualEffectView()
    private let luminosity = NSView() // luminosityBlendMode layer over the blur: see Theme.lightLuminosityAlpha
    private let burn = NSView()       // colorBurnBlendMode chroma boost: see Theme.chromaBurn
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
        level = .statusBar
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
        for v in [effect, luminosity, burn, background] as [NSView] {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }
        luminosity.wantsLayer = true
        luminosity.layer?.compositingFilter = "luminosityBlendMode"
        burn.wantsLayer = true
        burn.layer?.compositingFilter = "colorBurnBlendMode"
        effect.material = .fullScreenUI   // least built-in fill: see Theme.lightLuminosityAlpha
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
        burn.isHidden = theme.solid || theme.chromaBurn == nil
        burn.layer?.backgroundColor = theme.chromaBurn
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
            b.onPress = { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
            root.addSubview(b)
            ctaButton = b
            return b
        }()
        label.isHidden = false
        button.isHidden = !cta.showsButton
        label.stringValue = cta.text
        let size = label.intrinsicContentSize
        let buttonSize = button.intrinsicContentSize
        let room = frame.width - Self.edge - x - (cta.showsButton ? buttonSize.width + 10 : 0)
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
        let cx = meX + w / 2 + cdx
        var to = d.from
        for (i, k) in d.keys.enumerated() where i != d.from {
            guard let other = buttons[k] else { continue }
            let mid = d.originX[i] + other.frame.width / 2
            if i < d.from && cx < mid { to = min(to, i) }
            if i > d.from && cx > mid { to = max(to, i) }
        }
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

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if route(type, event) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// true → the event belongs to a bar and was taken. Delivery is async so that a handler never runs
    /// inside the tap callback (a slow one would stall every mouse event until the tap times out).
    private static func route(_ type: CGEventType, _ cg: CGEvent) -> Bool {
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
        let p = NSPoint(x: location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - location.y)
        guard let panel = NSApp.windows.first(where: { ($0 is TaskbarPanel || $0 is PreviewPanel) && $0.isVisible && $0.frame.contains(p) }),
              let root = panel.contentView,
              let view = root.hitTest(root.convert(panel.convertPoint(fromScreen: p), from: nil)) else { return nil }
        // Call to action stays native. PreviewView.hitTest returns only itself or its close button.
        return view is TaskbarButton || view is BarBackgroundView || panel is PreviewPanel ? (panel, view) : nil
    }

    private static func deliver(_ type: CGEventType, _ cg: CGEvent, _ panel: NSWindow, _ view: NSView) {
        let p = panel.convertPoint(fromScreen: NSPoint(x: cg.location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - cg.location.y))
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

/// Tint + 3% noise (or the solid Reduce Transparency colour) + 1 pt top border, drawn once per
/// size/theme change. Also the target for right-clicks on empty bar space.
final class BarBackgroundView: NSView {
    weak var panel: TaskbarPanel?
    var theme = Theme() { didSet { needsDisplay = true } }

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
