import AppKit
import Testing
@testable import WinBar

extension Desktop {
    @MainActor @Suite struct AppTests {
        @Test func followsAccessibilityTrust() async {
            let h = Harness()
            h.ax.trusted = false
            let a = h.app(91001, "test.alpha")
            h.window(5001, of: a, "One")
            let d = AppDelegate()
            d.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            #expect(d.bar.access == .untrusted)
            #expect(!d.tracker.isTracking)

            // Granted: noticed by the 1 s poll.
            h.ax.trusted = true
            await settle(1.3)
            #expect(d.bar.access == .trusted)
            #expect(d.tracker.isTracking)
            await settle()
            #expect(d.tracker.windows[5001] != nil)

            // Revoked: reported by an AX call.
            h.ax.trusted = false
            AX.onAPIDisabled?()
            await settle()
            #expect(d.bar.access == .untrusted)
            #expect(!d.tracker.isTracking)

            // The system's Accessibility notification re-checks after 0.25 s.
            h.ax.trusted = true
            d.perform(Selector(("accessibilityChanged")))
            await settle(0.4)
            #expect(d.tracker.isTracking)
            h.ws.contrast = true
            d.perform(Selector(("themeChanged")))

            d.signals.stop()
            d.tracker.stop()
        }

        @Test func incompatibleWithoutWindowIDs() {
            let h = Harness()
            AX.isWindowIDAvailable = false
            let d = AppDelegate()
            d.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            #expect(d.bar.access == .incompatible)
            #expect(h.log.contains("not compatible"))
        }

        @Test func eventLog() {
            let h = Harness()
            EventLog.write("hello")
            #expect(h.log.contains("hello"))
            EventLog.removeFile()
            #expect(!FileManager.default.fileExists(atPath: EventLog.url.path))
            _ = LaunchAtLogin.isEnabled
        }

        /// The live AX backend, against this (untrusted) test process: every call fails fast.
        @Test func liveAXBackend() {
            let h = Harness()
            _ = h
            let live = AX.Backend()
            let me = AXUIElementCreateApplication(getpid())
            _ = live.copy(me, kAXRoleAttribute)
            _ = live.copyMultiple(me, [kAXRoleAttribute])
            _ = live.set(me, kAXFrontmostAttribute, kCFBooleanTrue)
            _ = live.perform(me, kAXRaiseAction)
            #expect(live.windowID(me) == nil)
            #expect(live.pid(me) == getpid())
            let observer = live.createObserver(getpid()) { _, _, _, _ in }
            #expect(observer != nil)
            var refcon = 0
            _ = live.addNotification(observer!, me, kAXWindowCreatedNotification, &refcon)
            _ = live.isTrusted(false)
            // The real window list, Spaces SPI and permission check the fakes stand in for (all read-only).
            _ = liveSeams.onScreen()
            _ = liveSeams.spaces()
            _ = liveSeams.permission()
        }

        /// AX vocabulary edge cases.
        @Test func axReads() throws {
            let h = Harness()
            let el = h.ax.element(of: 91001)
            h.ax.attrs[el] = [kAXTitleAttribute: "T" as CFString, kAXMainAttribute: kCFBooleanTrue, kAXPositionAttribute: "x" as CFString]
            #expect(try AX.string(el, kAXTitleAttribute) == "T")
            #expect(try AX.bool(el, kAXMainAttribute) == true)
            #expect(try AX.element(el, kAXTitleAttribute) == nil)
            #expect(AX.point(try AX.raw(el, kAXPositionAttribute)) == nil)
            #expect(AX.size(nil) == nil)
            let v = try #require(try AX.values(el, [kAXTitleAttribute, kAXSizeAttribute]))
            #expect(v[1] == nil)
            h.ax.failing[el] = .apiDisabled
            var disabled = 0
            AX.onAPIDisabled = { disabled += 1 }
            #expect(throws: AXFailure.apiDisabled) { try AX.raw(el, kAXTitleAttribute) }
            #expect(disabled == 1)
            h.ax.failing[el] = .notificationAlreadyRegistered
            var refcon = 0
            #expect(try AX.observe(AX.backend.createObserver(91001, { _, _, _, _ in })!, el, kAXTitleChangedNotification, &refcon))
            h.ax.failing[el] = .cannotComplete
            #expect(throws: AXFailure.timeout) { try AX.isDestroyed(el) }
            AX.removeObserver(AX.makeObserver(91001, { _, _, _, _ in })!)
        }
    }
}
