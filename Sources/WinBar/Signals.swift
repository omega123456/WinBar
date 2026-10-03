import AppKit
import ApplicationServices

/// Dock badge text → what the button shows (requirement 27; rules applied in order).
enum Badge: Equatable {
    case count(String), alert, text(String), dot

    init?(dockLabel raw: String?) {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "0" { return nil }
        if t.allSatisfy({ ("0"..."9").contains($0) }) {
            let n = t.drop { $0 == "0" }
            self = .count(n.count > 2 ? "99+" : n.isEmpty ? "0" : String(n))
        } else if t == "!" {
            self = .alert
        } else if t.count <= 3 && t.contains(where: { $0.isLetter || $0.isNumber }) {
            self = .text(t)
        } else {
            self = .dot
        }
    }

    /// Text in the circle / pill; nil = the solid dot.
    var glyph: String? {
        switch self {
        case .count(let s), .text(let s): s
        case .alert: "!"
        case .dot: nil
        }
    }

    var voiceOver: String {
        switch self {
        case .count(let s): "\(s) notifications"
        case .alert: "alert"
        case .text(let s): s
        case .dot: "new activity"
        }
    }
}

/// Combined download progress of one app. fraction nil = indeterminate.
struct ProgressState: Equatable {
    var fraction: Double?
    var paused: Bool
}

/// Requirement 29: the button shows pulses (phase aligned to `since`), the held plate, or nothing.
enum AttentionState: Equatable { case none, pulsing(since: CFAbsoluteTime), holding }

/// Download owner (requirement 28): fixed when first seen; a fallback is replaced only by a quarantine agent.
struct Attribution: Equatable {
    var app: String?   // bundle ID
    var fallback: Bool // true = the frontmost app when first seen
}

/// Per-app badge, progress and attention. Main thread only; emits `onChange` (the bar re-renders, diffed).
final class Signals: NSObject {
    var onChange: (() -> Void)?
    private(set) var badges: [String: Badge] = [:]            // bundle ID →
    private(set) var progress: [String: ProgressState] = [:]  // bundle ID →
    private(set) var attention: [pid_t: AttentionState] = [:]

    private var running = false
    private var tokens: [NSObjectProtocol] = []

    // Badge reader (Design decision 6)
    private var dock: (pid: pid_t, element: AXUIElement)?
    private var dockItems: [AXUIElement: String?] = [:] // item → bundle ID (nil: not an app); URL read once
    private var poll: Timer?
    private var pauses = Set<String>()
    private var itemsRefreshScheduled = false

    // Attention (Design decision 7)
    private var lsSubscribed = false
    private var asns: [(asn: CFTypeRef, pid: pid_t)] = []
    private var requests: [pid_t: (start: CFAbsoluteTime, ended: CFAbsoluteTime?)] = [:]
    private var attentionTimer: Timer?

    // Downloads (Design decision 8)
    private final class Download {
        let progress: Progress
        var attribution: Attribution
        var observations: [NSKeyValueObservation] = []
        init(_ progress: Progress, _ attribution: Attribution) { self.progress = progress; self.attribution = attribution }
    }
    private var subscriber: Any?
    private var downloads: [ObjectIdentifier: Download] = [:]
    private var progressFlushScheduled = false
    private var lastProgressFlush: CFAbsoluteTime = 0

    // MARK: Lifecycle (runs while Accessibility is trusted)

    func start() {
        guard !running else { return }
        running = true
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping (Notification) -> Void) {
            tokens.append(ws.addObserver(forName: name, object: nil, queue: .main, using: body))
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [unowned self] _ in scheduleItemsRefresh() }
        on(NSWorkspace.didTerminateApplicationNotification) { [unowned self] n in
            if let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier {
                requests[pid] = nil
                updateAttention()
            }
            scheduleItemsRefresh()
        }
        on(NSWorkspace.didActivateApplicationNotification) { [unowned self] n in
            // Activation clears attention at once, without waiting for LaunchServices.
            guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier,
                  requests.removeValue(forKey: pid) != nil else { return }
            EventLog.write("attention cleared pid=\(pid) (activated)")
            updateAttention()
        }
        on(NSWorkspace.screensDidSleepNotification) { [unowned self] _ in setPaused("sleep", true) }
        on(NSWorkspace.screensDidWakeNotification) { [unowned self] _ in setPaused("sleep", false) }
        on(NSWorkspace.sessionDidResignActiveNotification) { [unowned self] _ in setPaused("session", true) }
        on(NSWorkspace.sessionDidBecomeActiveNotification) { [unowned self] _ in setPaused("session", false) }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked), name: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(screenUnlocked), name: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, suspensionBehavior: .deliverImmediately)

        refreshItems()
        updatePoll()
        if !lsSubscribed {
            lsSubscribed = true // once per process; events are ignored while stopped
            _ = LaunchServicesSPI.subscribeAttention { [weak self] asn, wants in self?.attentionEvent(asn, wants) }
        }
        // The subscription is checked silently on the service side, so the folder is touched once to show the
        // Downloads prompt (requirement 33). That call blocks until the prompt is answered: off the main thread,
        // then subscribe on main. Denied → progress is simply absent.
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            let readable = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
            DispatchQueue.main.async { [weak self] in
                EventLog.write("downloads folder \(readable ? "readable" : "not readable")")
                guard let self, running, subscriber == nil else { return }
                subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] p in
                    let id = ObjectIdentifier(p)
                    Self.onMain { self?.downloadAppeared(p) }
                    return { Self.onMain { self?.downloadGone(id) } }
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        DistributedNotificationCenter.default().removeObserver(self)
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        downloads = [:]
        updatePoll()
        attentionTimer?.invalidate()
        dock = nil; dockItems = [:]; pauses = []; requests = [:]; asns = []
        badges = [:]; progress = [:]; attention = [:]
        onChange?()
    }

    private static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    // MARK: Badges

    @objc private func screenLocked() { setPaused("lock", true) }
    @objc private func screenUnlocked() { setPaused("lock", false) }

    private func setPaused(_ reason: String, _ on: Bool) {
        let was = !pauses.isEmpty
        if on { pauses.insert(reason) } else { pauses.remove(reason) }
        guard was != !pauses.isEmpty else { return }
        EventLog.write("badge poll \(on ? "paused" : "resumed") (\(reason))")
        updatePoll()
    }

    /// The only periodic timer while idle: every 2 s with tolerance, off while paused or stopped.
    private func updatePoll() {
        if running && pauses.isEmpty {
            guard poll == nil else { return }
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            poll = t
            tick()
        } else {
            poll?.invalidate()
            poll = nil
        }
    }

    private func scheduleItemsRefresh() {
        guard running, !itemsRefreshScheduled else { return }
        itemsRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.itemsRefreshScheduled = false
            self?.refreshItems()
        }
    }

    /// Dock app → AXList → items. Attaches to the current Dock process (re-attaches after a relaunch).
    private func refreshItems() {
        guard running else { return }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else {
            dock = nil; dockItems = [:]
            return
        }
        if dock?.pid != pid {
            dock = (pid, AXUIElementCreateApplication(pid))
            dockItems = [:]
            EventLog.write("badge dock attached pid=\(pid)")
        }
        guard let dock else { return }
        do {
            var items: [AXUIElement: String?] = [:]
            for list in try AX.elements(dock.element, kAXChildrenAttribute) {
                for item in try AX.elements(list, kAXChildrenAttribute) {
                    if let known = dockItems[item] { items[item] = known; continue }
                    let v = try AX.values(item, [kAXSubroleAttribute, kAXURLAttribute])
                    let url = v?[0] as? String == "AXApplicationDockItem" ? v?[1] as? URL : nil
                    items[item] = url.flatMap { Bundle(url: $0)?.bundleIdentifier }
                }
            }
            dockItems = items
            EventLog.write("badge dock items=\(items.values.compactMap { $0 }.count)")
        } catch {
            EventLog.write("badge dock items \(error): retried on the next launch/quit")
        }
    }

    /// Reads only AXStatusLabel; the first timeout abandons the rest of the tick.
    private func tick() {
        guard running else { return }
        if dock.map({ NSRunningApplication(processIdentifier: $0.pid)?.isTerminated ?? true }) ?? true { refreshItems() }
        var next: [String: Badge] = [:]
        do {
            for case let (item, bundleID?) in dockItems {
                if let b = Badge(dockLabel: try AX.string(item, "AXStatusLabel")) { next[bundleID] = b }
            }
        } catch {
            EventLog.write("badge tick abandoned: dock \(error)")
            return
        }
        EventLog.write("badge tick items=\(dockItems.count) badges=\(next.count)")
        guard next != badges else { return }
        for (b, v) in next where badges[b] != v { EventLog.write("badge \(b) \(v.glyph ?? "•dot")") }
        for b in badges.keys where next[b] == nil { EventLog.write("badge \(b) cleared") }
        badges = next
        onChange?()
    }

    // MARK: Attention

    private func attentionEvent(_ asn: CFTypeRef, _ wants: Bool) {
        guard running else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if wants {
            guard let pid = LaunchServicesSPI.pid(of: asn) else {
                EventLog.write("attention request ignored: pid lookup failed")
                return
            }
            asns.removeAll { $0.pid == pid || CFEqual($0.asn, asn) }
            asns.append((asn, pid))
            if requests[pid]?.ended == nil && requests[pid] != nil { return } // already requested
            requests[pid] = (now, nil)
            EventLog.write("attention on pid=\(pid)")
        } else {
            guard let i = asns.firstIndex(where: { CFEqual($0.asn, asn) }) else { return } // the pid lookup fails after quit
            let pid = asns.remove(at: i).pid
            guard requests[pid] != nil, requests[pid]?.ended == nil else { return }
            requests[pid]?.ended = now
            EventLog.write("attention off pid=\(pid)")
        }
        updateAttention()
    }

    /// Re-evaluates every request now and wakes up (one-shot) at the next pulse-count boundary.
    private func updateAttention() {
        attentionTimer?.invalidate()
        attentionTimer = nil
        let now = CFAbsoluteTimeGetCurrent(), rm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var next: [pid_t: AttentionState] = [:]
        var wake: CFAbsoluteTime?
        for (pid, r) in requests {
            let (state, change) = Self.attention(start: r.start, ended: r.ended, now: now, reduceMotion: rm)
            if state == .none { requests[pid] = nil } else { next[pid] = state }
            if let change { wake = min(wake ?? change, change) }
        }
        if let wake {
            let t = Timer(timeInterval: wake - now + 0.02, repeats: false) { [weak self] _ in self?.updateAttention() }
            RunLoop.main.add(t, forMode: .common)
            attentionTimer = t
        }
        guard next != attention else { return }
        for (pid, s) in next where attention[pid] != s { EventLog.write("attention pid=\(pid) \(s)") }
        for pid in attention.keys where next[pid] == nil { EventLog.write("attention pid=\(pid) none") }
        attention = next
        onChange?()
    }

    // MARK: Downloads

    private func downloadAppeared(_ p: Progress) {
        guard running else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let d = Download(p, Self.attribute(nil, agentApp: agentApp(p), frontmost: front))
        let changed: () -> Void = { [weak self] in Self.onMain { self?.progressChanged() } } // KVO: any thread
        d.observations = [p.observe(\.fractionCompleted) { _, _ in changed() },
                          p.observe(\.isPaused) { _, _ in changed() },
                          p.observe(\.isIndeterminate) { _, _ in changed() }]
        downloads[ObjectIdentifier(p)] = d
        EventLog.write("download+ \(Self.fileURL(p)?.lastPathComponent ?? "?") app=\(d.attribution.app ?? "-")\(d.attribution.fallback ? " (frontmost fallback)" : " (quarantine)")")
        progressChanged()
    }

    private func downloadGone(_ id: ObjectIdentifier) {
        guard let d = downloads.removeValue(forKey: id) else { return }
        EventLog.write("download- \(Self.fileURL(d.progress)?.lastPathComponent ?? "?")")
        progressChanged()
    }

    /// At most 10 redraws per second.
    private func progressChanged() {
        guard !progressFlushScheduled else { return }
        progressFlushScheduled = true
        let delay = max(0, lastProgressFlush + 0.1 - CFAbsoluteTimeGetCurrent())
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flushProgress() }
    }

    private func flushProgress() {
        progressFlushScheduled = false
        lastProgressFlush = CFAbsoluteTimeGetCurrent()
        guard running else { return }
        var groups: [String: [Transfer]] = [:]
        for d in downloads.values where !d.progress.isFinished && !d.progress.isCancelled {
            if d.attribution.fallback, let agent = agentApp(d.progress) {
                d.attribution = Self.attribute(d.attribution, agentApp: agent, frontmost: nil)
                EventLog.write("download \(Self.fileURL(d.progress)?.lastPathComponent ?? "?") re-attributed app=\(agent) (quarantine)")
            }
            guard let app = d.attribution.app else { continue }
            let p = d.progress
            groups[app, default: []].append(Transfer(completed: p.completedUnitCount, total: p.isIndeterminate ? 0 : p.totalUnitCount,
                                                     paused: p.isPaused))
        }
        let next = groups.compactMapValues(Self.aggregate)
        guard next != progress else { return }
        for (app, s) in next where progress[app] != s {
            EventLog.write("progress \(app) \(s.fraction.map { "\(Int($0 * 100))%" } ?? "indeterminate")\(s.paused ? " paused" : "")")
        }
        for app in progress.keys where next[app] == nil { EventLog.write("progress \(app) cleared") }
        progress = next
        onChange?()
    }

    /// The running app named by the file's quarantine agent, if readable.
    private func agentApp(_ p: Progress) -> String? {
        guard let url = Self.fileURL(p), let agent = Self.quarantineAgent(Self.xattr(url, "com.apple.quarantine") ?? "") else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == agent }?.bundleIdentifier
    }

    /// Publishers set userInfo[.fileURLKey]; `fileURL` came back nil on the subscriber side (verified 2026-10-03).
    private static func fileURL(_ p: Progress) -> URL? { p.fileURL ?? p.userInfo[.fileURLKey] as? URL }

    private static func xattr(_ url: URL, _ name: String) -> String? {
        let n = getxattr(url.path, name, nil, 0, 0, 0)
        guard n > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: n)
        guard getxattr(url.path, name, &buf, n, 0, 0) == n else { return nil }
        return String(decoding: buf, as: UTF8.self)
    }

    // MARK: Pure logic (covered by --self-test)

    struct Transfer {
        var completed: Int64
        var total: Int64   // ≤ 0: unknown
        var paused: Bool
    }

    /// Requirement 28: completed / total summed over known totals; paused only if all are paused;
    /// indeterminate if none has a known total.
    static func aggregate(_ ts: [Transfer]) -> ProgressState? {
        guard !ts.isEmpty else { return nil }
        let known = ts.filter { $0.total > 0 }
        let total = known.reduce(Int64(0)) { $0 + $1.total }, done = known.reduce(Int64(0)) { $0 + min(max($1.completed, 0), $1.total) }
        return ProgressState(fraction: known.isEmpty ? nil : Double(done) / Double(total), paused: ts.allSatisfy(\.paused))
    }

    /// First seen (current nil): the quarantine agent's app, else the frontmost app (fallback). Afterwards
    /// only a fallback changes, and only to a readable agent; later frontmost changes never matter.
    static func attribute(_ current: Attribution?, agentApp: String?, frontmost: String?) -> Attribution {
        if let agentApp, current?.fallback ?? true { return Attribution(app: agentApp, fallback: false) }
        return current ?? Attribution(app: frontmost, fallback: true)
    }

    /// Third `;`-separated field of `com.apple.quarantine` (e.g. `0083;66fe1234;Vivaldi;UUID`).
    static func quarantineAgent(_ value: String) -> String? {
        let f = value.split(separator: ";", omittingEmptySubsequences: false)
        return f.count >= 3 && !f[2].isEmpty ? String(f[2]) : nil
    }

    static let pulse: CFAbsoluteTime = 1.06, maxPulses: Double = 7

    /// Requirement 29 at `now`, plus the time the state next changes on its own. Ended during the first
    /// 7 pulses → the current pulse finishes, then none; still requested after 7 → hold. Reduce Motion:
    /// the plate while requested, no pulses.
    static func attention(start: CFAbsoluteTime, ended: CFAbsoluteTime?, now: CFAbsoluteTime,
                          reduceMotion: Bool) -> (AttentionState, CFAbsoluteTime?) {
        if reduceMotion { return (ended == nil ? .holding : .none, nil) }
        let end = start + pulse * (ended.map { min(maxPulses, max(1, ceil(($0 - start) / pulse))) } ?? maxPulses)
        if now < end { return (.pulsing(since: start), end) }
        return (ended == nil ? .holding : .none, nil)
    }
}
