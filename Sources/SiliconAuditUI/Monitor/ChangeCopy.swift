import Foundation
import SiliconAuditCore

/// The words for a change, at two depths: a sentence anyone can read, then what it could mean,
/// then the technical transition. Copy discipline (SPEC §3): "reports", never "has" or "lost".
public enum ChangeCopy {
    /// "2 readings changed on Mac17,7" / "System updated on Mac17,7".
    public static func headline(_ diff: ReportDiff) -> String {
        let n = diff.changes.count
        if n == 0, diff.osChanged {
            return String(localized: "System updated to \(diff.osVersionAfter) (\(diff.osBuildAfter))", bundle: .module)
        }
        if diff.securityChanges.isEmpty {
            return n == 1 ? String(localized: "1 reading changed", bundle: .module) : String(localized: "\(n) readings changed", bundle: .module)
        }
        let s = diff.securityChanges.count
        return s == 1 ? String(localized: "1 security reading changed", bundle: .module) : String(localized: "\(s) security readings changed", bundle: .module)
    }

    /// The context line under the headline.
    public static func context(_ diff: ReportDiff) -> String {
        if diff.osChanged {
            return String(localized: "The system went from \(diff.osVersionBefore) (\(diff.osBuildBefore)) to \(diff.osVersionAfter) (\(diff.osBuildAfter)) between the two readings. Changes after an update usually come from the new kernel, but each one is still worth a look.", bundle: .module)
        }
        if !diff.securityChanges.isEmpty {
            return String(localized: "The system version did not change, so these changes did not come from an update.", bundle: .module)
        }
        return String(localized: "The system version did not change.", bundle: .module)
    }

    public static func notificationTitle(_ diff: ReportDiff) -> String {
        "Silicon Audit · \(diff.identity)"
    }

    public static func notificationBody(_ diff: ReportDiff) -> String {
        var line = headline(diff)
        if let first = diff.changes.first { line += ". " + plain(first) }
        return line
    }

    /// One plain sentence about one change.
    public static func plain(_ c: ReportDiff.FactChange) -> String {
        let name = c.name
        switch c.kind {
        case .appeared:
            return String(localized: "\(name) is now reported; it was not before.", bundle: .module)
        case .disappeared:
            return String(localized: "\(name) is no longer reported at all.", bundle: .module)
        case .valueChanged:
            return String(localized: "\(name) changed from \(c.beforeValue ?? "?") to \(c.afterValue ?? "?").", bundle: .module)
        case .stateChanged:
            switch (c.before, c.after) {
            case (.present, .notPresent): return String(localized: "\(name) was reported on and now reports off.", bundle: .module)
            case (.notPresent, .present): return String(localized: "\(name) was reported off and now reports on.", bundle: .module)
            case (_, .keyAbsent): return String(localized: "\(name) is no longer reported at all.", bundle: .module)
            case (.keyAbsent, .present): return String(localized: "\(name) is now reported on; the kernel did not have it before.", bundle: .module)
            case (.keyAbsent, _): return String(localized: "\(name) is now reported; the kernel did not have it before.", bundle: .module)
            case (_, .restricted): return String(localized: "The app is no longer allowed to read \(name).", bundle: .module)
            case (.restricted, _): return String(localized: "The app can read \(name) again.", bundle: .module)
            case (_, .error): return String(localized: "\(name) could not be read this time.", bundle: .module)
            default:
                return String(localized: "\(name) went from \(StateStyle.label(c.before ?? .unknown)) to \(StateStyle.label(c.after ?? .unknown)).", bundle: .module)
            }
        }
    }

    /// What it could mean, for the detail screen.
    public static func meaning(_ c: ReportDiff.FactChange, osChanged: Bool) -> String {
        let update = osChanged
            ? String(localized: "The system was updated between the two readings, which is the usual reason a kernel reports something differently.", bundle: .module)
            : String(localized: "The system was not updated between the two readings, so this did not come from an update.", bundle: .module)
        switch (c.kind, c.securityRelevant) {
        case (.stateChanged, true) where c.after == .notPresent || c.after == .keyAbsent:
            return String(localized: "A protection the kernel used to report is no longer reported. A kernel can mask a feature it has not enabled, so this says the kernel stopped reporting it, not that the silicon lost it. \(update) If nothing you know of explains it, treat it as worth investigating.", bundle: .module)
        case (.stateChanged, true) where c.after == .present:
            return String(localized: "A protection the kernel did not report before is reported now. \(update)", bundle: .module)
        case (.stateChanged, true) where c.after == .restricted:
            return String(localized: "The sandbox or kernel now refuses this read. \(update) The protection itself may be unchanged; the app just cannot see it.", bundle: .module)
        case (_, true):
            return String(localized: "A security-relevant reading changed. \(update)", bundle: .module)
        case (.valueChanged, false) where c.category == "debug":
            return String(localized: "The number of hardware debug registers the kernel reports changed. These counts come from the chip and do not normally change on the same device. \(update)", bundle: .module)
        case (.valueChanged, false) where c.category == "capability_bitmask":
            return String(localized: "The capability bitmask the kernel publishes changed. The kernel builds it from what it enables, so an update can change it. \(update)", bundle: .module)
        case (.valueChanged, false):
            return String(localized: "A descriptive value changed. Hardware description values usually change only with a system update. \(update)", bundle: .module)
        case (.appeared, false):
            return String(localized: "A key the kernel did not expose before is exposed now, usually after a system update. If the app's inventory does not know it yet, it is listed under new keys.", bundle: .module)
        case (.disappeared, false), (.stateChanged, false):
            return String(localized: "A descriptive reading is no longer available or changed state. \(update)", bundle: .module)
        }
    }

    /// The honest limits, for the monitoring screen.
    public static var limits: String {
        String(localized: "The monitor compares what this device's kernel reports today with what it reported before. It notices a protection that reports on and later off, a value that changes, a key that appears or vanishes, and a system update. It cannot see anything the kernel does not expose: the 2023 Operation Triangulation chain bypassed kernel memory protection through undocumented chip registers that never appeared in any reading an app can take. A quiet monitor is evidence, not proof.", bundle: .module)
    }
}
