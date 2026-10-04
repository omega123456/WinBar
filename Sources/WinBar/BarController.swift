import AppKit

/// Identity used to diff buttons: window ID, app (bundle ID: app item or launcher), or the "…" button.
enum ItemKey: Hashable {
    case window(CGWindowID)
    case app(String)
    case overflow
}

enum BarGroup: Equatable { case pinned, other }

/// One derived bar item (not persisted).
struct BarItem: Equatable {
    enum Kind: Equatable {
        case window(CGWindowID, pid_t)
        case appItem(String)   // running pinned app with no window on the main display
        case launcher(String)  // pinned app that is not running
    }
    var kind: Kind
    var group: BarGroup

    var key: ItemKey {
        switch kind {
        case .window(let id, _): return .window(id)
        case .appItem(let b), .launcher(let b): return .app(b)
        }
    }
}

/// Composition input: one visible window (requirement 8), in session order.
struct BarWindow {
    var id: CGWindowID
    var pid: pid_t
    var bundleID: String?
    var displayID: CGDirectDisplayID
}

/// Requirement 21 result: widths of the items that stay on the bar; the rest go into "…".
struct Fit: Equatable {
    var pinned: [CGFloat]
    var other: [CGFloat]
    var iconOnly: Bool
    var overflow: Bool
}

/// Model → bars, and user intent → WindowTracker / NSWorkspace.
final class BarController {
    enum Access { case trusted, untrusted, incompatible }

    static let slot: CGFloat = 44, maxWidth: CGFloat = 160, minShrink: CGFloat = 96
    private static let pinsKey = "pinnedBundleIDs"
    /// Modal menu tracking; returns when the menu closes. Tests replace it to pick an item without a real menu.
    static var trackMenu: (NSMenu, NSPoint) -> Void = { _ = $0.popUp(positioning: nil, at: $1, in: nil) }

    var access = Access.untrusted { didSet { if access != oldValue { render() } } }
    private(set) var pins: [String]

    private let tracker: WindowTracker
    private let signals: Signals
    private let preview: PreviewController
    private var panels: [CGDirectDisplayID: TaskbarPanel] = [:]
    private var hiddenItems: [CGDirectDisplayID: [BarItem]] = [:]  // overflowed into "…"
    private var theme = Theme.current()
    private var dots: NSImage
    private var lastActivated: [pid_t: CFAbsoluteTime] = [:]
    private var installed: [String: (url: URL, name: String, icon: NSImage)] = [:]
    private var tokens: [NSObjectProtocol] = []

    init(tracker: WindowTracker, signals: Signals, preview: PreviewController) {
        self.tracker = tracker
        self.signals = signals
        self.preview = preview
        dots = TaskbarButton.dots(color: theme.text)
        var seen = Set<String>()
        pins = (Env.defaults.stringArray(forKey: Self.pinsKey) ?? []).filter { seen.insert($0).inserted }
        pins.removeAll { appInfo($0) == nil } // no longer installed
        savePins()
        if let pid = Env.workspace.frontmostApplication?.processIdentifier { lastActivated[pid] = CFAbsoluteTimeGetCurrent() }
        tokens.append(Env.workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.lastActivated[app.processIdentifier] = CFAbsoluteTimeGetCurrent()
            }
        })
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.render() })
        render()
    }

    func themeChanged() {
        let t = Theme.current()
        guard t != theme else { return }
        theme = t
        dots = TaskbarButton.dots(color: t.text)
        EventLog.write("theme contrast=\(t.contrast) solid=\(t.solid) reduceMotion=\(t.reduceMotion)")
        render()
    }

    // MARK: Rendering

    func render() {
        if panels.values.contains(where: \.isDragging) { return } // the drop re-renders
        syncPanels()
        let mainID = Env.screens().first.map(WindowTracker.displayID)
        let trusted = access == .trusted
        let windows = tracker.visibleWindows.map {
            BarWindow(id: $0.id, pid: $0.pid, bundleID: tracker.apps[$0.pid]?.bundleID, displayID: $0.displayID)
        }
        let running = Set(tracker.apps.values.compactMap(\.bundleID))
        let rows = panels.map { id, panel in
            panel.apply(theme)
            let items = Self.compose(pins: pins, windows: windows, running: running, display: id,
                                     isMain: id == mainID, trusted: trusted)
            let pinned = items.filter { $0.group == .pinned }, other = items.filter { $0.group == .other }
            let natural: (BarItem) -> CGFloat? = { [unowned self] item in
                if case .window(let wid, _) = item.kind { return Self.naturalWidth(label(wid)) }
                return nil
            }
            let fit = trusted
                ? Self.fit(pinned: pinned.map(natural), other: other.map(natural), available: panel.frame.width - 2 * TaskbarPanel.edge - TaskbarPanel.rightReserve)
                : Fit(pinned: pinned.map { _ in Self.slot }, other: [], iconOnly: true, overflow: false)
            hiddenItems[id] = Array(pinned.dropFirst(fit.pinned.count)) + Array(other.dropFirst(fit.other.count))
            return (id: id, panel: panel, pinned: Array(pinned.prefix(fit.pinned.count)), other: Array(other.prefix(fit.other.count)), fit: fit)
        }
        // Attention target: the app's most recently used window that has a button on some bar (requirement 29).
        var targets: [pid_t: TrackedWindow] = [:]
        for case .window(let wid, let pid) in rows.flatMap({ ($0.pinned + $0.other).map(\.kind) }) where signals.attention[pid] != nil {
            if let w = tracker.windows[wid], w.lastFocused >= targets[pid]?.lastFocused ?? -1 { targets[pid] = w }
        }
        for (id, panel, pinned, other, fit) in rows {
            // Badge and progress: the app's first item on this bar (window button or app item, never a launcher).
            var seen = Set<String>()
            func make(_ item: BarItem, _ width: CGFloat) -> TaskbarButton.Content {
                var c = content(item, width, fit.iconOnly)
                var say: [String] = []
                let bundleID: String? = switch item.kind {
                case .window(_, let pid): tracker.apps[pid]?.bundleID
                case .appItem(let b): b
                case .launcher: nil
                }
                if let bundleID, seen.insert(bundleID).inserted {
                    c.badge = signals.badges[bundleID]
                    c.progress = signals.progress[bundleID]
                    if let b = c.badge { say.append(b.voiceOver) }
                    if let p = c.progress {
                        say.append(p.paused ? "download paused" : p.fraction.map { "downloading, \(Int($0 * 100)) percent" } ?? "downloading")
                    }
                }
                if case .window(let wid, let pid) = item.kind, targets[pid]?.id == wid, let a = signals.attention[pid] {
                    c.attention = a
                    say.append("needs attention")
                }
                c.voiceOver += say.map { ", " + $0 }.joined()
                return c
            }
            let overflow = fit.overflow ? TaskbarButton.Content(
                item: nil, icon: dots, label: "", width: Self.slot, iconOnly: true,
                voiceOver: "\(hiddenItems[id]?.count ?? 0) more items") : nil
            let cta: (text: String, showsButton: Bool)? = switch access {
            case .trusted: nil
            case .untrusted: ("WinBar needs Accessibility access to show your windows.", true)
            case .incompatible: ("WinBar is not compatible with this macOS version", false)
            }
            panel.update(pinned: zip(pinned, fit.pinned).map(make), other: zip(other, fit.other).map(make),
                         overflow: overflow, cta: cta)
        }
    }

    /// One panel per display ID; re-framed on parameter changes, created/destroyed only on connect/disconnect.
    private func syncPanels() {
        var live = Set<CGDirectDisplayID>()
        for screen in Env.screens() {
            let id = WindowTracker.displayID(of: screen)
            live.insert(id)
            if let panel = panels[id] {
                panel.reframe(to: screen)
            } else {
                panels[id] = TaskbarPanel(screen: screen, controller: self)
                EventLog.write("bar+ display=\(id)")
            }
            if let panel = panels[id], tracker.fullScreenDisplays.contains(id) == panel.isVisible {
                if panel.isVisible { panel.orderOut(nil); preview.hideNow() } else { panel.orderFrontRegardless() }
            }
        }
        for (id, panel) in panels where !live.contains(id) {
            panel.orderOut(nil)
            panel.close()
            panels[id] = nil
            hiddenItems[id] = nil
            EventLog.write("bar- display=\(id)")
        }
    }

    private func label(_ id: CGWindowID) -> String {
        guard let w = tracker.windows[id] else { return "" }
        return w.title.isEmpty ? (tracker.apps[w.pid]?.name ?? "") : w.title
    }

    private func content(_ item: BarItem, _ width: CGFloat, _ iconOnly: Bool) -> TaskbarButton.Content {
        switch item.kind {
        case .window(let id, let pid):
            let app = tracker.apps[pid], w = tracker.windows[id]
            let title = label(id), name = app?.name ?? ""
            let active = tracker.activeWindowID == id
            let state = active ? ", active" : w?.isMinimized == true ? ", minimized" : app?.isHidden == true ? ", hidden" : ""
            return .init(item: item, icon: app?.icon ?? NSImage(), label: title, width: width, iconOnly: iconOnly,
                         active: active, voiceOver: "\(title), \(name)\(state)")
        case .appItem(let b):
            let inst = instances(b).first
            let name = inst?.name ?? appInfo(b)?.name ?? b
            return .init(item: item, icon: inst?.icon ?? appInfo(b)?.icon ?? NSImage(), label: name, width: Self.slot,
                         iconOnly: true, voiceOver: "\(name), running, no windows on this display")
        case .launcher(let b):
            let info = appInfo(b)
            return .init(item: item, icon: info?.icon ?? NSImage(), label: info?.name ?? b, width: Self.slot,
                         iconOnly: true, voiceOver: "\(info?.name ?? b), pinned")
        }
    }

    // MARK: Apps

    /// Installed app info, cached per bundle ID. nil → not installed.
    private func appInfo(_ bundleID: String) -> (url: URL, name: String, icon: NSImage)? {
        if let i = installed[bundleID] { return i }
        guard let url = Env.workspace.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let info = (url, name, Env.workspace.icon(forFile: url.path))
        installed[bundleID] = info
        return info
    }

    /// Running instances of a bundle, most recently activated first.
    private func instances(_ bundleID: String) -> [TrackedApp] {
        tracker.apps.values.filter { $0.bundleID == bundleID }
            .sorted { (lastActivated[$0.pid] ?? 0, $0.launchDate) > (lastActivated[$1.pid] ?? 0, $1.launchDate) }
    }

    private func open(_ bundleID: String) {
        guard let url = appInfo(bundleID)?.url ?? Env.workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            EventLog.write("pinned app \(bundleID) no longer installed: unpinned")
            setPinned(bundleID, false)
            return
        }
        EventLog.write("action open \(bundleID)")
        // Launches, or sends a reopen event to a running app (which normally opens a window).
        Env.workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func setPinned(_ bundleID: String, _ on: Bool) {
        pins.removeAll { $0 == bundleID }
        if on { pins.append(bundleID) } // a newly pinned app goes to the end
        savePins()
        render()
    }

    private func savePins() { Env.defaults.set(pins, forKey: Self.pinsKey) }

    // MARK: Actions

    /// Click, overflow-menu choice and VoiceOver press all end up here.
    private func activate(_ item: BarItem) {
        switch item.kind {
        case .window(let id, let pid):
            guard let w = tracker.windows[id] else { return }
            let hidden = tracker.apps[pid]?.isHidden ?? false
            if id == tracker.activeWindowID && !w.isMinimized && !hidden { tracker.minimize(id) } else { tracker.focus(id) }
        case .appItem(let b):
            let pids = Set(instances(b).map(\.pid))
            if let w = tracker.visibleWindows.filter({ pids.contains($0.pid) }).max(by: { $0.lastFocused < $1.lastFocused }) {
                tracker.focus(w.id)
            } else {
                open(b)
            }
        case .launcher(let b):
            open(b)
        }
    }

    /// Window buttons drive the hover preview; not while dragging or while a menu is open.
    func hover(_ b: TaskbarButton, _ entered: Bool) {
        guard entered else { return preview.hoverExit() }
        guard case .window(let id, _) = b.content.item?.kind, !BarClickTap.isPaused,
              !panels.values.contains(where: \.isDragging), let win = b.window else { return }
        preview.hoverEnter(id, plate: win.convertToScreen(b.convert(b.plateRect, to: nil)), screen: win.screen)
    }

    /// Any mouse button down on a bar (delivered by BarClickTap).
    func barMouseDown() { preview.hideNow() }

    func clicked(_ b: TaskbarButton) {
        if let item = b.content.item { activate(item) } else { showOverflowMenu(b) }
    }

    func rightClicked(_ b: TaskbarButton, _ event: NSEvent) {
        guard let item = b.content.item else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch item.kind {
        case .window(let id, let pid):
            guard let app = tracker.apps[pid] else { return }
            menu.add("New Window", enabled: tracker.newWindowItem(pid) != nil) { [tracker] in tracker.newWindow(pid) }
            menu.addItem(.separator())
            if let bid = app.bundleID {
                let pinned = pins.contains(bid)
                menu.add(pinned ? "Unpin from Taskbar" : "Pin to Taskbar") { [weak self] in self?.setPinned(bid, !pinned) }
            } else {
                menu.add("Pin to Taskbar", enabled: false) {}
            }
            menu.addItem(.separator())
            menu.add("Close Window") { [tracker] in tracker.close(id) }
            menu.add("Quit \(app.name)") { [tracker] in tracker.quit(pid) } // this instance only
        case .appItem(let bid):
            let all = instances(bid)
            guard let recent = all.first else { return }
            menu.add("New Window", enabled: tracker.newWindowItem(recent.pid) != nil) { [tracker] in tracker.newWindow(recent.pid) }
            menu.addItem(.separator())
            menu.add("Unpin from Taskbar") { [weak self] in self?.setPinned(bid, false) }
            menu.addItem(.separator())
            menu.add("Quit \(recent.name)") { [tracker] in all.forEach { tracker.quit($0.pid) } } // every instance
        case .launcher(let bid):
            menu.add("Open \(appInfo(bid)?.name ?? bid)") { [weak self] in self?.open(bid) }
            menu.addItem(.separator())
            menu.add("Unpin from Taskbar") { [weak self] in self?.setPinned(bid, false) }
        }
        popUp(menu, atPointerOf: event, in: b)
    }

    func showBarMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        #if DEBUG
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.add("WinBar Dev \(version) (debug)", enabled: false) {}
        menu.addItem(.separator())
        #endif
        let login = menu.add("Launch at Login") { LaunchAtLogin.toggle() }
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        let updates = menu.add("Automatic Updates") { Updater.toggle() }
        updates.state = Updater.isEnabled ? .on : .off
        menu.add("Check for Updates…") { Updater.check(manual: true) }
        if !PreviewController.hasPermission {
            menu.add("Enable Window Previews…") {
                Env.workspace.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
        menu.addItem(.separator())
        menu.add("Quit WinBar") { NSApp.terminate(nil) }
        popUp(menu, atPointerOf: event, in: view)
    }

    private func showOverflowMenu(_ b: TaskbarButton) {
        guard let id = (b.window as? TaskbarPanel).flatMap({ p in panels.first { $0.value === p }?.key }) else { return }
        let menu = NSMenu()
        for item in hiddenItems[id] ?? [] {
            let c = content(item, Self.slot, true)
            let entry = menu.add(c.label) { [weak self] in self?.activate(item) }
            let icon = c.icon.copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
        }
        // Left-aligned with the "…" button, its bottom 6 pt above the button's top (mockup).
        guard let panel = b.window else { return }
        let r = panel.convertToScreen(b.convert(b.plateRect, to: nil))
        popUp(menu, left: r.minX, bottom: r.maxY + 6, on: panel)
    }

    /// Context menus: bottom-left corner at the pointer (mockup; nothing fits below a bottom bar).
    private func popUp(_ menu: NSMenu, atPointerOf event: NSEvent, in view: NSView) {
        guard let panel = view.window else { return }
        let p = panel.convertPoint(toScreen: event.locationInWindow)
        popUp(menu, left: p.x, bottom: p.y, on: panel)
    }

    private func popUp(_ menu: NSMenu, left: CGFloat, bottom: CGFloat, on panel: NSWindow) {
        let visibleMinY = (panel.screen ?? Env.screens().first)?.visibleFrame.minY ?? 0
        // Clicks on the menu come from BarClickTap (a native one would activate WinBar and end tracking first),
        // so the item under the pointer is fired here once tracking ends.
        let highlight = MenuHighlight()
        menu.delegate = highlight
        var chosen: ActionItem?
        BarClickTap.onMenuClick = {
            guard let item = highlight.item as? ActionItem, item.isEnabled else { return } // separator / disabled: stay open
            chosen = item
            menu.cancelTracking()
        }
        BarClickTap.isPaused = true // popUp returns when tracking ends
        defer { BarClickTap.isPaused = false; BarClickTap.onMenuClick = nil }
        Self.trackMenu(menu, Self.menuLocation(left: left, bottom: bottom, menuHeight: menu.size.height, visibleMinY: visibleMinY))
        chosen?.handler()
    }

    /// Drop commit (requirement 20): pinned group → pin order from each app's first appearance
    /// (persisted); window order → the dropped windows take over their own session-order slots.
    func reorder(_ group: BarGroup, _ keys: [ItemKey]) {
        let wins = keys.compactMap { key -> TrackedWindow? in
            if case .window(let id) = key { return tracker.windows[id] } else { return nil }
        }
        for (w, order) in zip(wins, wins.map(\.order).sorted()) { w.order = order }
        if group == .pinned {
            let apps = keys.compactMap { key -> String? in
                switch key {
                case .app(let b): return b
                case .window(let id): return tracker.windows[id].flatMap { tracker.apps[$0.pid]?.bundleID }
                case .overflow: return nil
                }
            }
            pins = Self.pinOrder(dropped: apps, pins: pins)
            savePins()
        }
        EventLog.write("reordered \(group) \(keys.count) items")
        render()
    }

    // MARK: Pure logic (covered by --self-test)

    /// Requirements 12–13 and 31. Main display: pinned group in pin order (each slot: its windows on
    /// this display from all instances in session order, else an app item if running, else a launcher),
    /// then the other windows. Other displays: their windows only. Untrusted: launchers only.
    static func compose(pins: [String], windows: [BarWindow], running: Set<String>,
                        display: CGDirectDisplayID, isMain: Bool, trusted: Bool) -> [BarItem] {
        let here = windows.filter { $0.displayID == display }
        var items: [BarItem] = []
        if isMain {
            for b in pins {
                let ws = trusted ? here.filter { $0.bundleID == b } : []
                if !ws.isEmpty {
                    items += ws.map { BarItem(kind: .window($0.id, $0.pid), group: .pinned) }
                } else {
                    items.append(BarItem(kind: trusted && running.contains(b) ? .appItem(b) : .launcher(b), group: .pinned))
                }
            }
        }
        guard trusted else { return items }
        let pinned = isMain ? Set(pins) : []
        return items + here.filter { $0.bundleID.map { !pinned.contains($0) } ?? true }
            .map { BarItem(kind: .window($0.id, $0.pid), group: .other) }
    }

    /// Requirement 21. `nil` entries are fixed 44 pt items (launchers, app items); numbers are the
    /// natural widths of labelled window buttons. Stages: natural → even shrink (share ≥ 96) →
    /// icon-only → trailing items into "…" (other windows first, then pinned).
    static func fit(pinned: [CGFloat?], other: [CGFloat?], available: CGFloat) -> Fit {
        func cost(_ p: [CGFloat], _ o: [CGFloat], _ more: Bool) -> CGFloat {
            let on = o.count + (more ? 1 : 0)
            return p.reduce(0, +) + o.reduce(0, +) + (more ? slot : 0)
                + CGFloat(max(0, p.count - 1) + max(0, on - 1)) * TaskbarPanel.gap
                + (!p.isEmpty && on > 0 ? TaskbarPanel.groupGap : 0)
        }
        let natP = pinned.map { $0 ?? slot }, natO = other.map { $0 ?? slot }
        if cost(natP, natO, false) <= available { return Fit(pinned: natP, other: natO, iconOnly: false, overflow: false) }

        let windowCount = (pinned + other).compactMap { $0 }.count
        if windowCount > 0 {
            let fixed = cost(pinned.map { $0 == nil ? slot : 0 }, other.map { $0 == nil ? slot : 0 }, false)
            let share = floor((available - fixed) / CGFloat(windowCount))
            if share >= minShrink {
                let shrink = { (w: CGFloat?) in w.map { min($0, share) } ?? slot }
                return Fit(pinned: pinned.map(shrink), other: other.map(shrink), iconOnly: false, overflow: false)
            }
        }
        var p = Array(repeating: slot, count: pinned.count), o = Array(repeating: slot, count: other.count)
        if cost(p, o, false) <= available { return Fit(pinned: p, other: o, iconOnly: true, overflow: false) }
        while !o.isEmpty && cost(p, o, true) > available { o.removeLast() }
        while !p.isEmpty && cost(p, o, true) > available { p.removeLast() }
        return Fit(pinned: p, other: o, iconOnly: true, overflow: true)
    }

    /// 8 · icon 24 · 8 · label · 10, clamped to 44…160 pt.
    static func naturalWidth(_ label: String) -> CGFloat {
        let text = (label as NSString).size(withAttributes: [.font: Fonts.label]).width
        return min(maxWidth, max(slot, ceil(8 + 24 + 8 + text + 10)))
    }

    /// Screen location to pass to `NSMenu.popUp(positioning: nil, at:, in: nil)` so that the menu window's
    /// bottom-left corner lands at (left, bottom). Measured on macOS 26: the menu window sits 5 pt above the
    /// requested point, and AppKit keeps it at least 6 pt above the screen's visibleFrame bottom (a bottom
    /// Dock reserves that area); a menu requested lower is clipped with scroll arrows instead of moved, so
    /// the bottom is raised to that limit (+2 pt margin) first.
    static func menuLocation(left: CGFloat, bottom: CGFloat, menuHeight: CGFloat, visibleMinY: CGFloat) -> NSPoint {
        NSPoint(x: left, y: max(bottom, visibleMinY + 8) - 5 + menuHeight)
    }

    /// Pin order after a drop in the pinned group: apps by first appearance, then pins not on the bar.
    static func pinOrder(dropped: [String], pins: [String]) -> [String] {
        var seen = Set<String>()
        let order = dropped.filter { seen.insert($0).inserted }
        return order + pins.filter { !seen.contains($0) }
    }
}

/// Closure-backed menu items.
private final class MenuHighlight: NSObject, NSMenuDelegate {
    var item: NSMenuItem?
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) { self.item = item }
}

private final class ActionItem: NSMenuItem {
    var handler: () -> Void = {}
    @objc func fire() { handler() }
}

private extension NSMenu {
    @discardableResult
    func add(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ActionItem(title: title, action: #selector(ActionItem.fire), keyEquivalent: "")
        item.target = item
        item.handler = handler
        item.isEnabled = enabled
        addItem(item)
        return item
    }
}
