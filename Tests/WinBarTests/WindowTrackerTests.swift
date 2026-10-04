import AppKit
import Testing
@testable import WinBar

extension Desktop {
    @MainActor @Suite struct WindowTrackerTests {
        @Test func tracksAppsWindowsAndAXEvents() async {
            let h = Harness()
            let a = h.app(91001, "test.alpha", "Alpha")
            let b = h.app(91002, "test.beta", "Beta")
            let w1 = h.window(5001, of: a, "One")
            let w2 = h.window(5002, of: a)
            // Bottom edge on the visible frame's bottom (maximized): shrunk to end above the bar.
            let w3 = h.window(5003, of: b, "Max", frame: h.main.visibleFrame)
            h.ws.front = a
            h.ax.attrs[h.element(a)]![kAXFocusedWindowAttribute] = w1
            let t = WindowTracker()
            var changes = 0
            var removed: [CGWindowID] = []
            t.onChange = { changes += 1 }
            t.onWindowRemoved = { removed.append($0) }
            t.start()
            t.start()
            await settle()

            #expect(t.visibleWindows.map(\.id) == [5001, 5002, 5003])
            #expect(t.visibleWindows(onDisplay: 4242).count == 3)
            #expect(t.app(of: t.windows[5001]!)?.name == "Alpha")
            #expect(t.activeWindowID == 5001)
            #expect(t.windows[5001]!.lastFocused > 0)
            #expect(h.ax.sets.contains { $0.element == w3 && $0.attribute == kAXSizeAttribute })
            #expect(changes == 1)

            // Title change; an untracked element's destruction is ignored.
            h.ax.attrs[w1]![kAXTitleAttribute] = "Renamed" as CFString
            h.ax.post(kAXTitleChangedNotification, w1)
            h.ax.post(kAXUIElementDestroyedNotification, h.ax.element(of: a.pid))
            await settle()
            #expect(t.windows[5001]?.title == "Renamed")

            // Moved onto the side display.
            h.screens = [h.main, h.side]
            h.setFrame(w2, CGRect(x: -18700, y: -19800, width: 200, height: 200))
            h.ax.post(kAXMovedNotification, w2)
            await settle()
            #expect(t.windows[5002]?.displayID == 4243)

            // Minimizing the active window: no active window; restoring forces it on screen while CG lags.
            h.ax.attrs[w1]![kAXMinimizedAttribute] = kCFBooleanTrue
            h.ax.post(kAXWindowMiniaturizedNotification, w1)
            await settle()
            #expect(t.windows[5001]?.isMinimized == true)
            #expect(t.activeWindowID == nil)
            h.ax.attrs[w1]![kAXMinimizedAttribute] = kCFBooleanFalse
            h.onScreen.remove(5001)
            h.ax.post(kAXWindowDeminiaturizedNotification, w1)
            await settle()
            #expect(t.windows[5001]?.isMinimized == false)
            #expect(t.windows[5001]?.isVisible == true)
            h.onScreen.insert(5001)

            // A created window is on screen before CG lists it.
            let w4 = h.window(5004, of: b, "New", listed: false)
            h.ax.post(kAXWindowCreatedNotification, w4)
            await settle()
            #expect(t.windows[5004]?.isVisible == true)

            // Focus moves within the app.
            h.ax.attrs[h.element(a)]![kAXFocusedWindowAttribute] = w2
            h.ax.post(kAXFocusedWindowChangedNotification, h.element(a))
            await settle()
            #expect(t.activeWindowID == 5002)

            // Destroyed.
            h.ax.post(kAXUIElementDestroyedNotification, w2)
            await settle()
            #expect(t.windows[5002] == nil)
            #expect(removed == [5002])
            #expect(t.activeWindowID == nil)

            // A failed read of a dead window removes it.
            h.ax.failing[w4] = .invalidUIElement
            h.ax.post(kAXResizedNotification, w4)
            await settle()
            #expect(t.windows[5004] == nil)

            // A timeout abandons that app's reads for the flush.
            h.ax.failing[w3] = .cannotComplete
            h.ax.post(kAXResizedNotification, w3)
            await settle()
            #expect(h.log.contains("skipping app until its next event"))

            // Space change: rescan. Dead windows missing from the AX list go; dialogs and ID-less elements are skipped.
            h.ax.failing[w3] = .invalidUIElement
            h.ax.attrs[h.element(b)]![kAXWindowsAttribute] = [] as CFArray
            let dialog = h.window(5005, of: a, "Dialog", listed: false)
            h.ax.attrs[dialog]![kAXSubroleAttribute] = kAXDialogSubrole as CFString
            h.ax.attrs[h.element(a)]![kAXWindowsAttribute] = [w1, dialog, h.ax.element(of: a.pid)] as CFArray
            h.ws.post(NSWorkspace.activeSpaceDidChangeNotification)
            await settle(1.2) // + the re-read after a full-screen exit animation
            #expect(t.windows[5003] == nil)
            #expect(t.windows[5005] == nil)

            // Full-screen Space on the (single, "Main") display set.
            h.spaces = [["Current Space": ["type": 4], "Display Identifier": "Main"]]
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            await settle()
            #expect(t.fullScreenDisplays == [4242, 4243])

            // Hide / unhide.
            a.fakeHidden = true
            h.ws.post(NSWorkspace.didHideApplicationNotification, a)
            h.ws.post(NSWorkspace.didHideApplicationNotification, FakeApp(1, nil)) // untracked
            await settle()
            #expect(t.apps[a.pid]?.isHidden == true)
            #expect(t.windows[5001]?.isVisible == false)
            a.fakeHidden = false
            h.ws.post(NSWorkspace.didUnhideApplicationNotification, a)
            await settle()
            #expect(t.windows[5001]?.isVisible == true)

            // Launches: regular apps only; activation can arrive first. Quit drops the app and its windows.
            let c = h.app(91003, "test.gamma", running: false)
            h.ws.post(NSWorkspace.didLaunchApplicationNotification, c)
            let accessory = FakeApp(91004, "test.accessory")
            accessory.fakePolicy = .accessory
            h.ws.post(NSWorkspace.didLaunchApplicationNotification, accessory)
            let d = h.app(91006, "test.delta", running: false)
            h.ws.post(NSWorkspace.didActivateApplicationNotification, d)
            h.ws.post(NSWorkspace.didTerminateApplicationNotification, a)
            h.ws.post(NSWorkspace.didTerminateApplicationNotification, FakeApp(2, nil))
            await settle()
            #expect(t.apps[91003] != nil)
            #expect(t.apps[91004] == nil)
            #expect(t.apps[91006] != nil)
            #expect(t.apps[a.pid] == nil)
            #expect(t.windows.isEmpty)

            // Activating WinBar itself changes nothing; an untracked app clears the active window.
            h.ax.attrs[h.element(c)]![kAXFocusedWindowAttribute] = h.window(5006, of: c, "C")
            h.ws.front = c
            h.ws.post(NSWorkspace.didActivateApplicationNotification, c)
            await settle()
            #expect(t.activeWindowID == 5006)
            h.ws.post(NSWorkspace.didActivateApplicationNotification, FakeApp(getpid(), nil))
            h.ws.post(NSWorkspace.didActivateApplicationNotification, nil)
            await settle()
            #expect(t.activeWindowID == 5006)
            h.ws.post(NSWorkspace.didActivateApplicationNotification, accessory)
            await settle()
            #expect(t.activeWindowID == nil)

            t.stop()
            t.stop()
            #expect(!t.isTracking)
            #expect(t.apps.isEmpty)
            h.ax.post(kAXTitleChangedNotification, w1) // after stop: ignored
        }

        @Test func observerRetriesThenWaitsForTheAppsNextEvent() async {
            let h = Harness()
            let a = h.app(91001, "test.alpha")
            h.window(5001, of: a, "One")
            let b = h.app(91002, "test.beta")
            h.ax.failing[h.element(a)] = .failure // registration refused
            h.ax.noObserver.insert(b.pid)
            let t = WindowTracker()
            t.start()
            await settle(2)
            #expect(h.log.contains("observer gave up pid=91001"))
            #expect(h.log.contains("observer gave up pid=91002"))
            #expect(t.windows.isEmpty)

            h.ax.failing[h.element(a)] = nil
            h.ws.post(NSWorkspace.didUnhideApplicationNotification, a)
            await settle()
            #expect(t.windows[5001] != nil)
            t.stop()
        }

        @Test func actions() async {
            let h = Harness()
            let a = h.app(91001, "test.alpha", "Alpha")
            let app = h.element(a)
            let w1 = h.window(5001, of: a, "One")
            let w2 = h.window(5002, of: a, "Two", minimized: true)
            let close = h.ax.element(of: a.pid)
            h.ax.attrs[w1]![kAXCloseButtonAttribute] = close
            // ⌘N: top-level menu → its menu → items (one unreadable, one ⌘O, one ⌘N).
            let bar = h.ax.element(of: a.pid), top = h.ax.element(of: a.pid), menu = h.ax.element(of: a.pid)
            let broken = h.ax.element(of: a.pid), open = h.ax.element(of: a.pid), new = h.ax.element(of: a.pid)
            h.ax.attrs[app]![kAXMenuBarAttribute] = bar
            h.ax.attrs[bar] = [kAXChildrenAttribute: [top] as CFArray]
            h.ax.attrs[top] = [kAXChildrenAttribute: [menu] as CFArray]
            h.ax.attrs[menu] = [kAXChildrenAttribute: [broken, open, new] as CFArray]
            h.ax.failing[broken] = .failure
            h.ax.attrs[open] = [kAXMenuItemCmdCharAttribute: "O" as CFString, kAXMenuItemCmdModifiersAttribute: 0 as CFNumber]
            h.ax.attrs[new] = [kAXMenuItemCmdCharAttribute: "n" as CFString, kAXMenuItemCmdModifiersAttribute: 0 as CFNumber]
            let t = WindowTracker()
            t.start()
            await settle()

            t.focus(5001)
            #expect(h.ax.sets.contains { $0.element == app && $0.attribute == kAXFrontmostAttribute })
            #expect(h.ax.sets.contains { $0.element == w1 && $0.attribute == kAXMainAttribute })
            #expect(h.ax.performed.contains { $0.element == w1 && $0.action == kAXRaiseAction })

            a.fakeHidden = true
            h.ws.post(NSWorkspace.didHideApplicationNotification, a)
            await settle()
            t.focus(5002) // hidden app unhidden, minimized window restored first
            #expect(a.unhides == 1)
            #expect(h.ax.sets.contains { $0.element == w2 && $0.attribute == kAXMinimizedAttribute })

            t.minimize(5001)
            t.close(5001)
            #expect(h.ax.performed.contains { $0.element == close && $0.action == kAXPressAction })
            t.unhide(a.pid)
            t.quit(a.pid)
            #expect(a.unhides == 2)
            #expect(a.terminates == 1)

            #expect(t.newWindowItem(a.pid) == new)
            #expect(t.newWindowItem(a.pid) == new) // cached
            #expect(t.newWindowItem(99) == nil)
            t.newWindow(a.pid)
            #expect(h.ax.performed.contains { $0.element == new && $0.action == kAXPressAction })

            t.focus(99)
            t.minimize(99)
            t.close(99)

            // Un-minimizing keeps the app busy: front/main/raise is retried once the animation is over.
            h.ax.failing[app] = .cannotComplete
            t.focus(5002)
            await settle(0.7)
            #expect(h.log.contains("focus 5002 after restore failed"))
            h.ax.failing[w1] = .cannotComplete
            t.minimize(5001)
            #expect(h.log.contains("action minimize 5001 failed"))

            // Activation drops the ⌘N cache; a timed-out search is not cached.
            h.ax.failing[app] = nil
            h.ws.post(NSWorkspace.didActivateApplicationNotification, a)
            await settle()
            h.ax.failing[bar] = .cannotComplete
            #expect(t.newWindowItem(a.pid) == nil)
            #expect(h.log.contains("during ⌘N search"))
            t.stop()
        }
    }
}
