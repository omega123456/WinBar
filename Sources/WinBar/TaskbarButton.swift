import AppKit

/// One taskbar item: window, app item, launcher or overflow ("…"). Layer-backed; layers are
/// updated property by property and nothing animates while idle.
/// Layers inside `body`, back to front: plate · attention plate · progress fill · icon · label · indicator · badge.
/// Only signal animations run (indeterminate sweep, attention pulses), and only while their signal is shown.
final class TaskbarButton: NSView {
    struct Content {
        var item: BarItem?             // nil = overflow button
        var icon: NSImage
        var label: String              // window title, or the app name for an empty title
        var width: CGFloat
        var iconOnly: Bool
        var active = false
        var voiceOver: String
        var badge: Badge? = nil
        var progress: ProgressState? = nil
        var attention = AttentionState.none
        var key: ItemKey { item?.key ?? .overflow }
    }

    weak var controller: BarController?
    private(set) var content = Content(item: nil, icon: NSImage(), label: "", width: 44, iconOnly: true, voiceOver: "")
    var key: ItemKey { content.key }

    private let body = CALayer()        // scaled / shadowed while lifted
    private let plate = CALayer()
    private let iconLayer = CALayer()
    private let label = LabelLayer()
    private let indicator = CALayer()
    private let attnPlate = CALayer()
    private let progressClip = CALayer() // full button, radius 4
    private let progressFill = CALayer()
    private let progressLine = CALayer() // 2 pt along the fill's bottom edge
    private let badge = CALayer()
    private var sweepWidth: CGFloat = 0  // button width the running sweep was built for (0 = none)
    private var pulseSince: CFAbsoluteTime?
    private var theme = Theme()
    private var configured = false     // first update() sets every layer
    private var hovering = false
    private var pressed = false
    private var lifted = false
    private var dragging = false
    private var downX: CGFloat = 0

    private var isWindow: Bool { if case .window = content.item?.kind { return true } else { return false } }
    private var hasIndicator: Bool {
        guard let kind = content.item?.kind else { return false }
        if case .launcher = kind { return false }
        return true
    }
    private var showsLabel: Bool { isWindow && !content.iconOnly }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        body.masksToBounds = false
        plate.cornerRadius = 4
        plate.shadowColor = .black
        plate.shadowOffset = CGSize(width: 0, height: -1)
        plate.shadowRadius = 1
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.minificationFilter = .trilinear
        label.masksToBounds = true // hard clip, no ellipsis
        indicator.cornerRadius = 1.5
        attnPlate.cornerRadius = 4
        attnPlate.borderWidth = 1 // inset edge
        progressClip.cornerRadius = 4
        progressClip.masksToBounds = true
        progressClip.addSublayer(progressFill)
        progressFill.addSublayer(progressLine)
        badge.shadowColor = .black // 0 / 0.5 / 1.5 black 30%
        badge.shadowOpacity = 0.3
        badge.shadowOffset = CGSize(width: 0, height: -0.5)
        badge.shadowRadius = 0.75
        for l in [plate, attnPlate, progressClip, iconLayer, label, indicator, badge] { body.addSublayer(l) }
        layer?.addSublayer(body)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Updates

    func update(_ c: Content, theme: Theme) {
        let old = content, oldTheme = self.theme, wasConfigured = configured
        content = c
        self.theme = theme
        configured = true
        // Width change: plate, label clip, icon and badge glide with the frame the panel animates.
        // Setting the same values again below without actions doesn't cancel these animations.
        if wasConfigured && c.width != old.width && !theme.reduceMotion {
            CATransaction.begin()
            CATransaction.setAnimationDuration(TaskbarPanel.resizeDuration)
            CATransaction.setAnimationTimingFunction(TaskbarPanel.resizeTiming)
            layoutLayers()
            CATransaction.commit()
        }
        Self.noAnimation {
            if !wasConfigured || c.icon !== old.icon { setIcon() }
            if !wasConfigured || c.label != old.label { label.string = c.label }
            if !wasConfigured || oldTheme != theme { label.color = theme.text }
            layoutLayers()
            refreshPlate()
            if !wasConfigured || c.badge != old.badge || oldTheme != theme { setBadgeImage() }
            refreshSignals()
        }
        // A button that just became active (incl. a new one) grows its indicator 6 → 16 pt.
        refreshIndicator(animate: c.active && !old.active && !theme.reduceMotion)
        setAccessibilityLabel(c.voiceOver)
    }

    func setLifted(_ on: Bool) {
        lifted = on
        dragging = dragging && on
        layer?.zPosition = on ? 1 : 0 // above its neighbours while lifted
        Self.noAnimation {
            body.transform = on ? CATransform3DMakeScale(1.02, 1.02, 1) : CATransform3DIdentity
            body.opacity = on ? 0.9 : 1
            body.shadowColor = .black
            body.shadowOpacity = on ? 0.22 : 0
            body.shadowRadius = 6
            body.shadowOffset = CGSize(width: 0, height: -4)
            body.shadowPath = on ? CGPath(roundedRect: plate.frame, cornerWidth: 4, cornerHeight: 4, transform: nil) : nil
            refreshPlate()
        }
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        Self.noAnimation { layoutLayers() }
        refreshIndicator(animate: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        Self.noAnimation {
            label.contentsScale = window?.backingScaleFactor ?? 2
            setIcon()
            setBadgeImage()
        }
    }

    private func setIcon() {
        let scale = window?.backingScaleFactor ?? 2
        iconLayer.contentsScale = scale
        iconLayer.contents = content.icon.iconContents
    }

    /// The visible 40 pt plate inside the hit rect (the view's bounds: full bar height, gap / 2 wider each side,
    /// so pointing anywhere above, below or beside the plate, down to the screen edge, is this button — Fitts's law).
    var plateRect: CGRect { CGRect(x: TaskbarPanel.gap / 2, y: TaskbarPanel.rowMidY - 20, width: content.width, height: 40) }

    private func layoutLayers() {
        body.frame = plateRect
        let b = CGRect(x: 0, y: 0, width: content.width, height: 40)
        plate.frame = b
        plate.shadowPath = CGPath(roundedRect: b, cornerWidth: 4, cornerHeight: 4, transform: nil)
        let size: CGFloat = content.item == nil ? 16 : 24
        let iconX = showsLabel ? 8 : floor((b.width - size) / 2)
        // macOS app icons keep ~10% transparent margin per side (824 of 1024 on the Big Sur grid); Win11 icons fill
        // their 24 px. Drawn at 30 pt, centred on the 24 pt slot, the artwork measures ~24 pt like the reference.
        // ponytail: full-bleed (pre-Big Sur style) icons come out ~25% larger; trim alpha bounds if that bothers.
        let drawn = content.item == nil ? size : 30
        iconLayer.frame = CGRect(x: iconX - (drawn - size) / 2, y: (b.height - drawn) / 2, width: drawn, height: drawn)
        label.isHidden = !showsLabel
        let lineHeight = ceil(Fonts.label.ascender - Fonts.label.descender + Fonts.label.leading)
        label.frame = CGRect(x: 40, y: floor((b.height - lineHeight) / 2), width: max(0, b.width - 50), height: lineHeight)
        label.contentsScale = window?.backingScaleFactor ?? 2
        attnPlate.frame = b
        progressClip.frame = b
        // Badge centre (top-left origin): (icon x + 21, 10); the 8 pt dot (icon x + 23, 9). = (29 | 31, 10) / (31 | 33, 9).
        let dot = content.badge?.glyph == nil
        let c = CGPoint(x: iconX + (dot ? 23 : 21), y: b.height - (dot ? 9 : 10))
        badge.frame = CGRect(x: c.x - badge.bounds.width / 2, y: c.y - badge.bounds.height / 2,
                             width: badge.bounds.width, height: badge.bounds.height)
    }

    /// macOS Dock style: 14 pt system-red circle / pill (4 pt padding) with an SF 9.5 medium white glyph, or an 8 pt dot.
    private func setBadgeImage() {
        guard let b = content.badge else { badge.contents = nil; return }
        let color = NSColor(cgColor: theme.badge) ?? .systemRed
        let image: NSImage
        if let text = b.glyph {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .medium), .foregroundColor: NSColor.white]
            let s = (text as NSString).size(withAttributes: attrs)
            image = NSImage(size: NSSize(width: max(14, ceil(s.width) + 8), height: 14), flipped: false) { r in
                color.setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
                (text as NSString).draw(at: NSPoint(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2), withAttributes: attrs)
                return true
            }
        } else {
            image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
                color.setFill()
                NSBezierPath(ovalIn: r).fill()
                return true
            }
        }
        let scale = window?.backingScaleFactor ?? 2
        badge.contentsScale = scale
        badge.contents = image.layerContents(forContentsScale: scale)
        badge.bounds = CGRect(origin: .zero, size: image.size)
        layoutLayers()
    }

    /// Badge, progress fill and attention plate. Called inside noAnimation; adds or removes only the
    /// sweep / pulse animations, so a re-render never restarts them.
    private func refreshSignals() {
        badge.isHidden = content.badge == nil

        let w = content.width
        if let p = content.progress {
            progressClip.isHidden = false
            progressFill.backgroundColor = theme.progressFill(paused: p.paused)
            progressLine.backgroundColor = theme.progressLine(paused: p.paused)
            let fillWidth = p.fraction.map { round(w * min(1, max(0, $0))) } ?? round(w * 0.25)
            progressFill.frame = CGRect(x: 0, y: 0, width: fillWidth, height: 40)
            progressLine.frame = CGRect(x: 0, y: 0, width: fillWidth, height: 2)
            if p.fraction == nil && !p.paused && !theme.reduceMotion { // indeterminate: 25% segment, left → right every 1.2 s
                if sweepWidth != w {
                    let sweep = CABasicAnimation(keyPath: "position.x")
                    sweep.fromValue = -fillWidth / 2
                    sweep.toValue = w + fillWidth / 2
                    sweep.duration = 1.2
                    sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    sweep.repeatCount = .infinity
                    progressFill.add(sweep, forKey: "sweep")
                    sweepWidth = w
                }
            } else {
                stopSweep() // still at the left edge with Reduce Motion or paused
            }
        } else {
            progressClip.isHidden = true
            stopSweep()
        }

        attnPlate.backgroundColor = theme.attentionPlate
        attnPlate.borderColor = theme.attentionEdge
        attnPlate.isHidden = content.attention == .none
        if case .pulsing(let since) = content.attention, !theme.reduceMotion {
            guard pulseSince != since else { return }
            // Plate ⇄ transparent, ~1.06 s per pulse, phase-locked to the request start (Signals ends it).
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [1, 0, 1]
            pulse.keyTimes = [0, 0.5, 1]
            pulse.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            pulse.duration = Signals.pulse
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() - (CFAbsoluteTimeGetCurrent() - since)
            attnPlate.add(pulse, forKey: "pulse")
            pulseSince = since
        } else if pulseSince != nil {
            attnPlate.removeAnimation(forKey: "pulse")
            pulseSince = nil
        }
    }

    private func stopSweep() {
        guard sweepWidth != 0 else { return }
        progressFill.removeAnimation(forKey: "sweep")
        sweepWidth = 0
    }

    private func refreshPlate() {
        let fill: CGColor
        var edge = false
        if lifted {
            fill = theme.active
        } else if content.active {
            fill = hovering || pressed ? theme.activeHover : theme.active
            edge = true
        } else if pressed {
            fill = theme.pressed
        } else if hovering {
            fill = theme.hover
        } else {
            fill = .clear
        }
        Self.noAnimation {
            plate.backgroundColor = fill
            plate.borderWidth = edge ? 1 : 0          // CALayer borders are drawn inside: an inset edge
            plate.borderColor = theme.activeEdge
            plate.shadowOpacity = edge ? theme.activeShadowOpacity : 0
        }
    }

    /// 3 pt pill, 1 pt above the bottom edge, centred under the icon (labelled) or the button.
    /// Running: 6 pt grey. Active: 16 pt accent, grown from 6 pt over 200 ms ease-out.
    /// Attention: 16 pt red while flashing or held.
    private func refreshIndicator(animate: Bool) {
        let attention = content.attention != .none
        let width: CGFloat = content.active || attention ? 16 : 6
        let cx = showsLabel ? 20 : content.width / 2
        let color = attention ? theme.attentionIndicator : content.active ? theme.accent : theme.runIndicator
        Self.noAnimation {
            indicator.isHidden = !hasIndicator
            indicator.frame = CGRect(x: cx - width / 2, y: 1, width: width, height: 3)
            indicator.backgroundColor = color
        }
        guard animate, hasIndicator else { return }
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 6
        grow.toValue = 16
        let tint = CABasicAnimation(keyPath: "backgroundColor")
        tint.fromValue = theme.runIndicator
        tint.toValue = color
        let group = CAAnimationGroup()
        group.animations = [grow, tint]
        group.duration = 0.2
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        indicator.add(group, forKey: "grow")
    }

    private static func noAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Input (WinBar is never active: always-active tracking, first click accepted, no tooltips)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refreshPlate(); controller?.hover(self, true) }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshPlate(); controller?.hover(self, false) }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        dragging = false
        downX = event.locationInWindow.x
        refreshPlate()
    }

    override func mouseDragged(with event: NSEvent) {
        guard content.item != nil, let panel = window as? TaskbarPanel else { return }
        let dx = event.locationInWindow.x - downX
        if !dragging {
            guard abs(dx) >= 4 else { return } // drag threshold, horizontal only
            dragging = true
            pressed = false
            refreshPlate()
            panel.dragBegan(self)
        }
        panel.dragMoved(self, dx: dx)
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        refreshPlate()
        if dragging {
            dragging = false
            (window as? TaskbarPanel)?.dragEnded(self)
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            controller?.clicked(self)
        }
    }

    override func rightMouseDown(with event: NSEvent) { controller?.rightClicked(self, event) }
    override func otherMouseDown(with event: NSEvent) {} // middle-click does nothing
    override func otherMouseUp(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        controller?.clicked(self)
        return true
    }

    /// The overflow glyph: three 1.2 pt-radius dots in a 16 pt box (mockup's DOTS svg).
    static func dots(color: CGColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(color)
            for x in [3.0, 8.0, 13.0] { ctx.fillEllipse(in: CGRect(x: x - 1.2, y: 8 - 1.2, width: 2.4, height: 2.4)) }
            return true
        }
    }
}

/// One line of Selawik 12 drawn with font smoothing. CATextLayer leaves it off, which drew the stems
/// visibly thinner than Windows' taskbar text (measured: ~18% less ink at the same weight).
private final class LabelLayer: CALayer {
    var string = "" { didSet { if string != oldValue { setNeedsDisplay() } } }
    var color: CGColor = .black { didSet { setNeedsDisplay() } }
    override var contentsScale: CGFloat { didSet { if contentsScale != oldValue { setNeedsDisplay() } } }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        contentsGravity = .left // a width animation reveals / clips the text instead of stretching it
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            .font: Fonts.label, .foregroundColor: NSColor(cgColor: color) ?? .labelColor]))
        ctx.textPosition = CGPoint(x: 0, y: bounds.height - Fonts.label.ascender) // first-line baseline, as CATextLayer
        CTLineDraw(line, ctx)
    }
}

extension NSImage {
    /// A 128 px raster for icon layers (set `minificationFilter = .trilinear`). `layerContents(forContentsScale:)`
    /// picks the rep nearest the pixel size, so at 1x it takes the 16/32 px app-icon artwork, which carries a grey
    /// rim; downscaling the large artwork looks the same at every scale. The identity CTM keeps it 128 px: without it,
    /// a nil context rasterizes at the main screen's scale.
    var iconContents: CGImage? {
        var r = CGRect(x: 0, y: 0, width: 128, height: 128)
        return cgImage(forProposedRect: &r, context: nil, hints: [.ctm: NSAffineTransform()])
    }
}
