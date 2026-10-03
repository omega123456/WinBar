import CoreGraphics

/// `--self-test`: checks of pure logic with explicit failure counting (not `assert`,
/// which is compiled out of release builds). Returns false if any check failed.
enum SelfTest {
    private static var total = 0
    private static var failures: [String] = []

    private static func check(_ name: String, _ ok: Bool) {
        total += 1
        if !ok { failures.append(name) }
    }

    static func run() -> Bool {
        coordinateConversion()
        displayAssignment()
        visibilityRule()
        barClamp()
        composition()
        fitting()
        pinOrder()
        menuAnchor()
        badgeMapping()
        downloads()
        attention()
        updateVersions()
        for f in failures { print("FAIL: \(f)") }
        print("self-test: \(total - failures.count)/\(total) checks passed")
        return failures.isEmpty
    }

    // Cocoa frames: primary A 1920×1080 at the origin, B to its right, C (1440p) above A.
    private static let a = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private static let b = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    private static let c = CGRect(x: 0, y: 1080, width: 2560, height: 1440)

    private static func coordinateConversion() {
        let convert = { WindowTracker.cocoaRect(fromAX: $0, primaryHeight: 1080) }
        check("AX rect on primary flips y",
              convert(CGRect(x: 100, y: 100, width: 800, height: 600)) == CGRect(x: 100, y: 380, width: 800, height: 600))
        check("AX rect filling primary maps to primary",
              convert(CGRect(x: 0, y: 0, width: 1920, height: 1080)) == a)
        check("AX rect above primary (negative y) maps onto C",
              convert(CGRect(x: 0, y: -1440, width: 2560, height: 1440)) == c)
        check("converted window above primary is assigned to C",
              WindowTracker.displayIndex(for: convert(CGRect(x: 200, y: -1000, width: 600, height: 400)), in: [a, b, c]) == 2)
    }

    private static func barClamp() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055) // menu bar 25, Dock on the side
        let clamp = { WindowTracker.clampedAboveBar($0, screen: a, visible: visible, barHeight: 48) }
        check("maximized window ends at the bar top", clamp(visible) == CGRect(x: 0, y: 48, width: 1920, height: 1007))
        check("left-half tile ends at the bar top",
              clamp(CGRect(x: 0, y: 0, width: 960, height: 1055)) == CGRect(x: 0, y: 48, width: 960, height: 1007))
        check("window above the bar untouched", clamp(CGRect(x: 100, y: 200, width: 800, height: 600)) == nil)
        check("window dragged partly under the bar untouched", clamp(CGRect(x: 100, y: 10, width: 800, height: 600)) == nil)
        check("whole-screen window untouched", clamp(a) == nil)
        check("window too short to shrink untouched", clamp(CGRect(x: 0, y: 0, width: 300, height: 80)) == nil)
        check("visible frame already above the bar → untouched",
              WindowTracker.clampedAboveBar(CGRect(x: 0, y: 74, width: 1920, height: 981), screen: a,
                                            visible: CGRect(x: 0, y: 74, width: 1920, height: 981), barHeight: 48) == nil)
    }

    private static func displayAssignment() {
        let idx = { WindowTracker.displayIndex(for: $0, in: $1) }
        check("window inside A → A", idx(CGRect(x: 100, y: 100, width: 500, height: 400), [a, b, c]) == 0)
        check("window inside B → B", idx(CGRect(x: 2000, y: 100, width: 500, height: 400), [a, b, c]) == 1)
        check("straddling A/B, mostly B → B", idx(CGRect(x: 1800, y: 100, width: 800, height: 400), [a, b, c]) == 1)
        check("straddling A/B, mostly A → A", idx(CGRect(x: 1400, y: 100, width: 800, height: 400), [a, b, c]) == 0)
        check("exact tie → first listed (A)", idx(CGRect(x: 1520, y: 100, width: 800, height: 400), [a, b, c]) == 0)
        check("exact tie → first listed (B when listed first)", idx(CGRect(x: 1520, y: 100, width: 800, height: 400), [b, a, c]) == 0)
        check("no overlap → main (index 0)", idx(CGRect(x: -5000, y: -5000, width: 300, height: 300), [a, b, c]) == 0)
        check("zero-size frame → main", idx(.zero, [b, a]) == 0)
        check("partly off-screen counts the visible part", idx(CGRect(x: -400, y: 1200, width: 600, height: 300), [a, b, c]) == 2)
        check("touching edge only → main", idx(CGRect(x: 3840, y: 0, width: 100, height: 100), [b, a]) == 0)
    }

    private static func visibilityRule() {
        let vis = WindowTracker.isVisible
        check("off-screen, normal, app shown → hidden", vis(false, false, false) == false)
        check("on screen → visible", vis(true, false, false))
        check("minimized (any Space) → visible", vis(false, true, false))
        check("app hidden (any Space) → visible", vis(false, false, true))
        check("minimized + app hidden → visible", vis(false, true, true))
        check("on screen + minimized → visible", vis(true, true, false))
    }

    // MARK: Bar composition (requirements 12, 13, 31)

    private static func composition() {
        let main: CGDirectDisplayID = 1, second: CGDirectDisplayID = 2
        // Session order: finder@main, safari#1@main, notes@main, safari#2(other pid)@main, terminal@second, mail-less, nil-bundle@main
        let ws = [
            BarWindow(id: 10, pid: 100, bundleID: "finder", displayID: main),
            BarWindow(id: 11, pid: 101, bundleID: "safari", displayID: main),
            BarWindow(id: 12, pid: 102, bundleID: "notes", displayID: main),
            BarWindow(id: 13, pid: 201, bundleID: "safari", displayID: main),
            BarWindow(id: 14, pid: 103, bundleID: "terminal", displayID: second),
            BarWindow(id: 15, pid: 104, bundleID: nil, displayID: main),
        ]
        let running: Set<String> = ["finder", "safari", "notes", "terminal", "mail"]
        let pins = ["safari", "mail", "terminal", "music", "finder"]
        let m = BarController.compose(pins: pins, windows: ws, running: running, display: main, isMain: true, trusted: true)
        let expected: [BarItem] = [
            .init(kind: .window(11, 101), group: .pinned),   // both Safari instances, session order
            .init(kind: .window(13, 201), group: .pinned),
            .init(kind: .appItem("mail"), group: .pinned),   // running, windowless
            .init(kind: .appItem("terminal"), group: .pinned), // only window on another display
            .init(kind: .launcher("music"), group: .pinned), // not running
            .init(kind: .window(10, 100), group: .pinned),
            .init(kind: .window(12, 102), group: .other),
            .init(kind: .window(15, 104), group: .other),    // no bundle ID → never pinned
        ]
        check("main bar: pinned slots resolved in pin order, then other windows", m == expected)
        let s = BarController.compose(pins: pins, windows: ws, running: running, display: second, isMain: false, trusted: true)
        check("secondary bar: only its windows, no pinned group", s == [.init(kind: .window(14, 103), group: .other)])
        let u = BarController.compose(pins: pins, windows: ws, running: running, display: main, isMain: true, trusted: false)
        check("untrusted main bar: launchers only", u == pins.map { .init(kind: .launcher($0), group: .pinned) })
        let us = BarController.compose(pins: pins, windows: ws, running: running, display: second, isMain: false, trusted: false)
        check("untrusted secondary bar: empty", us.isEmpty)
        let nopin = BarController.compose(pins: [], windows: ws, running: running, display: main, isMain: true, trusted: true)
        check("no pins: all main windows in session order", nopin.map(\.key) == [10, 11, 12, 13, 15].map { ItemKey.window($0) })
        check("pinned app on secondary display stays in the other group there",
              BarController.compose(pins: ["terminal"], windows: ws, running: running, display: second, isMain: false, trusted: true)
                == [.init(kind: .window(14, 103), group: .other)])
    }

    // MARK: Width fitting and overflow (requirement 21)

    private static func fitting() {
        let fit = BarController.fit
        let g = TaskbarPanel.gap, gg = TaskbarPanel.groupGap
        // natural: the edges are outside `available`; `g` between items, `gg` between groups.
        let n = fit([nil, 120], [150, 80], 44 + g + 120 + gg + 150 + g + 80)
        check("natural widths when they fit", n == Fit(pinned: [44, 120], other: [150, 80], iconOnly: false, overflow: false))
        check("1 pt short of natural → even shrink, share floor(349 / 3)", fit([nil, 120], [150, 80], 44 + g + 120 + gg + 150 + g + 80 - 1)
              == Fit(pinned: [44, 116], other: [116, 80], iconOnly: false, overflow: false))
        // shrink: fixed = 44 + g + gg + 2g (+ 0 for windows); 4 windows share 125 each
        let s = fit([nil, 160], [160, 100, 160], 44 + 3 * g + gg + 4 * 125)
        check("even shrink: min(natural, share)", s == Fit(pinned: [44, 125], other: [125, 100, 125], iconOnly: false, overflow: false))
        let edge = fit([], [160, 160], 96 * 2 + g)
        check("share of exactly 96 still shrinks", edge == Fit(pinned: [], other: [96, 96], iconOnly: false, overflow: false))
        // share below 96 → icon-only 44 for every window (pinned and other)
        let i = fit([nil, 160], [160, 160, 160], 5 * 44 + 3 * g + gg)
        check("icon-only when the share drops below 96", i == Fit(pinned: [44, 44], other: [44, 44, 44], iconOnly: true, overflow: false))
        // overflow: 10 other windows, room for pinned(2) + gg + 5 items (incl. "…") with 4 gaps
        let o = fit([nil, nil], Array(repeating: 160, count: 10), 2 * 44 + g + gg + 5 * 44 + 4 * g)
        check("overflow: trailing other windows go into \"…\"", o == Fit(pinned: [44, 44], other: [44, 44, 44, 44], iconOnly: true, overflow: true))
        // pinned group alone too wide: every other window hidden, then trailing pinned
        let p = fit([nil, 160, nil, nil], [160, 160], 3 * 44 + 2 * g + gg + 44)
        check("pinned-group overflow: other first, then trailing pinned", p == Fit(pinned: [44, 44, 44], other: [], iconOnly: true, overflow: true))
        check("no items: nothing to fit", fit([], [], 100) == Fit(pinned: [], other: [], iconOnly: false, overflow: false))
    }

    private static func menuAnchor() {
        let loc = BarController.menuLocation
        check("menu: bottom-left at the anchor when the screen has no bottom Dock",
              loc(500, 30, 128, 0) == CGPoint(x: 500, y: 30 - 5 + 128))
        check("menu: raised above a bottom Dock's reserved area instead of being clipped",
              loc(500, 50, 128, 74) == CGPoint(x: 500, y: 82 - 5 + 128))
    }

    private static func pinOrder() {
        check("pin order from first appearance after a drop",
              BarController.pinOrder(dropped: ["b", "a", "b", "c"], pins: ["a", "b", "c", "d"]) == ["b", "a", "c", "d"])
    }

    // MARK: Signals (requirements 27–29)

    private static func badgeMapping() {
        let cases: [(String?, Badge?)] = [
            (nil, nil), ("", nil), ("  ", nil), ("0", nil),                         // rule 1
            ("3", .count("3")), ("007", .count("7")), ("99", .count("99")),       // rule 2
            ("120", .count("99+")), ("99999999999999999999999", .count("99+")),
            ("!", .alert),                                                       // rule 3
            ("ab", .text("ab")), (" a1 ", .text("a1")), ("新", .text("新")),         // rule 4
            ("•", .dot), ("abcd", .dot), ("!!", .dot), ("1234a", .dot),         // rule 5
        ]
        for (raw, expected) in cases { check("badge \(raw.map { "\"\($0)\"" } ?? "nil") → \(String(describing: expected))", Badge(dockLabel: raw) == expected) }
    }

    private static func downloads() {
        let q = Signals.quarantineAgent
        check("quarantine agent is the third field", q("0083;66fe1234;Vivaldi;3F2A-UUID") == "Vivaldi")
        check("quarantine agent with spaces", q("0081;66fe1234;Google Chrome;") == "Google Chrome")
        check("quarantine empty agent → nil", q("0083;66fe1234;;UUID") == nil)
        check("quarantine too few fields → nil", q("0083;66fe1234") == nil && q("") == nil)

        let agg = Signals.aggregate
        typealias T = Signals.Transfer
        check("aggregate: none → nil", agg([]) == nil)
        check("aggregate: completed / total summed", agg([T(completed: 50, total: 100, paused: false), T(completed: 25, total: 300, paused: false)])
              == ProgressState(fraction: 0.1875, paused: false))
        check("aggregate: paused only if all paused", agg([T(completed: 1, total: 2, paused: true), T(completed: 1, total: 2, paused: false)])?.paused == false
              && agg([T(completed: 1, total: 2, paused: true), T(completed: 1, total: 4, paused: true)])?.paused == true)
        check("aggregate: indeterminate if no known total", agg([T(completed: 5, total: 0, paused: false), T(completed: 9, total: -1, paused: false)])
              == ProgressState(fraction: nil, paused: false))
        check("aggregate: unknown totals ignored in the fraction", agg([T(completed: 3, total: 4, paused: false), T(completed: 9, total: -1, paused: false)])?.fraction == 0.75)

        let attr = Signals.attribute
        let agent = attr(nil, "com.vivaldi", "com.apple.Terminal")
        check("attribution: quarantine agent when readable at first sight", agent == Attribution(app: "com.vivaldi", fallback: false))
        let fb = attr(nil, nil, "com.apple.Safari")
        check("attribution: frontmost fallback otherwise", fb == Attribution(app: "com.apple.Safari", fallback: true))
        check("attribution: never follows later frontmost changes", attr(fb, nil, "com.apple.Notes") == fb && attr(agent, nil, "com.apple.Notes") == agent)
        check("attribution: fallback replaced by a later readable agent", attr(fb, "com.vivaldi", "com.apple.Notes") == Attribution(app: "com.vivaldi", fallback: false))
        check("attribution: an agent attribution is final", attr(agent, "org.other", nil) == agent)
    }

    private static func attention() {
        let a = { Signals.attention(start: 100, ended: $0, now: $1, reduceMotion: $2) }
        let p = Signals.pulse
        check("attention: pulsing until 7 pulses", a(nil, 103, false) == (.pulsing(since: 100), 100 + 7 * p))
        check("attention: held after 7 pulses", a(nil, 100 + 7 * p + 0.01, false) == (.holding, nil))
        check("attention: ended in pulse 2 finishes it, then no hold",
              a(100 + 1.5, 100 + 1.6, false) == (.pulsing(since: 100), 100 + 2 * p) && a(100 + 1.5, 100 + 2 * p + 0.01, false) == (.none, nil))
        check("attention: ended at once still shows one pulse", a(100, 100, false) == (.pulsing(since: 100), 100 + p))
        check("attention: ended while held → none", a(100 + 20, 100 + 20, false) == (.none, nil))
        check("attention: Reduce Motion = plate while requested, no pulses",
              a(nil, 100.5, true) == (.holding, nil) && a(100.5, 100.5, true) == (.none, nil))
    }

    private static func updateVersions() {
        check("update: 1.0.10 is newer than 1.0.9", Updater.isNewer("1.0.10", than: "1.0.9"))
        check("update: v-prefixed tag is newer", Updater.isNewer("v1.1.0", than: "1.0.0"))
        check("update: 1.0 equals 1.0.0", !Updater.isNewer("1.0", than: "1.0.0") && !Updater.isNewer("1.0.0", than: "1.0"))
        check("update: older is not newer", !Updater.isNewer("1.9.9", than: "2.0.0"))
    }
}
