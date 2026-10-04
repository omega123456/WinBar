import AppKit
import Testing
@testable import WinBar

extension Desktop {
    @MainActor @Suite struct PreviewTests {
        @Test func hoverTimingCaptureAndClose() async {
            let h = Harness()
            let a = h.app(91001, "test.alpha", "Alpha")
            h.window(5001, of: a, "One")
            h.window(5002, of: a)
            h.window(5003, of: a, "Min", minimized: true)
            for i in 0..<34 { h.window(CGWindowID(6000 + i), of: a, "W\(i)") }
            let t = WindowTracker()
            t.start()
            await settle()
            let p = PreviewController(tracker: t)
            let panel = p.panel
            let plate = CGRect(x: -19900, y: -19995, width: 160, height: 40)
            func shown(_ s: String) -> Bool { h.log.contains("preview shown id=\(s)") }

            // Cold: captured at hover-enter, shown after the delay, off the real desktop.
            p.hoverEnter(5001, plate: plate, screen: nil)
            await settle(0.2)
            #expect(h.captures == [5001])
            #expect(!panel.isVisible)
            await settle(0.4)
            #expect(panel.isVisible)
            #expect(panel.frame.maxX < -10000)
            #expect(shown("5001 fresh"))
            p.hoverEnter(5001, plate: plate, screen: h.main) // already shown

            // Warm switch: at once; the thumbnail follows.
            p.hoverEnter(5002, plate: plate, screen: h.main)
            #expect(shown("5002 icon"))
            await settle()
            #expect(h.log.contains("preview thumbnail displayed id=5002"))

            // Hovering the preview keeps it; leaving fades it out.
            p.hoverExit()
            p.panel.view.mouseEntered(with: mouse(.mouseMoved, at: .zero, in: p.panel.view))
            await settle(0.4)
            #expect(panel.isVisible)
            p.panel.view.mouseExited(with: mouse(.mouseMoved, at: .zero, in: p.panel.view))
            await settle(0.45) // hidden after 0.3 s, faded out 83 ms later
            #expect(!panel.isVisible)

            // Re-hover within 0.3 s of hiding: at once, from the cache. A re-hover mid-fade keeps it on screen.
            p.hoverEnter(5001, plate: plate, screen: h.main)
            #expect(shown("5001 cached"))
            p.hoverExit()
            await settle(0.33)
            p.hoverEnter(5002, plate: plate, screen: h.main)
            await settle(0.2)
            #expect(panel.isVisible)

            // The close button hides the preview and closes the window.
            let view = p.panel.view
            let close = view.hitTest(NSPoint(x: view.frame.maxX - 20, y: view.frame.maxY - 20))!
            #expect(close !== view)
            #expect(view.hitTest(NSPoint(x: -50, y: -50)) == nil)
            #expect(view.hitTest(NSPoint(x: view.frame.midX, y: view.frame.minY + 20)) === view)
            close.updateTrackingAreas()
            close.updateTrackingAreas()
            close.mouseEntered(with: mouse(.mouseMoved, at: .zero, in: close))
            close.mouseExited(with: mouse(.mouseMoved, at: .zero, in: close))
            close.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 5, y: 5), in: close))
            #expect(close.acceptsFirstMouse(for: nil))
            close.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: -50, y: 5), in: close)) // released outside
            #expect(panel.isVisible)
            close.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 5, y: 5), in: close))
            #expect(!panel.isVisible)
            #expect(h.log.contains("action close 5002"))
            #expect(close.accessibilityPerformPress()) // nothing shown: nothing to close
            view.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: view))
            view.mouseUp(with: mouse(.leftMouseUp, at: .zero, in: view)) // nothing shown: nothing to focus

            // A body click hides the preview and focuses the window; a release outside does nothing.
            p.hoverEnter(5001, plate: plate, screen: h.main)
            #expect(panel.isVisible)
            view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: -50, y: 5), in: view))
            #expect(panel.isVisible)
            view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 5, y: 5), in: view))
            #expect(!panel.isVisible)
            #expect(h.log.contains("action focus 5001"))
            view.rightMouseDown(with: mouse(.rightMouseDown, at: .zero, in: view))
            #expect(view.acceptsFirstMouse(for: nil))
            view.updateTrackingAreas()
            view.updateTrackingAreas()

            // A removed window takes its preview with it.
            p.hoverEnter(5001, plate: plate, screen: h.main)
            #expect(panel.isVisible)
            p.windowRemoved(5001)
            #expect(!panel.isVisible)
            p.windowRemoved(5001)

            // Failed capture; minimized windows aren't captured; no permission → "unavailable".
            h.image = nil
            p.hoverEnter(5002, plate: plate, screen: h.main)
            await settle()
            #expect(h.log.contains("preview capture failed id=5002"))
            p.hoverEnter(5003, plate: plate, screen: h.main)
            #expect(!h.captures.contains(5003))
            h.permission = false
            p.hoverEnter(6000, plate: plate, screen: h.main)
            #expect(shown("6000 unavailable"))
            p.hideNow()
            p.hideNow()

            // Reduce Motion: fade only, cold and warm.
            h.permission = true
            h.image = Harness.makeImage()
            h.ws.reduceMotion = true
            await settle(0.35)
            p.hoverEnter(6001, plate: plate, screen: h.main)
            await settle(0.5)
            #expect(panel.isVisible)
            p.hoverEnter(6002, plate: plate, screen: h.main)
            p.hideNow()

            // A window that is gone by the time the delay ends shows nothing.
            await settle(0.35)
            p.hoverEnter(9999, plate: plate, screen: h.main)
            await settle(0.5)
            #expect(!panel.isVisible)

            // The thumbnail cache keeps the 32 most recent.
            for i in 0..<34 { p.hoverEnter(CGWindowID(6000 + i), plate: plate, screen: h.main) }
            await settle()
            p.hideNow()
            t.stop()
        }
    }
}
