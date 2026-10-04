import AppKit
import Testing
@testable import WinBar

extension Desktop {
    /// Synthesized CGEvents are handed to the tap's routing directly; none is ever posted.
    @MainActor @Suite struct ClickTapTests {
        /// The CG global location (top-left origin, as the tap sees it) of a point in a view, on the fake screens.
        func location(_ view: NSView, _ p: NSPoint) -> CGPoint {
            let s = view.window!.convertPoint(toScreen: view.convert(p, to: nil))
            return CGPoint(x: s.x, y: Env.screens()[0].frame.height - s.y)
        }

        func event(_ type: CGEventType, _ at: CGPoint) -> CGEvent {
            let button: CGMouseButton = switch type {
            case .rightMouseDown, .rightMouseUp: .right
            case .otherMouseDown, .otherMouseUp: .center
            default: .left
            }
            return CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: button)!
        }

        func route(_ type: CGEventType, _ at: CGPoint) -> Bool { BarClickTap.route(type, event(type, at)) }

        @Test func routesBarClicks() async throws {
            let h = Harness()
            let a = h.app(91001, "test.alpha", "Alpha")
            let one = h.window(5001, of: a, "One")
            let t = WindowTracker(), s = Signals(), p = PreviewController(tracker: t)
            t.start()
            await settle()
            let bar = BarController(tracker: t, signals: s, preview: p)
            bar.access = .trusted
            let main = try #require(panel(on: h.main))
            let b = try #require(main.button(.window(5001)))
            let onButton = location(b, NSPoint(x: 20, y: 24))

            // Left click: down, drag and up go to the button; the up clicks it.
            #expect(route(.leftMouseDown, onButton))
            #expect(route(.leftMouseDragged, onButton))
            #expect(route(.leftMouseUp, onButton))
            await settle()
            #expect(h.ax.performed.contains { $0.element == one && $0.action == kAXRaiseAction })
            #expect(!route(.leftMouseUp, onButton)) // a lone up passes through
            #expect(!route(.leftMouseDragged, onButton))

            // Right click opens the menu; its up is taken. Middle click is taken and does nothing.
            #expect(route(.rightMouseDown, onButton))
            await settle()
            #expect(h.menus.count == 1)
            #expect(route(.rightMouseUp, onButton))
            #expect(!route(.rightMouseUp, onButton))
            #expect(route(.otherMouseDown, onButton))
            #expect(route(.otherMouseUp, onButton))
            #expect(!route(.otherMouseUp, onButton))

            // Empty bar space: the bar menu. Off the bars: not taken. The call to action stays native.
            #expect(route(.rightMouseDown, location(main.background, NSPoint(x: 1000, y: 24))))
            #expect(route(.rightMouseUp, onButton))
            await settle()
            #expect(h.menus.count == 2)
            #expect(!route(.leftMouseDown, CGPoint(x: 5, y: 5)))
            bar.access = .untrusted
            let label = try #require(main.contentView!.subviews.first { $0 is NSTextField && !$0.isHidden })
            #expect(!route(.leftMouseDown, location(label, NSPoint(x: 2, y: 2))))
            bar.access = .trusted

            // The hover preview takes clicks too (its X would otherwise activate WinBar).
            p.hoverEnter(5001, plate: CGRect(x: -19900, y: -19995, width: 160, height: 40), screen: h.main)
            await settle(0.6)
            #expect(p.panel.isVisible)
            let onPreview = location(p.panel.view, NSPoint(x: 100, y: 40))
            #expect(route(.leftMouseDown, onPreview))
            #expect(route(.leftMouseUp, onPreview))
            await settle()
            p.hideNow()

            // While a WinBar menu tracks: a click on that menu's window picks its item; other clicks pass.
            let menuWindow = NSWindow(contentRect: NSRect(x: -19000, y: -19500, width: 100, height: 100),
                                      styleMask: .borderless, backing: .buffered, defer: false)
            menuWindow.isReleasedWhenClosed = false
            menuWindow.orderFrontRegardless()
            defer { menuWindow.orderOut(nil) }
            await settle()
            let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(menuWindow.windowNumber)) as? [[String: Any]]
            let bounds = try #require(CGRect(dictionaryRepresentation: info?.first?[kCGWindowBounds as String] as! CFDictionary))
            let onMenu = CGPoint(x: bounds.midX, y: bounds.midY)
            var picked = 0
            BarClickTap.isPaused = true
            BarClickTap.onMenuClick = { picked += 1 }
            #expect(route(.leftMouseDown, onMenu))
            #expect(route(.leftMouseUp, onMenu))
            #expect(route(.rightMouseDown, onMenu))
            #expect(route(.rightMouseUp, onMenu))
            #expect(picked == 2)
            #expect(!route(.otherMouseDown, onMenu))
            let barInCG = main.frame // a bar is WinBar's too, but not a menu
            let onBar = CGPoint(x: barInCG.midX, y: CGDisplayBounds(CGMainDisplayID()).height - barInCG.midY)
            #expect(!route(.leftMouseDown, onBar))
            #expect(!route(.leftMouseDown, CGPoint(x: -99999, y: -99999)))
            BarClickTap.isPaused = false
            BarClickTap.onMenuClick = nil

            // The tap callback: re-enables a disabled tap, swallows what it routes, passes the rest.
            let proxy = OpaquePointer(bitPattern: 1)!
            #expect(BarClickTap.callback(proxy, .tapDisabledByTimeout, event(.leftMouseDown, onButton), nil) != nil)
            #expect(BarClickTap.callback(proxy, .otherMouseDown, event(.otherMouseDown, onButton), nil) == nil)
            #expect(BarClickTap.callback(proxy, .otherMouseUp, event(.otherMouseUp, onButton), nil) == nil)
            #expect(BarClickTap.callback(proxy, .leftMouseDown, event(.leftMouseDown, CGPoint(x: 5, y: 5)), nil) != nil)
            await settle()

            // Without Accessibility the tap can't be created.
            BarClickTap.install()
            BarClickTap.install()
            #expect(h.log.contains("bar click tap unavailable"))
            t.stop()
        }
    }
}
