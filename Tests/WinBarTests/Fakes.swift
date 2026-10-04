import AppKit
import Testing
@testable import WinBar

/// Every test that swaps the global seams (`Env`, `AX.backend`, …) is nested in this suite, so none run concurrently.
@Suite(.serialized) struct Desktop {}

/// The app bundle registers Selawik through ATSApplicationFontsPath; tests must do it before anything first reads
/// `Fonts.label` (a static: a read before registration falls back to the system font for the whole run).
let fontsRegistered: Void = {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Fonts")
    for name in ["Selawik-Regular", "Selawik-Semibold"] {
        CTFontManagerRegisterFontsForURL(dir.appendingPathComponent("\(name).ttf") as CFURL, .process, nil)
    }
}()

/// A display far off the real desktop: panels and previews created for it are real windows nobody sees or clicks.
final class FakeScreen: NSScreen {
    let id: CGDirectDisplayID
    var rect: NSRect
    var visible: NSRect

    init(id: CGDirectDisplayID, frame: NSRect, visible: NSRect? = nil) {
        self.id = id
        rect = frame
        self.visible = visible ?? frame
        super.init()
    }

    override var frame: NSRect { rect }
    override var visibleFrame: NSRect { visible }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] { [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: id)] }
}

final class FakeApp: NSRunningApplication, @unchecked Sendable {
    let pid: pid_t
    let bundle: String?
    let name: String?
    var fakeHidden = false, fakeTerminated = false, fakePolicy = NSApplication.ActivationPolicy.regular
    var unhides = 0, terminates = 0

    init(_ pid: pid_t, _ bundle: String?, _ name: String? = nil) {
        self.pid = pid
        self.bundle = bundle
        self.name = name
        super.init()
    }

    override var processIdentifier: pid_t { pid }
    override var bundleIdentifier: String? { bundle }
    override var localizedName: String? { name }
    override var activationPolicy: NSApplication.ActivationPolicy { fakePolicy }
    override var isTerminated: Bool { fakeTerminated }
    override var isHidden: Bool { fakeHidden }
    override var launchDate: Date? { Date(timeIntervalSince1970: TimeInterval(pid)) }
    override var bundleURL: URL? { nil }
    override var icon: NSImage? { nil }
    override func unhide() -> Bool { unhides += 1; return true }
    override func terminate() -> Bool { terminates += 1; return true }
}

/// Own notification center (system workspace events never arrive), no real app launches or URL opens.
final class FakeWorkspace: NSWorkspace {
    let center = NotificationCenter()
    var apps: [NSRunningApplication] = []
    var front: NSRunningApplication?
    var opened: [URL] = []
    var contrast = false, solid = false, reduceMotion = false

    override var notificationCenter: NotificationCenter { center }
    override var runningApplications: [NSRunningApplication] { apps }
    override var frontmostApplication: NSRunningApplication? { front }
    override var accessibilityDisplayShouldIncreaseContrast: Bool { contrast }
    override var accessibilityDisplayShouldReduceTransparency: Bool { solid }
    override var accessibilityDisplayShouldReduceMotion: Bool { reduceMotion }
    override func open(_ url: URL) -> Bool { opened.append(url); return true }
    override func openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration,
                                  completionHandler: ((NSRunningApplication?, (any Error)?) -> Void)?) {
        opened.append(url)
    }

    func post(_ name: Notification.Name, _ app: NSRunningApplication? = nil) {
        center.post(name: name, object: self, userInfo: app.map { [NSWorkspace.applicationUserInfoKey: $0] })
    }
}

/// An in-memory Accessibility world behind `AX.backend`. Elements are distinct AXUIElement refs (application
/// elements of unused pids); `pids` says which app each belongs to.
final class FakeAX {
    var attrs: [AXUIElement: [String: CFTypeRef]] = [:]
    var failing: [AXUIElement: AXError] = [:] // every call on the element returns this
    var windowIDs: [AXUIElement: CGWindowID] = [:]
    var pids: [AXUIElement: pid_t] = [:]
    var sets: [(element: AXUIElement, attribute: String)] = []
    var performed: [(element: AXUIElement, action: String)] = []
    var registered: [(element: AXUIElement, notification: String)] = []
    var noObserver = Set<pid_t>()
    var trusted = true
    private var callbacks: [pid_t: AXObserverCallback] = [:]
    private var refcon: UnsafeMutableRawPointer?
    private var next: pid_t = 95_000
    private let observer: AXObserver = {
        var o: AXObserver?
        AXObserverCreate(getpid(), { _, _, _, _ in }, &o)
        return o!
    }()

    static let missing: CFTypeRef = { var e = AXError.noValue; return AXValueCreate(.axError, &e)! }()

    func element(of pid: pid_t) -> AXUIElement {
        next += 1
        let el = AXUIElementCreateApplication(next)
        pids[el] = pid
        return el
    }

    /// Delivers an AX notification the way an AXObserver would.
    func post(_ notification: String, _ el: AXUIElement) {
        guard let pid = pids[el], let cb = callbacks[pid], let refcon else { return }
        cb(observer, el, notification as CFString, refcon)
    }

    var backend: AX.Backend {
        var b = AX.Backend()
        b.copy = { [unowned self] el, attr in
            if let e = failing[el] { return (e, nil) }
            guard let v = attrs[el]?[attr] else { return (.noValue, nil) }
            return (.success, v)
        }
        b.copyMultiple = { [unowned self] el, list in
            if let e = failing[el] { return (e, nil) }
            guard let a = attrs[el] else { return (.failure, nil) }
            return (.success, list.map { a[$0] ?? Self.missing } as CFArray)
        }
        b.set = { [unowned self] el, attr, v in
            if let e = failing[el] { return e }
            sets.append((el, attr))
            attrs[el, default: [:]][attr] = v
            return .success
        }
        b.perform = { [unowned self] el, action in
            if let e = failing[el] { return e }
            performed.append((el, action))
            return .success
        }
        b.windowID = { [unowned self] in windowIDs[$0] }
        b.pid = { [unowned self] in pids[$0] ?? 0 }
        b.createObserver = { [unowned self] pid, cb in
            if noObserver.contains(pid) { return nil }
            callbacks[pid] = cb
            return observer
        }
        b.addNotification = { [unowned self] _, el, n, refcon in
            if let e = failing[el] { return e }
            self.refcon = refcon
            registered.append((el, n))
            return .success
        }
        b.isTrusted = { [unowned self] _ in trusted }
        return b
    }
}

func axPoint(_ p: CGPoint) -> CFTypeRef { var p = p; return AXValueCreate(.cgPoint, &p)! }
func axSize(_ s: CGSize) -> CFTypeRef { var s = s; return AXValueCreate(.cgSize, &s)! }

/// Lets main-queue work (flushes, timers, async deliveries) run.
func settle(_ seconds: Double = 0.15) async { try? await Task.sleep(for: .seconds(seconds)) }

/// The real implementations behind the seams that are safe to call from a test (read-only), kept before any test
/// replaces them.
let liveSeams = (onScreen: WindowTracker.onScreenWindowIDs, spaces: WindowTracker.managedDisplaySpaces,
                 permission: PreviewController.checkPermission)

/// Installs fresh fakes behind every seam. One per test.
@MainActor
final class Harness {
    let ws = FakeWorkspace()
    let ax = FakeAX()
    let main = FakeScreen(id: 4242, frame: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
                          visible: NSRect(x: -20000, y: -20000, width: 1200, height: 775))
    let side = FakeScreen(id: 4243, frame: NSRect(x: -18800, y: -20000, width: 400, height: 800))
    var screens: [NSScreen]
    var onScreen = Set<CGWindowID>()
    var spaces: [[String: Any]] = []
    var menus: [NSMenu] = []
    /// Runs inside the (fake) modal menu tracking: pick an item with `choose`.
    var onMenu: ((NSMenu) -> Void)?
    var permission = true
    var captures: [CGWindowID] = []
    var image: CGImage? = Harness.makeImage()
    var notices: [String] = []
    let dir: URL

    init() {
        _ = fontsRegistered
        _ = liveSeams
        _ = NSApplication.shared
        screens = [main]
        // Panels and previews from earlier tests must not catch the click tap's hit tests.
        for w in NSApp.windows where w is TaskbarPanel || w is PreviewPanel { w.orderOut(nil) }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("WinBarTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "local.winbar.tests")!
        defaults.removePersistentDomain(forName: "local.winbar.tests")
        defaults.set(true, forKey: "screenRecordingRequested") // never the real Screen Recording prompt

        Env.workspace = ws
        Env.screens = { [unowned self] in screens }
        Env.defaults = defaults
        AX.backend = ax.backend
        AX.onAPIDisabled = nil
        AX.isWindowIDAvailable = true
        WindowTracker.onScreenWindowIDs = { [unowned self] in onScreen }
        WindowTracker.managedDisplaySpaces = { [unowned self] in spaces }
        BarController.trackMenu = { [unowned self] menu, _ in menus.append(menu); onMenu?(menu) }
        BarClickTap.isPaused = false
        BarClickTap.onMenuClick = nil
        PreviewController.checkPermission = { [unowned self] in permission }
        PreviewController.captureWindow = { [unowned self] id, done in
            captures.append(id)
            let image = image
            DispatchQueue.main.async { done(image, image == nil ? CocoaError(.featureUnsupported) : nil) }
        }
        Signals.downloadsFolder = dir
        Signals.pidOfASN = { ($0 as? NSNumber)?.int32Value }
        Updater.isInstallable = false
        Updater.bundleURL = dir.appendingPathComponent("WinBar.app")
        Updater.notice = { [unowned self] header, _ in notices.append(header) }
        Updater.ask = { _, _ in }
        Updater.verify = { _ in }
        Updater.relaunch = { _ in }
        EventLog.url = dir.appendingPathComponent("events.log")
        EventLog.enable()
    }

    var log: String { (try? String(contentsOf: EventLog.url, encoding: .utf8)) ?? "" }

    /// A running regular app with its AX application element.
    @discardableResult
    func app(_ pid: pid_t, _ bundle: String?, _ name: String? = nil, running: Bool = true) -> FakeApp {
        let a = FakeApp(pid, bundle, name ?? bundle)
        if running { ws.apps.append(a) }
        let el = AXUIElementCreateApplication(pid)
        ax.pids[el] = pid
        ax.attrs[el, default: [:]][kAXWindowsAttribute] = [] as CFArray
        return a
    }

    func element(_ app: FakeApp) -> AXUIElement { AXUIElementCreateApplication(app.pid) }

    /// A standard window at a Cocoa frame; `listed` puts it in the app's AXWindows and the on-screen list.
    @discardableResult
    func window(_ id: CGWindowID, of app: FakeApp, _ title: String = "", frame: CGRect? = nil,
                minimized: Bool = false, listed: Bool = true) -> AXUIElement {
        let el = ax.element(of: app.pid)
        ax.windowIDs[el] = id
        setFrame(el, frame ?? CGRect(x: main.frame.minX + 100, y: main.frame.minY + 200, width: 400, height: 300))
        ax.attrs[el]![kAXSubroleAttribute] = kAXStandardWindowSubrole as CFString
        ax.attrs[el]![kAXTitleAttribute] = title as CFString
        ax.attrs[el]![kAXMinimizedAttribute] = minimized ? kCFBooleanTrue : kCFBooleanFalse
        ax.attrs[el]!["AXFullScreen"] = kCFBooleanFalse
        if listed {
            let appEl = element(app)
            let list = (ax.attrs[appEl]?[kAXWindowsAttribute] as? [AnyObject]) ?? []
            ax.attrs[appEl]![kAXWindowsAttribute] = (list + [el]) as CFArray
            onScreen.insert(id)
        }
        return el
    }

    func setFrame(_ el: AXUIElement, _ cocoa: CGRect) {
        let h = screens.first?.frame.height ?? 0
        ax.attrs[el, default: [:]][kAXPositionAttribute] = axPoint(CGPoint(x: cocoa.minX, y: h - cocoa.maxY))
        ax.attrs[el]![kAXSizeAttribute] = axSize(cocoa.size)
    }

    /// Highlights the item titled `title` and clicks it, as BarClickTap would while the menu tracks.
    static func choose(_ title: String, in menu: NSMenu) {
        let item = menu.items.first { $0.title == title }
        menu.delegate?.menu?(menu, willHighlight: item)
        BarClickTap.onMenuClick?()
    }

    static func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }
}

/// A mouse event in `window` at a point in the view's coordinates.
@MainActor
func mouse(_ type: NSEvent.EventType, at p: NSPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                       windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
}
