import AppKit
import ApplicationServices

/// One running process with the regular activation policy.
final class TrackedApp {
    let pid: pid_t
    let running: NSRunningApplication
    let element: AXUIElement
    var isHidden: Bool
    var bundleID: String? { running.bundleIdentifier }
    var name: String { running.localizedName ?? running.bundleIdentifier ?? "pid \(pid)" }
    var bundleURL: URL? { running.bundleURL }
    var launchDate: Date { running.launchDate ?? .distantPast }
    lazy var icon: NSImage = running.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

    fileprivate var observer: AXObserver?
    fileprivate var observing = false          // app-level notifications registered
    fileprivate var retries = 0                // observer launch retries used
    fileprivate var newWindowItem: AXUIElement?? // ⌘N cache: .none = not searched yet

    init(_ running: NSRunningApplication) {
        self.running = running
        pid = running.processIdentifier
        element = AXUIElementCreateApplication(pid)
        isHidden = running.isHidden
    }
}

/// One standard window.
final class TrackedWindow {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    var title = ""                          // empty → show the app name
    var frame = CGRect.zero                 // Cocoa global coordinates (bottom-left origin of the primary screen)
    var displayID: CGDirectDisplayID = 0
    var isMinimized = false
    var isOnScreen = false                  // in the on-screen list of the current Space
    fileprivate(set) var isVisible = false  // requirement 8, recomputed on every flush
    var order: Int                          // session order (ascending)
    var lastFocused: CFAbsoluteTime = 0     // MRU; 0 = never focused while tracked

    init(id: CGWindowID, pid: pid_t, element: AXUIElement, order: Int) {
        self.id = id; self.pid = pid; self.element = element; self.order = order
    }
}

/// Single source of truth for apps and windows. Main thread only, event-driven:
/// AX and workspace events mark work as pending; one ~50 ms one-shot flush does the reads
/// and emits at most one `onChange`.
final class WindowTracker {
    private(set) var apps: [pid_t: TrackedApp] = [:]
    private(set) var windows: [CGWindowID: TrackedWindow] = [:]
    /// The focused window of the frontmost app, if it is a tracked window.
    private(set) var activeWindowID: CGWindowID?
    private(set) var isTracking = false
    private(set) var fullScreenDisplays = Set<CGDirectDisplayID>() // requirement 4: no bar on these displays
    /// Called once per coalesced burst that changed the model.
    var onChange: (() -> Void)?
    /// Called for every window that stops being tracked (destroyed or its app quit): evicts its thumbnail.
    var onWindowRemoved: ((CGWindowID) -> Void)?

    // MARK: Model accessors

    /// Visible windows (requirement 8) in session order.
    var visibleWindows: [TrackedWindow] { windows.values.filter(\.isVisible).sorted { $0.order < $1.order } }

    func visibleWindows(onDisplay id: CGDirectDisplayID) -> [TrackedWindow] {
        visibleWindows.filter { $0.displayID == id }
    }

    func app(of window: TrackedWindow) -> TrackedApp? { apps[window.pid] }

    // MARK: Pending work

    private var flushScheduled = false
    private var newElements: [(pid_t, AXUIElement)] = []
    private var rescanPids = Set<pid_t>()
    private var dirtyWindows = Set<CGWindowID>()
    private var focusPids = Set<pid_t>()
    private var refreshOnScreen = false
    private var forcedOnScreen = Set<CGWindowID>()  // created / de-minimized: on screen even if CG lags
    private var timedOut = Set<pid_t>()              // apps abandoned for the rest of this flush
    private var changed = false

    private var onScreenIDs = Set<CGWindowID>()
    private var screens: [(id: CGDirectDisplayID, frame: CGRect, visible: CGRect)] = []
    private var elementIDs: [AXUIElement: CGWindowID] = [:]
    private var nextOrder = 0
    private var workspaceTokens: [NSObjectProtocol] = []

    private static let retryDelays: [TimeInterval] = [0.25, 0.5, 1]
    private static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                           kAXApplicationActivatedNotification]
    private static let windowNotifications = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                                              kAXMovedNotification, kAXResizedNotification,
                                              kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
    private static let windowAttributes = [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, "AXFullScreen"]

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private static let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue().handle(notification as String, element)
    }

    // MARK: Lifecycle

    func start() {
        guard !isTracking else { return }
        isTracking = true
        EventLog.write("tracker start")
        let ws = NSWorkspace.shared
        let nc = ws.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping (NSRunningApplication?) -> Void) {
            workspaceTokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { n in
                body(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [unowned self] in if let r = $0 { addApp(r) } }
        on(NSWorkspace.didTerminateApplicationNotification) { [unowned self] in if let r = $0 { removeApp(r.processIdentifier) } }
        on(NSWorkspace.didHideApplicationNotification) { [unowned self] in setHidden($0, true) }
        on(NSWorkspace.didUnhideApplicationNotification) { [unowned self] in setHidden($0, false) }
        on(NSWorkspace.didActivateApplicationNotification) { [unowned self] in activated($0) }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [unowned self] _ in
            EventLog.write("ws space changed")
            rescanPids.formUnion(apps.keys)
            schedule()
            // Leaving fullscreen animates for ~0.7 s (verified with Warp on macOS 26): until it ends only a transition
            // window is in CGWindowList, so the restored window would stay invisible. Re-read it once it has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, isTracking else { return }
                refreshOnScreen = true
                schedule()
            }
        }
        workspaceTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [unowned self] _ in
            EventLog.write("screens changed")
            refreshOnScreen = true
            schedule()
        })

        for running in ws.runningApplications { addApp(running) }
        if let pid = ws.frontmostApplication?.processIdentifier { focusPids.insert(pid) }
        schedule()
    }

    func stop() {
        guard isTracking else { return }
        isTracking = false
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        workspaceTokens = []
        for app in apps.values { if let o = app.observer { AX.removeObserver(o) } }
        apps = [:]; windows = [:]; elementIDs = [:]; activeWindowID = nil
        newElements = []; rescanPids = []; dirtyWindows = []; focusPids = []; forcedOnScreen = []
        EventLog.write("tracker stop")
        onChange?()
    }

    // MARK: Apps and observers

    private func addApp(_ running: NSRunningApplication) {
        let pid = running.processIdentifier
        guard isTracking, running.activationPolicy == .regular, pid != getpid(), apps[pid] == nil, !running.isTerminated else { return }
        let app = TrackedApp(running)
        apps[pid] = app
        note("app+ pid=\(pid) \(app.bundleID ?? "-") \"\(app.name)\"")
        attach(app)
    }

    /// Registers app-level notifications; one-shot retries at 0.25 / 0.5 / 1 s, then waits for the
    /// app's next workspace event. On success the app's windows are (re)scanned.
    private func attach(_ app: TrackedApp) {
        guard isTracking, apps[app.pid] === app, !app.observing else { return }
        if app.observer == nil { app.observer = AX.makeObserver(app.pid, Self.axCallback) }
        var ok = false
        if let observer = app.observer {
            ok = (try? Self.appNotifications.allSatisfy { try AX.observe(observer, app.element, $0, refcon) }) ?? false
        }
        if ok, let observer = app.observer {
            // Finder (verified on macOS 26) posts AXUIElementDestroyed for its windows only to observers registered on
            // the application element; the per-window registration in addWindow is accepted but never fires there.
            // Best effort: an app that refuses it still gets the per-window registration and the focus-time pruning.
            _ = try? AX.observe(observer, app.element, kAXUIElementDestroyedNotification, refcon)
            app.observing = true
            app.retries = 0
            rescanPids.insert(app.pid)
            schedule()
        } else if app.retries < Self.retryDelays.count {
            let delay = Self.retryDelays[app.retries]
            app.retries += 1
            EventLog.write("observer retry \(app.retries) in \(delay)s pid=\(app.pid) \(app.name)")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak app] in
                if let app { self?.attach(app) }
            }
        } else {
            EventLog.write("observer gave up pid=\(app.pid) \(app.name) (until its next workspace event)")
        }
    }

    /// A workspace event for an app whose observer gave up restarts the retries.
    private func reattachIfNeeded(_ app: TrackedApp) {
        if !app.observing && app.retries >= Self.retryDelays.count { app.retries = 0; attach(app) }
    }

    private func removeApp(_ pid: pid_t) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        if let o = app.observer { AX.removeObserver(o) }
        for w in windows.values where w.pid == pid { removeWindow(w.id) }
        note("app- pid=\(pid) \(app.name)")
        schedule()
    }

    private func setHidden(_ running: NSRunningApplication?, _ hidden: Bool) {
        guard let running, let app = apps[running.processIdentifier] else { return }
        app.isHidden = hidden
        if !hidden { refreshOnScreen = true }
        note("\(hidden ? "hidden" : "unhidden") pid=\(app.pid) \(app.name)")
        reattachIfNeeded(app)
        schedule()
    }

    private func activated(_ running: NSRunningApplication?) {
        guard let running else { return }
        EventLog.write("ws activated pid=\(running.processIdentifier) \(running.localizedName ?? "")")
        // WinBar itself is activated by bar clicks when BarClickTap is unavailable, and by a bar click while one
        // of its menus is open. That is not a focus change: the last active window keeps its state.
        guard running.processIdentifier != getpid() else { return }
        if apps[running.processIdentifier] == nil { addApp(running) } // activation can arrive before didLaunch
        guard let app = apps[running.processIdentifier] else {
            if activeWindowID != nil { activeWindowID = nil; note("active window none") }
            schedule()
            return
        }
        app.newWindowItem = .none
        focusPids.insert(app.pid)
        reattachIfNeeded(app)
        schedule()
    }

    // MARK: AX events

    private func handle(_ notification: String, _ element: AXUIElement) {
        guard isTracking else { return }
        // The app-level registration reports every destroyed element of the app; only tracked windows matter.
        if notification == kAXUIElementDestroyedNotification && elementIDs[element] == nil { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        EventLog.write("ax \(notification) pid=\(pid)")
        switch notification {
        case kAXWindowCreatedNotification:
            newElements.append((pid, element))
        case kAXUIElementDestroyedNotification:
            if let id = elementIDs[element] { removeWindow(id) }
        case kAXWindowDeminiaturizedNotification:
            if let id = elementIDs[element] { dirtyWindows.insert(id); forcedOnScreen.insert(id); refreshOnScreen = true }
        case kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification:
            focusPids.insert(pid)
        default: // title, moved, resized, miniaturized
            if let id = elementIDs[element] { dirtyWindows.insert(id) }
        }
        schedule()
    }

    private func schedule() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.flush() }
    }

    // MARK: Flush

    private func flush() {
        flushScheduled = false
        guard isTracking else { return }
        timedOut = []
        screens = NSScreen.screens.map { (Self.displayID(of: $0), $0.frame, $0.visibleFrame) }
        // CGWindowList only on: launch, Space change, window creation, de-minimize, unhide.
        if !newElements.isEmpty || !rescanPids.isEmpty { refreshOnScreen = true }
        if refreshOnScreen {
            onScreenIDs = Self.onScreenWindowIDs()
            let fs = Self.fullScreen(spaces: Self.managedDisplaySpaces(),
                                     displays: screens.map { ($0.id, Self.displayUUID($0.id)) })
            if fs != fullScreenDisplays { fullScreenDisplays = fs; note("full-screen displays \(fs.sorted())") }
        }

        for (pid, el) in newElements {
            if let app = apps[pid] { withApp(app) { try addWindow(el, app, created: true) } }
        }
        // Launch order, then each app's own AX order (requirement 10).
        for app in rescanPids.compactMap({ apps[$0] }).sorted(by: { $0.launchDate < $1.launchDate }) {
            withApp(app) { try rescan(app) }
        }
        for id in dirtyWindows {
            if let w = windows[id], let app = apps[w.pid] { withApp(app) { try read(w, app) } }
        }
        // Activation can beat observer attachment (retries up to 1.75 s), leaving the focused window unread:
        // re-read the frontmost app's focus whenever its windows were (re)scanned.
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, rescanPids.contains(front) {
            focusPids.insert(front)
        }
        for pid in focusPids {
            if let app = apps[pid] { withApp(app) { try pruneDead(app); try updateFocus(app) } }
        }

        for w in windows.values {
            if refreshOnScreen { w.isOnScreen = onScreenIDs.contains(w.id) || forcedOnScreen.contains(w.id) }
            assignDisplay(w, isNew: false)
            let visible = Self.isVisible(onScreen: w.isOnScreen, minimized: w.isMinimized, appHidden: apps[w.pid]?.isHidden ?? false)
            if visible != w.isVisible {
                w.isVisible = visible
                note("\(visible ? "visible" : "invisible") id=\(w.id) pid=\(w.pid)")
            }
        }

        newElements = []; rescanPids = []; dirtyWindows = []; focusPids = []; forcedOnScreen = []
        refreshOnScreen = false
        if changed { changed = false; onChange?() }
    }

    /// Runs one app's reads; the first timeout abandons the rest of that app's reads in this flush.
    private func withApp(_ app: TrackedApp, _ body: () throws -> Void) {
        guard !timedOut.contains(app.pid) else { return }
        do { try body() } catch {
            timedOut.insert(app.pid)
            EventLog.write("ax \(error) pid=\(app.pid) \(app.name): skipping app until its next event")
        }
    }

    private func rescan(_ app: TrackedApp) throws {
        guard app.observing else { return }
        var seen = Set<CGWindowID>()
        for el in try AX.elements(app.element, kAXWindowsAttribute) {
            guard let id = AX.windowID(el) else { continue }
            seen.insert(id)
            try addWindow(el, app, created: false)
        }
        // Windows on other Spaces are absent from the AX list but still exist; drop only dead ones.
        for w in windows.values where w.pid == app.pid && !seen.contains(w.id) {
            if try AX.isDestroyed(w.element) { removeWindow(w.id) }
        }
    }

    private func addWindow(_ el: AXUIElement, _ app: TrackedApp, created: Bool) throws {
        guard let observer = app.observer, let id = AX.windowID(el), windows[id] == nil,
              let v = try AX.values(el, [kAXSubroleAttribute] + Self.windowAttributes),
              v[0] as? String == kAXStandardWindowSubrole else { return }
        for n in Self.windowNotifications { try AX.observe(observer, el, n, refcon) }
        let w = TrackedWindow(id: id, pid: app.pid, element: el, order: nextOrder)
        nextOrder += 1
        apply(Array(v.dropFirst()), to: w, isNew: true)
        if id == activeWindowID { w.lastFocused = CFAbsoluteTimeGetCurrent() }
        windows[id] = w
        elementIDs[el] = id
        if created { forcedOnScreen.insert(id) }
        note("window+ \(describe(w, app))")
    }

    private func read(_ w: TrackedWindow, _ app: TrackedApp) throws {
        if let v = try AX.values(w.element, Self.windowAttributes) {
            apply(v, to: w, isNew: false)
        } else if try AX.isDestroyed(w.element) {
            removeWindow(w.id)
        }
    }

    /// v = [title, position, size, minimized, fullScreen]
    private func apply(_ v: [CFTypeRef?], to w: TrackedWindow, isNew: Bool) {
        let title = v[0] as? String ?? ""
        if title != w.title {
            w.title = title
            if !isNew { note("title id=\(w.id) \"\(title)\"") }
        }
        if let p = AX.point(v[1]), let s = AX.size(v[2]) {
            w.frame = Self.cocoaRect(fromAX: CGRect(origin: p, size: s), primaryHeight: screens.first?.frame.height ?? 0)
            assignDisplay(w, isNew: isNew)
            if v[4] as? Bool != true, let screen = screens.first(where: { $0.id == w.displayID }),
               let f = Self.clampedAboveBar(w.frame, screen: screen.frame, visible: screen.visible, barHeight: TaskbarPanel.height) {
                // Top-left stays put, so the size alone lifts the bottom edge; the resulting kAXResized re-reads it.
                // Best effort: an app that refuses or times out just stays under the bar.
                note("clamp above bar id=\(w.id) height \(w.frame.height) -> \(f.height)")
                _ = try? AX.set(w.element, kAXSizeAttribute, f.size)
            }
        }
        let minimized = v[3] as? Bool ?? false
        if minimized != w.isMinimized {
            w.isMinimized = minimized
            if !isNew { note("\(minimized ? "minimized" : "restored") id=\(w.id)") }
            // A minimized window is never active; its app's next focus event names the new one.
            if minimized && w.id == activeWindowID { activeWindowID = nil; note("active window none (minimized)") }
        }
    }

    private func assignDisplay(_ w: TrackedWindow, isNew: Bool) {
        guard !screens.isEmpty else { return }
        let id = screens[Self.displayIndex(for: w.frame, in: screens.map(\.frame))].id
        guard id != w.displayID else { return }
        if !isNew { note("display id=\(w.id) \(w.displayID) -> \(id)") }
        w.displayID = id
    }

    /// Safety net for a missed AXUIElementDestroyed, run on the app's focus/activation events (no timer):
    /// one cheap read per known window of this app; windows on other Spaces still answer and are kept.
    private func pruneDead(_ app: TrackedApp) throws {
        for w in windows.values where w.pid == app.pid {
            if try AX.isDestroyed(w.element) { removeWindow(w.id) }
        }
    }

    private func updateFocus(_ app: TrackedApp) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid else { return }
        let id = try AX.element(app.element, kAXFocusedWindowAttribute).flatMap(AX.windowID)
        if let id, let w = windows[id] { w.lastFocused = CFAbsoluteTimeGetCurrent() }
        if id != activeWindowID {
            activeWindowID = id
            note("active window \(id.map(String.init) ?? "none") pid=\(app.pid)")
        }
    }

    private func removeWindow(_ id: CGWindowID) {
        guard let w = windows.removeValue(forKey: id) else { return }
        elementIDs[w.element] = nil
        dirtyWindows.remove(id)
        if activeWindowID == id { activeWindowID = nil }
        note("window- id=\(id) pid=\(w.pid)")
        onWindowRemoved?(id)
    }

    private func note(_ line: String) {
        changed = true
        EventLog.write(line)
    }

    private func describe(_ w: TrackedWindow, _ app: TrackedApp) -> String {
        "id=\(w.id) pid=\(w.pid) app=\"\(app.name)\" display=\(w.displayID) order=\(w.order) min=\(w.isMinimized) \"\(w.title)\""
    }

    // MARK: Action primitives

    /// Focuses exactly this window: unhide / un-minimize, then AXFrontmost + AXMain + AXRaise.
    /// Never NSRunningApplication.activate (ignored for a never-active agent since macOS 14).
    func focus(_ id: CGWindowID) {
        guard let w = windows[id], let app = apps[w.pid] else { return }
        act("focus \(id)") {
            if app.isHidden { app.running.unhide() }
            guard w.isMinimized else { return try bringToFront(w, app) }
            do {
                try AX.set(w.element, kAXMinimizedAttribute, false)
                try bringToFront(w, app)
            } catch AXFailure.timeout {
                // The app runs the de-miniaturize animation on its main thread, so whichever call comes next
                // outlasts the 0.25 s timeout (verified: AXRaise right after a successful un-minimize → -25204).
                // The request was still delivered; finish the sequence once the animation is over.
                EventLog.write("action focus \(id): app busy restoring the window, retrying front/main/raise in 0.5 s (non-fatal)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    // Usually the restore already fronted it (its focus event made it active): nothing to do.
                    guard let self, self.activeWindowID != id, let w = self.windows[id], let app = self.apps[w.pid] else { return }
                    self.act("focus \(id) after restore") { try self.bringToFront(w, app) }
                }
            }
        }
    }

    /// AXFrontmost + AXMain + AXRaise. Calculator (SwiftUI) answers AXRaise with -25205 (attribute unsupported)
    /// when the window is already frontmost and main: harmless, AX.perform only logs it.
    private func bringToFront(_ w: TrackedWindow, _ app: TrackedApp) throws {
        try AX.set(app.element, kAXFrontmostAttribute, true)
        try AX.set(w.element, kAXMainAttribute, true)
        try AX.perform(w.element, kAXRaiseAction)
    }

    /// Minimizes only. The app must not be re-fronted afterwards: with Stage Manager on, AXMinimized moves the
    /// window to the strip (AXMinimized stays false), and fronting the app brings its stage straight back.
    /// Bar clicks no longer activate WinBar (BarClickTap), so the app keeps the focus like its own minimize button.
    func minimize(_ id: CGWindowID) {
        guard let w = windows[id] else { return }
        act("minimize \(id)") { try AX.set(w.element, kAXMinimizedAttribute, true) }
    }

    func close(_ id: CGWindowID) {
        guard let w = windows[id] else { return }
        act("close \(id)") {
            if let button = try AX.element(w.element, kAXCloseButtonAttribute) { try AX.perform(button, kAXPressAction) }
        }
    }

    func unhide(_ pid: pid_t) { apps[pid]?.running.unhide() }

    /// Quits only this instance.
    func quit(_ pid: pid_t) { apps[pid]?.running.terminate() }

    /// The instance's ⌘N menu item, cached until the app's next activation. nil → "New Window" disabled.
    func newWindowItem(_ pid: pid_t) -> AXUIElement? {
        guard let app = apps[pid] else { return nil }
        if case .some(let cached) = app.newWindowItem { return cached }
        do {
            let item = try AX.newWindowMenuItem(app.element)
            app.newWindowItem = .some(item)
            return item
        } catch {
            EventLog.write("ax \(error) during ⌘N search pid=\(pid)")
            return nil // not cached: retried next time
        }
    }

    /// Activates the instance and presses its ⌘N item.
    func newWindow(_ pid: pid_t) {
        guard let app = apps[pid], let item = newWindowItem(pid) else { return }
        act("new window pid=\(pid)") {
            try AX.set(app.element, kAXFrontmostAttribute, true)
            try AX.perform(item, kAXPressAction)
        }
    }

    private func act(_ label: String, _ body: () throws -> Void) {
        EventLog.write("action \(label)")
        do { try body() } catch { EventLog.write("action \(label) failed: \(error)") }
    }

    // MARK: Pure logic (covered by --self-test)

    /// AX/CG global rect (top-left origin of the primary screen, y down) → Cocoa screen rect (y up).
    static func cocoaRect(fromAX r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Index of the screen with the largest overlap; ties → the earlier screen; no overlap → 0 (main).
    static func displayIndex(for frame: CGRect, in screens: [CGRect]) -> Int {
        var best = 0
        var bestArea: CGFloat = 0
        for (i, s) in screens.enumerated() {
            let r = frame.intersection(s)
            let area = r.isNull ? 0 : r.width * r.height
            if area > bestArea { best = i; bestArea = area }
        }
        return best
    }

    /// macOS gives no API to reserve screen space, so maximize, Fill, tiling and edge-snapped resizes all reach the
    /// visible frame's bottom, under the bar. A window whose bottom edge sits exactly there is shrunk to end at the
    /// bar's top edge; nil → leave it alone (dragged elsewhere, too short, or covering the whole screen).
    /// ponytail: re-clicking the green button re-maximizes instead of restoring (the app no longer sees it as zoomed).
    static func clampedAboveBar(_ frame: CGRect, screen: CGRect, visible: CGRect, barHeight: CGFloat) -> CGRect? {
        let barTop = screen.minY + barHeight
        guard frame != screen, abs(frame.minY - visible.minY) < 1, frame.minY < barTop, frame.maxY > barTop + barHeight else { return nil }
        return CGRect(x: frame.minX, y: barTop, width: frame.width, height: frame.maxY - barTop)
    }

    /// Requirement 4: displays whose current Space is a full-screen one (CGS space type 4). Without
    /// "Displays have separate Spaces" there is one "Main" entry, and a full-screen Space then covers every display.
    static func fullScreen(spaces: [[String: Any]], displays: [(id: CGDirectDisplayID, uuid: String)]) -> Set<CGDirectDisplayID> {
        var result = Set<CGDirectDisplayID>()
        for d in spaces where (d["Current Space"] as? [String: Any])?["type"] as? Int == 4 {
            let uuid = d["Display Identifier"] as? String
            result.formUnion(displays.filter { uuid == "Main" || $0.uuid == uuid }.map(\.id))
        }
        return result
    }

    /// Private SkyLight SPI (verified on macOS 26), resolved with dlsym; empty if missing, so the bar stays everywhere.
    private static func managedDisplaySpaces() -> [[String: Any]] {
        typealias Conn = @convention(c) () -> Int32
        typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
        let h = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let c = dlsym(h, "CGSMainConnectionID"), let f = dlsym(h, "CGSCopyManagedDisplaySpaces") else { return [] }
        let conn = unsafeBitCast(c, to: Conn.self)()
        return unsafeBitCast(f, to: Copy.self)(conn)?.takeRetainedValue() as? [[String: Any]] ?? []
    }

    private static func displayUUID(_ id: CGDirectDisplayID) -> String {
        CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
    }

    /// Requirement 8.
    static func isVisible(onScreen: Bool, minimized: Bool, appHidden: Bool) -> Bool {
        // Hiding doesn't refresh the on-screen list, so a just-hidden window can still read as on screen.
        minimized || (onScreen && !appHidden)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }
}
