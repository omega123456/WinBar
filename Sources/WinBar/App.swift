import AppKit
import ApplicationServices
import ServiceManagement

@main
enum WinBarMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--self-test") { exit(SelfTest.run() ? 0 : 1) } // before any UI
        if args.contains("--log-events") { EventLog.enable() } else { EventLog.removeFile() }
        let app = NSApplication.shared // LSUIElement: no Dock icon, no menu bar
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// What WinBar observes and acts on outside itself. Tests substitute fakes (Tests/WinBarTests) so they never touch
/// the real desktop, apps or defaults; production never changes these.
enum Env {
    static var workspace = NSWorkspace.shared
    static var screens: () -> [NSScreen] = { NSScreen.screens }
    static var defaults = UserDefaults.standard
}

/// `--log-events`: millisecond-timestamped plain-text lines in ~/Library/Logs/WinBar/events.log
/// (WinBar Dev: ~/Library/Logs/WinBar Dev/events.log), cleared at each launch. The file only exists while the flag is used.
enum EventLog {
    private static var handle: FileHandle?
    #if DEBUG
    private static let folder = "WinBar Dev"
    #else
    private static let folder = "WinBar"
    #endif
    static var url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(folder)/events.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func enable() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil) // truncates
        handle = try? FileHandle(forWritingTo: url)
    }

    static func removeFile() { try? FileManager.default.removeItem(at: url) }

    static func write(_ line: @autoclosure () -> String) {
        guard let handle else { return }
        handle.write(Data("\(formatter.string(from: Date())) \(line())\n".utf8))
    }
}

/// Launch at Login via SMAppService.mainApp; the status is always read live, never mirrored.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Enabled → unregister. Requires approval → open Login Items. Otherwise → register
    /// (and open Login Items if the system then asks for approval).
    static func toggle() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            EventLog.write("launch at login failed: \(error)")
        }
        EventLog.write("launch at login status=\(service.status.rawValue)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let tracker = WindowTracker()
    let signals = Signals()
    private(set) var preview: PreviewController!
    private(set) var bar: BarController!
    private var grantPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        EventLog.write("WinBar started pid=\(getpid())")
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25) // global AX timeout
        preview = PreviewController(tracker: tracker)
        bar = BarController(tracker: tracker, signals: signals, preview: preview)
        tracker.onChange = { [weak self] in self?.bar.render() }
        tracker.onWindowRemoved = { [weak self] in self?.preview.windowRemoved($0) }
        signals.onChange = { [weak self] in self?.bar.render() }
        observeTheme()
        Updater.start() // independent of Accessibility trust
        guard AX.isWindowIDAvailable else {
            EventLog.write("_AXUIElementGetWindow unavailable: WinBar is not compatible with this macOS version")
            bar.access = .incompatible
            return
        }
        AX.onAPIDisabled = { [weak self] in
            DispatchQueue.main.async { self?.updateTrust(AX.isTrusted(false)) }
        }
        // Never-active agent: distributed notifications must be delivered immediately, not on activation.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessibilityChanged),
            name: Notification.Name("com.apple.accessibility.api"), object: nil,
            suspensionBehavior: .deliverImmediately)
        updateTrust(AX.isTrusted(true))
    }

    /// Accent colour and accessibility display options re-apply to the bars immediately (the bar is always dark).
    private func observeTheme() {
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
        Env.workspace.notificationCenter.addObserver(
            self, selector: #selector(themeChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @objc private func themeChanged() { bar.themeChanged() }

    @objc private func accessibilityChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.updateTrust(AX.isTrusted(false))
        }
    }

    /// Trusted → stop the grant poll and track. Untrusted → stop tracking and poll every 1 s.
    private func updateTrust(_ trusted: Bool) {
        bar.access = trusted ? .trusted : .untrusted // call to action while untrusted
        if trusted {
            grantPoll?.invalidate()
            grantPoll = nil
            BarClickTap.install()
            if !tracker.isTracking {
                EventLog.write("accessibility trusted")
                tracker.start()
                signals.start()
            }
            requestScreenRecordingOnce()
        } else {
            if tracker.isTracking {
                EventLog.write("accessibility revoked")
                preview.hideNow()
                signals.stop()
                tracker.stop()
            }
            if grantPoll == nil {
                EventLog.write("waiting for accessibility (1 s poll)")
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    if AX.isTrusted(false) { self?.updateTrust(true) }
                }
                timer.tolerance = 0.2
                RunLoop.main.add(timer, forMode: .common)
                grantPoll = timer
            }
        }
    }

    /// Requirement 32: asked once ever, after Accessibility is granted; the request is remembered.
    private func requestScreenRecordingOnce() {
        let key = "screenRecordingRequested"
        guard !Env.defaults.bool(forKey: key) else { return }
        Env.defaults.set(true, forKey: key)
        let granted = CGPreflightScreenCaptureAccess()
        EventLog.write("screen recording \(granted ? "already granted" : "requested")")
        if !granted { CGRequestScreenCaptureAccess() }
    }
}
