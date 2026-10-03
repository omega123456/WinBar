import AppKit
import Security

/// Self-update from GitHub Releases: checked at launch and hourly unless turned off, or on demand from the bar menu.
/// Dialogs are CFUserNotifications: shown by the system, so WinBar never becomes active and the bar keeps
/// updating while one is open. A download is installed only if it satisfies the running app's own designated
/// requirement (same identifier, same "WinBar Local Signing" leaf certificate), which also keeps the TCC grants.
enum Updater {
    static let repo = "omega123456/WinBar"
    private static let disabledKey = "autoUpdateDisabled"
    private static var timer: Timer?
    private static var busy = false // a check, prompt or install is in progress
    private static var prompt: (note: CFUserNotification, source: CFRunLoopSource, onUpdate: () -> Void)?

    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: disabledKey) }
    private static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    /// `swift run` has no .app bundle: nothing to replace.
    private static var isInstallable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func start() {
        guard isEnabled, isInstallable, timer == nil else { return }
        check(manual: false)
        let t = Timer(timeInterval: 3600, repeats: true) { _ in check(manual: false) }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func toggle() {
        UserDefaults.standard.set(isEnabled, forKey: disabledKey)
        EventLog.write("automatic updates \(isEnabled ? "on" : "off")")
        if isEnabled { start() } else { timer?.invalidate(); timer = nil }
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let assets: [Asset]
    }

    static func check(manual: Bool) {
        guard isInstallable else { if manual { notice("Updates unavailable", "This copy of WinBar is not an installed app.") }; return }
        guard !busy else { return }
        busy = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = status == 200 ? data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) } : nil
            DispatchQueue.main.async {
                busy = false
                guard let release else {
                    EventLog.write("update check failed: status=\(status) \(error.map { "\($0)" } ?? "")")
                    if manual { notice("Couldn't check for updates", error?.localizedDescription ?? "GitHub returned status \(status).") }
                    return
                }
                let version = String(release.tag_name.trimmingPrefix("v"))
                guard isNewer(version, than: current),
                      let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") })?.browser_download_url else {
                    EventLog.write("update check: \(current) is current (latest \(version))")
                    if manual { notice("WinBar is up to date", "You have the latest version, \(current).") }
                    return
                }
                EventLog.write("update available: \(version)")
                ask(version) { install(zip, version: version) }
            }
        }.resume()
    }

    // MARK: Dialogs

    private static var iconURL: URL? { Bundle.main.url(forResource: "AppIcon", withExtension: "icns") }

    private static func ask(_ version: String, onUpdate: @escaping () -> Void) {
        var dict: [CFString: Any] = [
            kCFUserNotificationAlertHeaderKey: "WinBar \(version) is available",
            kCFUserNotificationAlertMessageKey: "You have \(current). Do you want to update now?",
            kCFUserNotificationDefaultButtonTitleKey: "Update Now",
            kCFUserNotificationAlternateButtonTitleKey: "Later",
        ]
        if let iconURL { dict[kCFUserNotificationIconURLKey] = iconURL as CFURL }
        var err: Int32 = 0
        guard let note = CFUserNotificationCreate(nil, 0, kCFUserNotificationNoteAlertLevel, &err, dict as CFDictionary),
              let source = CFUserNotificationCreateRunLoopSource(nil, note, { _, flags in
                  guard let p = Updater.prompt else { return }
                  CFRunLoopRemoveSource(CFRunLoopGetMain(), p.source, .commonModes)
                  Updater.prompt = nil
                  Updater.busy = false
                  if flags & 0x3 == CFOptionFlags(kCFUserNotificationDefaultResponse) { p.onUpdate() }
              }, 0)
        else { EventLog.write("update prompt failed: \(err)"); return }
        busy = true // until answered: no second prompt from the hourly check
        prompt = (note, source, onUpdate)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// One-button, non-blocking.
    private static func notice(_ header: String, _ message: String) {
        CFUserNotificationDisplayNotice(0, kCFUserNotificationPlainAlertLevel, iconURL as CFURL?, nil, nil,
                                        header as CFString, message as CFString, "OK" as CFString)
    }

    // MARK: Install

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func install(_ zip: URL, version: String) {
        busy = true
        EventLog.write("update: downloading \(zip)")
        URLSession.shared.downloadTask(with: zip) { file, _, error in
            // The downloaded file is deleted when this returns, so unpack and verify here (off the main thread).
            let result = Result { try unpack(file, error, version) }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let app): replaceAndRelaunch(with: app)
                case .failure(let e):
                    EventLog.write("update failed: \(e)")
                    notice("WinBar update failed", e.localizedDescription)
                }
            }
        }.resume()
    }

    /// Download → <replacement dir on the app's volume>/WinBar.app, verified. Returns the new bundle.
    private static func unpack(_ file: URL?, _ error: Error?, _ version: String) throws -> URL {
        guard let file else { throw error ?? UpdateError("The download failed.") }
        let fm = FileManager.default
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                             appropriateFor: Bundle.main.bundleURL, create: true)
        do {
            let zip = dir.appendingPathComponent("update.zip")
            try fm.moveItem(at: file, to: zip)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, dir.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw UpdateError("The download could not be unpacked.") }
            let app = dir.appendingPathComponent("WinBar.app")
            try verify(app)
            guard Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String == version else {
                throw UpdateError("The download is not WinBar \(version).")
            }
            return app
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// The new bundle must be validly signed and satisfy this running app's designated requirement.
    private static func verify(_ app: URL) throws {
        var me: SecCode?, meStatic: SecStaticCode?, requirement: SecRequirement?, new: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement
        else { throw UpdateError("This copy of WinBar has no usable code signature.") }
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new,
              SecStaticCodeCheckValidity(new, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                                         requirement) == errSecSuccess
        else { throw UpdateError("The download is not signed by WinBar Local Signing.") }
    }

    private static func replaceAndRelaunch(with app: URL) {
        let dest = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: app)
            try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            // Wait for this process to exit, then open the new bundle.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                                  dest.path, String(getpid())]
            try relaunch.run()
        } catch {
            EventLog.write("update install failed: \(error)")
            notice("WinBar update failed", error.localizedDescription)
            return
        }
        EventLog.write("update installed, relaunching")
        NSApp.terminate(nil)
    }

    // MARK: Pure logic (covered by --self-test)

    /// Numeric dotted-version comparison; a leading "v" is ignored and missing components count as 0.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingPrefix("v").split(separator: ".").map { Int($0) ?? 0 } }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
