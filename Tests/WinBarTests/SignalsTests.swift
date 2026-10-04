import AppKit
import Testing
@testable import WinBar

extension Desktop {
    @MainActor @Suite struct SignalsTests {
        @Test func badgesFromTheDock() async {
            let h = Harness()
            let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first!.processIdentifier
            let dock = AXUIElementCreateApplication(dockPid)
            let list = h.ax.element(of: dockPid), textEdit = h.ax.element(of: dockPid), separator = h.ax.element(of: dockPid)
            h.ax.attrs[dock] = [kAXChildrenAttribute: [list] as CFArray]
            h.ax.attrs[list] = [kAXChildrenAttribute: [textEdit, separator] as CFArray]
            h.ax.attrs[textEdit] = [kAXSubroleAttribute: "AXApplicationDockItem" as CFString, "AXStatusLabel": "3" as CFString,
                                    kAXURLAttribute: URL(fileURLWithPath: "/System/Applications/TextEdit.app") as CFURL]
            h.ax.attrs[separator] = [kAXSubroleAttribute: "AXSeparatorDockItem" as CFString]
            let s = Signals()
            var changes = 0
            s.onChange = { changes += 1 }
            s.start()
            s.start()
            await settle()
            #expect(s.badges == ["com.apple.TextEdit": .count("3")])

            // Each resume ticks at once: the badge clears.
            h.ax.attrs[textEdit]!["AXStatusLabel"] = "" as CFString
            h.ws.post(NSWorkspace.screensDidSleepNotification)
            h.ws.post(NSWorkspace.screensDidWakeNotification)
            #expect(s.badges.isEmpty)

            // Overlapping pauses: the poll resumes only when all have ended.
            h.ax.attrs[textEdit]!["AXStatusLabel"] = "!" as CFString
            h.ws.post(NSWorkspace.sessionDidResignActiveNotification)
            s.perform(Selector(("screenLocked")))
            h.ws.post(NSWorkspace.sessionDidBecomeActiveNotification)
            #expect(s.badges.isEmpty)
            s.perform(Selector(("screenUnlocked")))
            #expect(s.badges == ["com.apple.TextEdit": .alert])

            // Launches refresh the item list (coalesced, 0.5 s later); known items are kept.
            h.ws.post(NSWorkspace.didLaunchApplicationNotification)
            h.ws.post(NSWorkspace.didLaunchApplicationNotification)
            await settle(0.7)
            #expect(h.log.contains("badge dock items=1"))

            // Timeouts: a tick is abandoned; a refresh waits for the next launch or quit.
            h.ax.failing[textEdit] = .cannotComplete
            h.ws.post(NSWorkspace.screensDidSleepNotification)
            h.ws.post(NSWorkspace.screensDidWakeNotification)
            #expect(h.log.contains("badge tick abandoned"))
            h.ax.failing[dock] = .cannotComplete
            h.ws.post(NSWorkspace.didTerminateApplicationNotification)
            await settle(0.7)
            #expect(h.log.contains("retried on the next launch/quit"))

            s.stop()
            s.stop()
            #expect(s.badges.isEmpty)
        }

        @Test func attention() async {
            let h = Harness()
            let s = Signals()
            s.start()
            func asn(_ pid: pid_t) -> CFTypeRef { NSNumber(value: pid) }

            s.attentionEvent(asn(91001), true)
            guard case .pulsing = s.attention[91001] else { Issue.record("not pulsing"); return }
            s.attentionEvent(asn(91001), true)      // already requested
            s.attentionEvent("?" as CFString, true) // pid lookup failed
            s.attentionEvent(asn(1234), false)      // never requested
            s.attentionEvent(asn(91001), false)     // ended in the first pulse: that pulse finishes
            s.attentionEvent(asn(91001), false)
            #expect(s.attention[91001] != nil)
            await settle(1.2)
            #expect(s.attention.isEmpty)

            // Reduce Motion: held while requested, none once ended.
            h.ws.reduceMotion = true
            s.attentionEvent(asn(91002), true)
            #expect(s.attention[91002] == .holding)
            s.attentionEvent(asn(91002), false)
            #expect(s.attention.isEmpty)

            // Activation and quit clear a request at once.
            s.attentionEvent(asn(91003), true)
            s.attentionEvent(asn(91004), true)
            h.ws.post(NSWorkspace.didActivateApplicationNotification, FakeApp(91003, nil))
            h.ws.post(NSWorkspace.didActivateApplicationNotification, FakeApp(91009, nil))
            h.ws.post(NSWorkspace.didTerminateApplicationNotification, FakeApp(91004, nil))
            #expect(s.attention.isEmpty)

            s.stop()
            s.attentionEvent(asn(91001), true) // stopped: ignored
            #expect(s.attention.isEmpty)
        }

        @Test func downloadProgress() async throws {
            let h = Harness()
            h.ws.apps = [FakeApp(91010, "test.vivaldi", "Vivaldi")]
            h.ws.front = FakeApp(91011, "test.front", "Front")
            let s = Signals()
            s.start()
            await settle(0.3) // folder check, then subscription
            #expect(h.log.contains("downloads folder readable"))

            func download(_ name: String, quarantine: String?) -> Progress {
                let file = h.dir.appendingPathComponent(name)
                FileManager.default.createFile(atPath: file.path, contents: Data())
                if let quarantine { setxattr(file.path, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, 0) }
                let p = Progress(totalUnitCount: 100)
                p.kind = .file
                p.fileOperationKind = .downloading
                p.setUserInfoObject(file, forKey: .fileURLKey)
                p.isPausable = true
                p.publish()
                return p
            }
            let a = download("a.zip", quarantine: "0083;66fe1234;Vivaldi;UUID")
            let b = download("b.zip", quarantine: nil)
            await settle(0.5)
            #expect(s.progress["test.vivaldi"] == ProgressState(fraction: 0, paused: false))
            #expect(s.progress["test.front"] == ProgressState(fraction: 0, paused: false))

            a.completedUnitCount = 40
            b.totalUnitCount = -1
            await settle(0.5)
            #expect(s.progress["test.vivaldi"] == ProgressState(fraction: 0.4, paused: false))
            #expect(s.progress["test.front"] == ProgressState(fraction: nil, paused: false))

            // A fallback owner is replaced once the quarantine agent is readable.
            let bFile = h.dir.appendingPathComponent("b.zip").path
            setxattr(bFile, "com.apple.quarantine", "0083;66fe1234;Vivaldi;UUID", 27, 0, 0)
            a.pause()
            await settle(0.5)
            #expect(s.progress["test.front"] == nil)
            #expect(s.progress["test.vivaldi"]?.paused == false)

            a.unpublish()
            b.unpublish()
            await settle(0.5)
            #expect(s.progress.isEmpty)
            s.stop()
        }
    }
}
