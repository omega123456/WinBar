import AppKit
import Testing
@testable import WinBar

extension TaskbarPanel {
    var taskbarButtons: [TaskbarButton] { contentView!.subviews.compactMap { $0 as? TaskbarButton }.sorted { $0.frame.minX < $1.frame.minX } }
    func button(_ key: ItemKey) -> TaskbarButton? { taskbarButtons.first { $0.key == key } }
    var background: BarBackgroundView { contentView!.subviews.compactMap { $0 as? BarBackgroundView }[0] }
}

/// The visible bar on a fake screen.
@MainActor func panel(on screen: NSScreen) -> TaskbarPanel? {
    NSApp.windows.compactMap { $0 as? TaskbarPanel }.first { $0.isVisible && $0.frame.minX == screen.frame.minX }
}

/// A mouse event at a point in window coordinates.
@MainActor func mouse(_ type: NSEvent.EventType, window p: NSPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

extension Desktop {
    @MainActor @Suite struct BarTests {
        @Test func composesSignalsClicksMenusAndDrags() async throws {
            let h = Harness()
            h.screens = [h.main, h.side]
            Env.defaults.set(["com.apple.TextEdit", "com.apple.calculator", "com.apple.Chess", "com.apple.TextEdit", "test.not.installed"],
                             forKey: "pinnedBundleIDs")
            let textEdit = h.app(91001, "com.apple.TextEdit", "TextEdit")
            let calculator = h.app(91002, "com.apple.calculator", "Calculator")
            let beta = h.app(91003, "test.beta", "Beta")
            let anon = h.app(91004, nil, "Anon")
            let doc = h.window(5001, of: textEdit, "Doc")
            h.window(5002, of: textEdit)
            func onSide(_ i: Int) -> CGRect { CGRect(x: -18790 + CGFloat(i), y: -19900, width: 300, height: 300) }
            let sum = h.window(5003, of: calculator, "Sum", frame: onSide(0))
            h.window(5004, of: beta, "Beta document with a long title")
            h.window(5005, of: anon, "A")
            for i in 0..<8 { h.window(CGWindowID(5010 + i), of: beta, "Side \(i)", frame: onSide(i)) }
            h.ws.front = textEdit
            h.ax.attrs[h.element(textEdit)]![kAXFocusedWindowAttribute] = doc
            let close = h.ax.element(of: textEdit.pid)
            h.ax.attrs[doc]![kAXCloseButtonAttribute] = close
            // Dock badge for TextEdit, and a TextEdit download.
            let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first!.processIdentifier
            let list = h.ax.element(of: dockPid), item = h.ax.element(of: dockPid)
            h.ax.attrs[AXUIElementCreateApplication(dockPid)] = [kAXChildrenAttribute: [list] as CFArray]
            h.ax.attrs[list] = [kAXChildrenAttribute: [item] as CFArray]
            h.ax.attrs[item] = [kAXSubroleAttribute: "AXApplicationDockItem" as CFString, "AXStatusLabel": "5" as CFString,
                                kAXURLAttribute: URL(fileURLWithPath: "/System/Applications/TextEdit.app") as CFURL]

            let t = WindowTracker(), s = Signals(), p = PreviewController(tracker: t)
            t.start()
            s.start()
            await settle(0.3)
            let file = h.dir.appendingPathComponent("doc.zip")
            FileManager.default.createFile(atPath: file.path, contents: Data())
            setxattr(file.path, "com.apple.quarantine", "0083;66fe1234;TextEdit;UUID", 28, 0, 0)
            let download = Progress(totalUnitCount: 10)
            download.kind = .file
            download.fileOperationKind = .downloading
            download.setUserInfoObject(file, forKey: .fileURLKey)
            download.publish()
            defer { download.unpublish() }
            s.attentionEvent(NSNumber(value: beta.pid), true)
            await settle(0.3)

            let bar = BarController(tracker: t, signals: s, preview: p)
            t.onChange = { bar.render() }
            s.onChange = { bar.render() }
            #expect(bar.pins == ["com.apple.TextEdit", "com.apple.calculator", "com.apple.Chess"])
            let main = try #require(panel(on: h.main)), side = try #require(panel(on: h.side))

            // Untrusted: pinned launchers and the call to action, whose button opens System Settings.
            #expect(main.taskbarButtons.map(\.key) == [.app("com.apple.TextEdit"), .app("com.apple.calculator"), .app("com.apple.Chess")])
            let cta = try #require(main.contentView!.subviews.compactMap { $0 as? CTAButton }.first)
            #expect(!cta.isHidden)
            #expect(cta.acceptsFirstMouse(for: nil))
            cta.sendAction(cta.action, to: cta.target)
            #expect(h.ws.opened.last?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
            bar.access = .incompatible
            #expect(cta.isHidden)

            bar.access = .trusted
            bar.access = .trusted
            #expect(main.taskbarButtons.map(\.key) == [.window(5001), .window(5002), .app("com.apple.calculator"),
                                                       .app("com.apple.Chess"), .window(5004), .window(5005)])
            #expect(side.button(.overflow) != nil)
            #expect(side.button(.window(5003)) != nil)
            let first = main.button(.window(5001))!.accessibilityLabel() ?? ""
            #expect(first.hasPrefix("Doc, TextEdit, active, 5 notifications, downloading, 0 percent"))
            #expect(main.button(.window(5002))!.content.label == "TextEdit")
            #expect(main.button(.window(5002))!.accessibilityLabel()?.contains("5 notifications") == false) // first button only
            #expect(side.taskbarButtons.contains { $0.accessibilityLabel()?.hasSuffix("needs attention") == true }
                    || main.button(.window(5004))!.accessibilityLabel()?.hasSuffix("needs attention") == true)

            // Clicks: the active window minimizes, others focus; an app item focuses its window elsewhere; a launcher opens.
            bar.clicked(main.button(.window(5001))!)
            #expect(h.ax.sets.contains { $0.element == doc && $0.attribute == kAXMinimizedAttribute })
            bar.clicked(main.button(.window(5004))!)
            bar.clicked(main.button(.app("com.apple.calculator"))!)
            #expect(h.ax.performed.contains { $0.element == sum && $0.action == kAXRaiseAction })
            bar.clicked(main.button(.app("com.apple.Chess"))!)
            #expect(h.ws.opened.last?.lastPathComponent == "Chess.app")

            // Drag in the pinned group (animated), and in the other group (Reduce Motion). Narrower items are dragged onto
            // wider ones: a dragged button only swaps with the group's last item if that item is wider than itself.
            func drag(_ b: TaskbarButton, by dx: CGFloat) {
                let w = b.window!, o = b.convert(NSPoint(x: 20, y: 20), to: nil)
                b.mouseDown(with: mouse(.leftMouseDown, window: o, in: w))
                b.mouseDragged(with: mouse(.leftMouseDragged, window: NSPoint(x: o.x + 2, y: o.y), in: w)) // under the threshold
                b.mouseDragged(with: mouse(.leftMouseDragged, window: NSPoint(x: o.x + dx, y: o.y), in: w))
                #expect(main.isDragging)
                bar.render() // deferred to the drop
                b.mouseUp(with: mouse(.leftMouseUp, window: NSPoint(x: o.x + dx, y: o.y), in: w))
            }
            drag(main.button(.app("com.apple.Chess"))!, by: -400)
            #expect(main.taskbarButtons.map(\.key).prefix(4) == [.app("com.apple.Chess"), .window(5001), .window(5002), .app("com.apple.calculator")])
            #expect(bar.pins == ["com.apple.Chess", "com.apple.TextEdit", "com.apple.calculator"])
            h.ws.reduceMotion = true
            bar.themeChanged()
            drag(main.button(.window(5005))!, by: -300)
            #expect(t.windows[5005]!.order < t.windows[5004]!.order)
            h.ws.reduceMotion = false
            bar.reorder(.pinned, [.window(5002), .app("com.apple.Chess"), .overflow, .window(9999)])
            #expect(bar.pins == ["com.apple.TextEdit", "com.apple.Chess", "com.apple.calculator"])

            // Click without a drag; release outside; VoiceOver press; middle button; hover.
            let b4 = main.button(.window(5004))!
            let mid = b4.convert(NSPoint(x: 20, y: 20), to: nil)
            b4.mouseDown(with: mouse(.leftMouseDown, window: mid, in: main))
            b4.mouseUp(with: mouse(.leftMouseUp, window: mid, in: main))
            b4.mouseDown(with: mouse(.leftMouseDown, window: mid, in: main))
            b4.mouseUp(with: mouse(.leftMouseUp, window: NSPoint(x: mid.x, y: mid.y + 500), in: main))
            #expect(b4.accessibilityPerformPress())
            b4.otherMouseDown(with: mouse(.otherMouseDown, window: mid, in: main))
            b4.otherMouseUp(with: mouse(.otherMouseUp, window: mid, in: main))
            #expect(b4.acceptsFirstMouse(for: nil))
            b4.updateTrackingAreas()
            b4.updateTrackingAreas()
            b4.viewDidChangeBackingProperties()
            b4.mouseEntered(with: mouse(.mouseMoved, window: mid, in: main))
            b4.mouseExited(with: mouse(.mouseMoved, window: mid, in: main))
            side.button(.overflow)!.mouseDragged(with: mouse(.leftMouseDragged, window: mid, in: side)) // not draggable
            bar.barMouseDown()

            // Context menus (picked as BarClickTap would; disabled items keep the menu open).
            func menu(_ b: TaskbarButton, choose title: String?) -> [String] {
                let count = h.menus.count
                h.onMenu = { m in if let title { Harness.choose(title, in: m) } }
                b.rightMouseDown(with: mouse(.rightMouseDown, window: b.convert(NSPoint(x: 10, y: 10), to: nil), in: b.window!))
                return h.menus.count > count ? h.menus.last!.items.map(\.title) : []
            }
            #expect(menu(main.button(.window(5001))!, choose: "New Window")
                    == ["New Window", "", "Unpin from Taskbar", "", "Close Window", "Quit TextEdit"])
            _ = menu(main.button(.window(5001))!, choose: "Close Window")
            #expect(h.ax.performed.contains { $0.element == close && $0.action == kAXPressAction })
            _ = menu(main.button(.window(5004))!, choose: "Pin to Taskbar")
            #expect(bar.pins.last == "test.beta")
            _ = menu(main.button(.window(5004))!, choose: "Unpin from Taskbar")
            _ = menu(main.button(.window(5004))!, choose: "Quit Beta")
            #expect(beta.terminates == 1)
            #expect(menu(main.button(.window(5005))!, choose: nil) == ["New Window", "", "Pin to Taskbar", "", "Close Window", "Quit Anon"])
            #expect(menu(main.button(.app("com.apple.calculator"))!, choose: "Quit Calculator")
                    == ["New Window", "", "Unpin from Taskbar", "", "Quit Calculator"])
            #expect(calculator.terminates == 1)
            #expect(menu(main.button(.app("com.apple.Chess"))!, choose: "Open Chess") == ["Open Chess", "", "Unpin from Taskbar"])
            #expect(h.ws.opened.last?.lastPathComponent == "Chess.app")
            _ = menu(main.button(.app("com.apple.Chess"))!, choose: "Unpin from Taskbar")
            #expect(!bar.pins.contains("com.apple.Chess"))
            _ = menu(main.button(.app("com.apple.calculator"))!, choose: "Unpin from Taskbar")
            #expect(menu(side.button(.overflow)!, choose: nil).isEmpty)

            // The overflow menu lists the hidden items; choosing one activates it.
            h.onMenu = { m in Harness.choose(m.items[0].title, in: m) }
            bar.clicked(side.button(.overflow)!)
            #expect(h.menus.last!.items.count >= 1)
            #expect(h.menus.last!.items[0].image?.size == NSSize(width: 16, height: 16))

            // An app item with no window focuses nothing: it reopens the app.
            bar.reorder(.pinned, [.app("com.apple.calculator")])
            h.ax.post(kAXUIElementDestroyedNotification, sum)
            await settle()
            bar.clicked(main.button(.app("com.apple.calculator"))!)
            #expect(h.ws.opened.last?.lastPathComponent == "Calculator.app")
            // A pinned app that is no longer installed is unpinned when opened.
            bar.reorder(.pinned, [.app("test.gone")])
            #expect(main.button(.app("test.gone"))!.content.label == "test.gone")
            bar.clicked(main.button(.app("test.gone"))!)
            #expect(!bar.pins.contains("test.gone"))

            // Bar menu on empty space.
            h.permission = false
            #expect(main.background.acceptsFirstMouse(for: nil))
            func barMenu(_ title: String) {
                h.onMenu = { Harness.choose(title, in: $0) }
                main.background.rightMouseDown(with: mouse(.rightMouseDown, window: NSPoint(x: 1100, y: 10), in: main))
            }
            barMenu("Enable Window Previews…")
            #expect(h.ws.opened.last?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
            #expect(h.menus.last!.items.map(\.title).contains("Launch at Login"))
            barMenu("Check for Updates…")
            #expect(h.notices == ["Updates unavailable"])
            let updates = Updater.isEnabled
            barMenu("Automatic Updates")
            #expect(Updater.isEnabled != updates)
            barMenu("Automatic Updates")
            #expect(Updater.isEnabled == updates)

            // Theme: contrast and solid backgrounds re-render; an unchanged theme does nothing.
            h.ws.contrast = true
            h.ws.solid = true
            bar.themeChanged()
            bar.themeChanged()
            main.background.display()
            h.ws.solid = false
            bar.themeChanged()
            main.background.display()

            // Hover drives the preview.
            bar.hover(main.button(.window(5004))!, true)
            bar.hover(main.taskbarButtons.first { if case .app = $0.key { true } else { false } }!, true) // not a window
            bar.hover(main.button(.window(5004))!, false)

            // Full-screen Space: bars hide; display changes reframe or remove them.
            h.spaces = [["Current Space": ["type": 4], "Display Identifier": "Main"]]
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            await settle()
            #expect(!main.isVisible)
            h.spaces = []
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            await settle()
            #expect(main.isVisible)
            h.screens = [h.main]
            h.main.rect.size.width = 1100
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            await settle()
            #expect(!side.isVisible)
            #expect(main.frame.width == 1100)
            h.main.rect.size.width = 1200

            t.stop()
            s.stop()
        }

        @Test func buttonSignalsAndLift() {
            _ = fontsRegistered
            let b = TaskbarButton()
            var c = TaskbarButton.Content(item: BarItem(kind: .window(1, 1), group: .other), icon: NSImage(), label: "Doc",
                                          width: 160, iconOnly: false, voiceOver: "Doc")
            b.update(c, theme: Theme())
            c.progress = ProgressState(fraction: nil, paused: false) // indeterminate sweep
            b.update(c, theme: Theme())
            b.update(c, theme: Theme())
            c.progress = ProgressState(fraction: nil, paused: true)
            b.update(c, theme: Theme())
            c.progress = nil
            b.update(c, theme: Theme())
            c.attention = .pulsing(since: CFAbsoluteTimeGetCurrent())
            b.update(c, theme: Theme())
            b.update(c, theme: Theme())
            c.attention = .holding
            c.active = true
            b.update(c, theme: Theme())
            var rm = Theme()
            rm.reduceMotion = true
            c.attention = .pulsing(since: 1)
            c.progress = ProgressState(fraction: nil, paused: false)
            b.update(c, theme: rm)
            b.setLifted(true)
            b.setLifted(false)
            b.setFrameSize(NSSize(width: 162, height: 48))
            b.viewDidChangeBackingProperties()
            #expect(b.accessibilityLabel() == "Doc")
            let dots = TaskbarButton.dots(color: Theme().text)
            #expect(dots.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        }
    }
}
