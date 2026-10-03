import AppKit
import ScreenCaptureKit

/// The single shared hover preview (requirements 23–26, Design decision 5). Main thread only;
/// ScreenCaptureKit completions hop to main.
final class PreviewController {
    private static let showDelay: TimeInterval = 0.4, hideDelay: TimeInterval = 0.3, warm: CFTimeInterval = 0.3
    private static let cacheLimit = 32

    private let tracker: WindowTracker
    private let panel = PreviewPanel()
    private var shown: CGWindowID?         // window of the visible preview
    private var hovered: CGWindowID?       // last hovered window button
    private var hoverAt: CFTimeInterval = 0, shownAt: CFTimeInterval = 0
    private var freshReady = false         // the hovered window's capture finished before the preview showed
    private var lastHidden: CFTimeInterval = -.infinity
    private var generation = 0             // bumped on every show/hide so a stale fade-out can't orderOut a re-shown preview
    private var anchor = CGRect.zero       // hovered plate, screen coordinates
    private var screen: NSScreen?
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var cache: [CGWindowID: CGImage] = [:]
    private var lru: [CGWindowID] = []     // least recently used first

    init(tracker: WindowTracker) {
        self.tracker = tracker
        panel.view.onHover = { [weak self] inside in // hovering the preview keeps it open
            guard let self else { return }
            if inside { cancel(&hideTimer) } else { hoverExit() }
        }
        panel.view.onClose = { [weak self] in
            guard let self, let id = shown else { return }
            hideNow()
            tracker.close(id)
        }
    }

    /// Requirement 32: no capture is attempted (and no prompt re-triggered) while this is false.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: Hover timing (requirement 24)

    func hoverEnter(_ id: CGWindowID, plate: CGRect, screen: NSScreen?) {
        cancel(&hideTimer)
        anchor = plate
        self.screen = screen
        guard shown != id else { return }
        cancel(&showTimer)
        hovered = id
        hoverAt = CACurrentMediaTime()
        freshReady = false
        capture(id) // at hover-enter, so the thumbnail is ready when the delay ends
        if shown != nil || hoverAt - lastHidden < Self.warm {
            show(id) // warm switch
        } else {
            showTimer = once(Self.showDelay) { [weak self] in self?.show(id) }
        }
    }

    func hoverExit() {
        cancel(&showTimer)
        cancel(&hideTimer)
        hideTimer = once(Self.hideDelay) { [weak self] in self?.hide() }
    }

    /// Click, drag start, window gone: no fade.
    func hideNow() {
        cancel(&showTimer)
        cancel(&hideTimer)
        hovered = nil
        hide(animated: false)
    }

    /// Window destroyed: drop its thumbnail and its preview.
    func windowRemoved(_ id: CGWindowID) {
        cache[id] = nil
        lru.removeAll { $0 == id }
        if shown == id || hovered == id { hideNow() }
    }

    private func hide(animated: Bool = true) {
        guard shown != nil else { return }
        shown = nil
        lastHidden = CACurrentMediaTime()
        generation += 1
        guard animated else { return panel.orderOut(nil) } // completions are async; the next show resets frame and alpha
        let g = generation
        // A superseded group completes early, so the guard keeps a re-hover mid-fade on screen.
        animate(0.083, CAMediaTimingFunction(name: .linear), alpha: 0) { [weak self] in
            guard let self, generation == g else { return }
            panel.orderOut(nil)
        }
    }

    private func show(_ id: CGWindowID) {
        guard let w = tracker.windows[id], let app = tracker.apps[w.pid] else { return }
        shown = id
        shownAt = CACurrentMediaTime()
        let thumb: PreviewView.Thumb
        if !Self.hasPermission {
            thumb = .unavailable
        } else if let image = cache[id] {
            touch(id)
            thumb = .image(image)
        } else {
            thumb = .icon
        }
        let theme = Theme.current()
        panel.view.set(icon: app.icon, title: w.title.isEmpty ? app.name : w.title, thumb: thumb, theme: theme)
        let f = (screen ?? NSScreen.screens.first)?.frame ?? .zero
        let x = min(max(anchor.midX - PreviewView.size.width / 2, f.minX + 8), f.maxX - PreviewView.size.width - 8)
        let barTop = f.minY + TaskbarPanel.height
        let target = NSRect(origin: NSPoint(x: x, y: barTop + 8), size: PreviewView.size)
        let rm = theme.reduceMotion
        generation += 1
        if panel.isVisible { // warm switch, possibly mid-fade or mid-slide: carry on from where it is
            animate(rm ? 0 : 0.167, CAMediaTimingFunction(controlPoints: 0.55, 0.55, 0, 1), frame: target, alpha: 1) // Fluent point-to-point
        } else {
            // Cold: a 0 pt strip on the bar's top edge grows to full size; the view is pinned to the panel's top,
            // so the preview slides up out of the bar. Reduce Motion: fade only.
            animate(0, nil, frame: rm ? target : NSRect(x: x, y: barTop, width: target.width, height: 0), alpha: rm ? 0 : 1)
            panel.orderFrontRegardless()
            animate(rm ? 0.083 : 0.25, rm ? CAMediaTimingFunction(name: .linear) : CAMediaTimingFunction(controlPoints: 0, 0, 0, 1),
                    frame: target, alpha: 1) { [weak self] in self?.panel.invalidateShadow() } // Fluent direct entrance
        }
        let kind = switch thumb { case .image: freshReady ? "fresh" : "cached"; case .icon: "icon"; case .unavailable: "unavailable" }
        EventLog.write("preview shown id=\(id) \(kind) \(ms(shownAt - hoverAt)) ms after hover-enter")
        if freshReady && hovered == id { EventLog.write("preview thumbnail displayed id=\(id) 0 ms after shown") }
    }

    // MARK: Capture (Design decision 5)

    private func capture(_ id: CGWindowID) {
        guard Self.hasPermission, let w = tracker.windows[id], !w.isMinimized, tracker.apps[w.pid]?.isHidden != true else { return }
        let t0 = CACurrentMediaTime()
        EventLog.write("preview capture start id=\(id)")
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async { [weak self] in
                guard let win = content?.windows.first(where: { $0.windowID == id }), win.frame.width > 0, win.frame.height > 0 else {
                    EventLog.write("preview capture failed id=\(id): not shareable \(error.map { "\($0)" } ?? "")")
                    return
                }
                let config = SCStreamConfiguration()
                let scale = min(2 * PreviewView.thumbSize.width / win.frame.width, 2 * PreviewView.thumbSize.height / win.frame.height, 2)
                config.width = max(1, Int(win.frame.width * scale))
                config.height = max(1, Int(win.frame.height * scale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: config) { image, error in
                    DispatchQueue.main.async { self?.captured(id, image, error, t0) }
                }
            }
        }
    }

    private func captured(_ id: CGWindowID, _ image: CGImage?, _ error: Error?, _ t0: CFTimeInterval) {
        let now = CACurrentMediaTime()
        guard let image, tracker.windows[id] != nil else {
            EventLog.write("preview capture failed id=\(id) after \(ms(now - t0)) ms \(error.map { "\($0)" } ?? "")")
            return
        }
        EventLog.write("preview capture finished id=\(id) in \(ms(now - t0)) ms")
        cache[id] = image
        touch(id)
        if lru.count > Self.cacheLimit { cache[lru.removeFirst()] = nil }
        guard hovered == id else { return }
        if shown == id {
            panel.view.setThumb(.image(image))
            EventLog.write("preview thumbnail displayed id=\(id) \(ms(now - shownAt)) ms after shown, \(ms(now - hoverAt)) ms after hover-enter")
        } else {
            freshReady = true
        }
    }

    private func touch(_ id: CGWindowID) {
        lru.removeAll { $0 == id }
        lru.append(id)
    }

    // MARK: Helpers

    /// Window-level, not layer-level: only the window frame and alpha clip and fade the behind-window blur.
    /// A new group retargets an in-flight one from its current value, so every transition is interruptible.
    private func animate(_ duration: TimeInterval, _ timing: CAMediaTimingFunction?, frame: NSRect? = nil, alpha: CGFloat,
                         done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            if let frame { panel.animator().setFrame(frame, display: true) }
            panel.animator().alphaValue = alpha
        }, completionHandler: done)
    }

    private func once(_ delay: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: delay, repeats: false) { _ in body() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func cancel(_ t: inout Timer?) {
        t?.invalidate()
        t = nil
    }

    private func ms(_ s: CFTimeInterval) -> Int { Int((s * 1000).rounded()) }
}

/// One level above the bars; never key. Clicks arrive through BarClickTap.
final class PreviewPanel: NSPanel {
    let view = PreviewView(frame: NSRect(origin: .zero, size: PreviewView.size))

    init() {
        super.init(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false) // deferred creation stalls the first slide ~100 ms
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true // ponytail: system window shadow, not the exact 0/8/32 16% (needs a transparent margin over the bar)
        isReleasedWhenClosed = false
        animationBehavior = .none
        let root = NSView(frame: view.frame)
        view.autoresizingMask = .minYMargin // pinned to the top: growing the frame upward slides the preview out of the bar
        root.addSubview(view)
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 240 pt wide, 8 pt padding (+1 pt stroke), radius 8: header 24 pt (16 pt icon, Selawik 12 title, X 32×32),
/// 6 pt gap, thumbnail frame 222×139 radius 4 (aspect-fit, centred).
final class PreviewView: NSView {
    enum Thumb { case image(CGImage), icon, unavailable }

    static let thumbSize = CGSize(width: 222, height: 139)
    static let size = NSSize(width: 240, height: 1 + 8 + 24 + 6 + 139 + 8 + 1)

    var onHover: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let luminosity = NSView()       // luminosityBlendMode layer over the blur, as on the bar
    private let chrome = CALayer()          // noise (or solid fill) + 1 pt stroke
    private let iconLayer = CALayer()
    private let title = NSTextField(labelWithString: "")
    private let close = CloseButton()
    private let thumb = CALayer()
    private let fallback = CALayer()        // icon / no-permission plate
    private let fallbackIcon = CALayer()
    private let fallbackText = NSTextField(labelWithString: "Preview unavailable")
    private var appIcon = NSImage()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.frame = bounds
        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = NSImage(size: bounds.size, flipped: false) { r in
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            return true
        }
        addSubview(effect)
        luminosity.frame = bounds
        luminosity.wantsLayer = true
        luminosity.layer?.cornerRadius = 8
        luminosity.layer?.compositingFilter = "luminosityBlendMode"
        addSubview(luminosity)
        let content = NSView(frame: bounds)
        content.wantsLayer = true
        addSubview(content)
        let root = content.layer!
        chrome.frame = bounds
        chrome.cornerRadius = 8
        chrome.borderWidth = 1
        let headerY = bounds.height - 9 - 24
        iconLayer.frame = CGRect(x: 9, y: headerY + 4, width: 16, height: 16)
        iconLayer.contentsGravity = .resizeAspect
        thumb.frame = CGRect(x: 9, y: 9, width: Self.thumbSize.width, height: Self.thumbSize.height)
        thumb.cornerRadius = 4
        thumb.masksToBounds = true
        thumb.contentsGravity = .resizeAspect
        fallback.frame = thumb.frame
        fallback.cornerRadius = 4
        fallback.opacity = 0.85
        fallbackIcon.contentsGravity = .resizeAspect
        fallback.addSublayer(fallbackIcon)
        for l in [chrome, iconLayer, thumb, fallback] { root.addSublayer(l) }

        title.font = Fonts.label
        title.lineBreakMode = .byTruncatingTail // the approved mockup ends long titles in an ellipsis
        let h = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: 33, y: headerY + (24 - h) / 2, width: 205 - 8 - 33, height: h)
        content.addSubview(title)
        close.frame = NSRect(x: bounds.width - 1 - 8 + 6 - 32, y: headerY - 4, width: 32, height: 32)
        close.onPress = { [weak self] in self?.onClose?() }
        content.addSubview(close)
        fallbackText.font = Fonts.label
        fallbackText.alignment = .center
        content.addSubview(fallbackText)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(icon: NSImage, title text: String, thumb t: Thumb, theme: Theme) {
        appearance = theme.appearance
        effect.isHidden = theme.solid
        luminosity.isHidden = theme.solid
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        luminosity.layer?.backgroundColor = theme.flyoutLuminosity
        chrome.backgroundColor = theme.flyout
        chrome.borderColor = theme.flyoutStroke
        fallback.backgroundColor = theme.hover
        appIcon = icon
        iconLayer.contentsScale = scale
        iconLayer.contents = icon.layerContents(forContentsScale: scale)
        CATransaction.commit()
        title.stringValue = text
        title.textColor = NSColor(cgColor: theme.text)
        fallbackText.textColor = NSColor(cgColor: theme.text)
        close.apply(theme)
        close.setVisible(false)
        setThumb(t)
    }

    func setThumb(_ t: Thumb) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let scale = window?.backingScaleFactor ?? 2
        if case .image(let image) = t {
            thumb.contents = image
            thumb.isHidden = false
            fallback.isHidden = true
            fallbackText.isHidden = true
            return
        }
        // 64 pt icon, with "Preview unavailable" 8 pt below when Screen Recording is missing; centred as a group.
        let unavailable = if case .unavailable = t { true } else { false }
        thumb.isHidden = true
        thumb.contents = nil
        fallback.isHidden = false
        fallbackText.isHidden = !unavailable
        let textH = ceil(fallbackText.intrinsicContentSize.height)
        let groupH = 64 + (unavailable ? 8 + textH : 0)
        let iconY = (fallback.bounds.height - groupH) / 2 + groupH - 64
        fallbackIcon.frame = CGRect(x: (fallback.bounds.width - 64) / 2, y: iconY, width: 64, height: 64)
        fallbackIcon.contentsScale = scale
        fallbackIcon.contents = appIcon.layerContents(forContentsScale: scale)
        fallbackText.frame = NSRect(x: fallback.frame.minX, y: fallback.frame.minY + iconY - 8 - textH,
                                    width: fallback.frame.width, height: textH)
    }

    // Only this view and the X take input (BarClickTap delivers to the hit view; labels must never track).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        return close.frame.contains(p) ? close : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }

    // The X is visible only while the pointer is over the preview.
    override func mouseEntered(with event: NSEvent) { close.setVisible(true); onHover?(true) }
    override func mouseExited(with event: NSEvent) { close.setVisible(false); onHover?(false) }
    override func mouseDown(with event: NSEvent) {} // body clicks are swallowed
    override func rightMouseDown(with event: NSEvent) {}
}

/// `xmark` 10 pt in a 32×32 hit area; transparent at rest, bar-button hover fill.
private final class CloseButton: NSView {
    var onPress: (() -> Void)?
    private let glyph = NSImageView()
    private var theme = Theme()
    private var hovering = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        glyph.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        glyph.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Close window")
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ theme: Theme) {
        self.theme = theme
        glyph.contentTintColor = NSColor(cgColor: theme.text)
        refresh()
    }

    func setVisible(_ on: Bool) {
        alphaValue = on ? 1 : 0
        if !on { hovering = false; refresh() }
    }

    private func refresh() { layer?.backgroundColor = hovering ? theme.hover : .clear }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}
