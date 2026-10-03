import Foundation

/// LaunchServices private notifications, used for app attention only (Design decision 7). The three
/// functions are resolved with dlsym; if any is missing, attention is disabled and nothing else is affected.
/// Signatures verified 2026-10-03 (Apple's SecTranslocateLSNotification.cpp + probe).
enum LaunchServicesSPI {
    private typealias Handler = @convention(block) (UInt32, CFAbsoluteTime, CFTypeRef?, CFTypeRef?, Int32, UInt64) -> Void
    private typealias Schedule = @convention(c) (Int32, CFTypeRef?, DispatchQueue, @escaping Handler) -> UInt64 // LS keeps the block
    private typealias Modify = @convention(c) (UInt64, UInt32, UnsafePointer<UInt32>?, UInt32, UnsafePointer<UInt32>?,
                                               CFTypeRef?, CFTypeRef?) -> OSStatus
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    private static let session: Int32 = -2 // default session
    private static let attentionCode: UInt32 = 563 // 0x233: data["LSWantsAttention"] is a CFBoolean
    private static let lib = dlopen("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices", RTLD_NOW)

    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let lib, let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let schedule = sym("_LSScheduleNotificationOnQueueWithBlock", Schedule.self)
    private static let modify = sym("_LSModifyNotification", Modify.self)
    private static let copyItem = sym("_LSCopyApplicationInformationItem", CopyItem.self)

    /// Subscribes to code 563 in the default session on the main queue: handler(ASN, wants attention).
    /// Returns false (and logs "LaunchServices SPI unavailable") if the SPI cannot be used.
    static func subscribeAttention(_ handler: @escaping (CFTypeRef, Bool) -> Void) -> Bool {
        guard let schedule, let modify, copyItem != nil else {
            EventLog.write("LaunchServices SPI unavailable")
            return false
        }
        let id = schedule(session, nil, .main) { code, _, data, asn, _, _ in
            guard code == attentionCode, let asn, let wants = (data as? [String: Any])?["LSWantsAttention"] as? Bool else { return }
            handler(asn, wants)
        }
        var code = attentionCode
        let status = modify(id, 1, &code, 0, nil, nil, nil)
        guard status == 0 else {
            EventLog.write("LaunchServices SPI unavailable (modify status \(status))")
            return false
        }
        EventLog.write("LaunchServices attention subscribed")
        return true
    }

    /// The app's pid. NULL once the app has quit, so callers record ASN → pid on the "true" event.
    static func pid(of asn: CFTypeRef) -> pid_t? {
        (copyItem?(session, asn, "pid" as CFString)?.takeRetainedValue() as? NSNumber)?.int32Value
    }
}
