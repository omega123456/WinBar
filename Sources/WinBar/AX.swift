import ApplicationServices
import Foundation

/// Calls that must abort the current batch of reads for an app.
enum AXFailure: Error {
    case timeout       // kAXErrorCannotComplete: the 0.25 s messaging timeout hit (or the app is busy)
    case apiDisabled   // Accessibility trust was revoked
}

/// Minimal Accessibility vocabulary. No business logic.
/// Reads return nil for ordinary failures (missing attribute, no value) and throw only
/// `AXFailure`, so callers can abandon an unresponsive app with one `catch`.
enum AX {
    /// Called (synchronously) whenever any AX call reports "API disabled".
    static var onAPIDisabled: (() -> Void)?

    /// The Accessibility C calls everything below goes through. Tests replace it with a fake Accessibility world.
    struct Backend {
        var copy: (AXUIElement, String) -> (AXError, CFTypeRef?) = { el, attr in
            var value: CFTypeRef?
            return (AXUIElementCopyAttributeValue(el, attr as CFString, &value), value)
        }
        var copyMultiple: (AXUIElement, [String]) -> (AXError, CFArray?) = { el, attrs in
            var out: CFArray?
            return (AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out), out)
        }
        var set: (AXUIElement, String, CFTypeRef) -> AXError = { AXUIElementSetAttributeValue($0, $1 as CFString, $2) }
        var perform: (AXUIElement, String) -> AXError = { AXUIElementPerformAction($0, $1 as CFString) }
        var windowID: (AXUIElement) -> CGWindowID? = { el in
            var id: CGWindowID = 0
            guard let fn = getWindowFn, fn(el, &id) == .success, id != 0 else { return nil }
            return id
        }
        var pid: (AXUIElement) -> pid_t = { el in
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            return pid
        }
        var createObserver: (pid_t, AXObserverCallback) -> AXObserver? = { pid, callback in
            var observer: AXObserver?
            return AXObserverCreate(pid, callback, &observer) == .success ? observer : nil
        }
        var addNotification: (AXObserver, AXUIElement, String, UnsafeMutableRawPointer) -> AXError = {
            AXObserverAddNotification($0, $1, $2 as CFString, $3)
        }
        var isTrusted: (_ prompt: Bool) -> Bool = { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": $0] as CFDictionary) }
    }
    static var backend = Backend()

    static func isTrusted(_ prompt: Bool) -> Bool { backend.isTrusted(prompt) }
    static func pid(_ el: AXUIElement) -> pid_t { backend.pid(el) }

    @discardableResult
    static func check(_ err: AXError) throws -> Bool {
        switch err {
        case .success: return true
        case .cannotComplete: throw AXFailure.timeout
        case .apiDisabled:
            onAPIDisabled?()
            throw AXFailure.apiDisabled
        default: return false
        }
    }

    // MARK: Private window-ID mapping

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindowFn: GetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    static var isWindowIDAvailable = getWindowFn != nil

    static func windowID(_ el: AXUIElement) -> CGWindowID? { backend.windowID(el) }

    // MARK: Attribute reads

    static func raw(_ el: AXUIElement, _ attr: String) throws -> CFTypeRef? {
        let (err, value) = backend.copy(el, attr)
        return try check(err) ? value : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) throws -> String? { try raw(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) throws -> Bool? { try raw(el, attr) as? Bool }
    static func element(_ el: AXUIElement, _ attr: String) throws -> AXUIElement? { asElement(try raw(el, attr)) }
    static func elements(_ el: AXUIElement, _ attr: String) throws -> [AXUIElement] {
        (try raw(el, attr) as? [AnyObject])?.compactMap { asElement($0) } ?? []
    }

    /// Several attributes in one IPC round trip. nil if the whole call failed;
    /// individual attributes that failed come back as nil entries.
    static func values(_ el: AXUIElement, _ attrs: [String]) throws -> [CFTypeRef?]? {
        let (err, out) = backend.copyMultiple(el, attrs)
        guard try check(err), let array = out as? [AnyObject], array.count == attrs.count else { return nil }
        return array.map { v in
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(unsafeBitCast(v, to: AXValue.self)) == .axError { return nil }
            return v
        }
    }

    static func asElement(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    static func point(_ v: CFTypeRef?) -> CGPoint? {
        var p = CGPoint.zero
        return axValue(v).map { AXValueGetValue($0, .cgPoint, &p) } == true ? p : nil
    }

    static func size(_ v: CFTypeRef?) -> CGSize? {
        var s = CGSize.zero
        return axValue(v).map { AXValueGetValue($0, .cgSize, &s) } == true ? s : nil
    }

    private static func axValue(_ v: CFTypeRef?) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXValue.self)
    }

    /// True if the element no longer exists.
    static func isDestroyed(_ el: AXUIElement) throws -> Bool {
        let err = backend.copy(el, kAXRoleAttribute).0
        if err == .invalidUIElement { return true }
        try check(err)
        return false
    }

    // MARK: Writes and actions

    /// Writes and actions log every failure (ordinary ones would otherwise vanish as `false`).
    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: Bool) throws -> Bool {
        try checkLogged(backend.set(el, attr, (value ? kCFBooleanTrue : kCFBooleanFalse)!), "set \(attr)")
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: CGSize) throws -> Bool {
        var v = value
        return try checkLogged(backend.set(el, attr, AXValueCreate(.cgSize, &v)!), "set \(attr)")
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) throws -> Bool {
        try checkLogged(backend.perform(el, action), "perform \(action)")
    }

    private static func checkLogged(_ err: AXError, _ what: String) throws -> Bool {
        if err != .success { EventLog.write("ax \(what) failed: AXError \(err.rawValue)") }
        return try check(err)
    }

    // MARK: Observers

    /// Creates an observer for `pid` and attaches it to the main run loop (common modes).
    static func makeObserver(_ pid: pid_t, _ callback: AXObserverCallback) -> AXObserver? {
        guard let observer = backend.createObserver(pid, callback) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observer
    }

    static func removeObserver(_ observer: AXObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    @discardableResult
    static func observe(_ observer: AXObserver, _ el: AXUIElement, _ notification: String, _ refcon: UnsafeMutableRawPointer) throws -> Bool {
        let err = backend.addNotification(observer, el, notification, refcon)
        return err == .notificationAlreadyRegistered ? true : try check(err)
    }

    // MARK: ⌘N search (requirement 19)

    /// The app's menu item bound to ⌘N with Command as the only modifier. Searches the direct
    /// items of every top-level menu (no submenus); both attributes per item come from one call.
    static func newWindowMenuItem(_ app: AXUIElement) throws -> AXUIElement? {
        guard let bar = try element(app, kAXMenuBarAttribute) else { return nil }
        for top in try elements(bar, kAXChildrenAttribute) {
            for menu in try elements(top, kAXChildrenAttribute) {
                for item in try elements(menu, kAXChildrenAttribute) {
                    guard let v = try values(item, [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute]) else { continue }
                    // Modifiers 0 == kAXMenuItemModifierNone, i.e. Command only.
                    if (v[0] as? String)?.uppercased() == "N", (v[1] as? Int) == 0 { return item }
                }
            }
        }
        return nil
    }
}
