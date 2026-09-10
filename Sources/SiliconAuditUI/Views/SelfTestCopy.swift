import SiliconAuditCore
import SwiftUI

/// Plain-English sentences for self-test facts (SPEC §11), derived from the exported `probe` so
/// they work for imported reports too, whose `description` is not exported.
enum SelfTestCopy {
    static func explanation(state: FactState, probe: ProbeDetails) -> String {
        let entitlement: String
        switch probe.entitlement {
        case "declared": entitlement = String(localized: "This build declares the Enhanced Security entitlement.", bundle: .module)
        case "not_declared": entitlement = String(localized: "This build does not declare the Enhanced Security entitlement.", bundle: .module)
        default: entitlement = String(localized: "Whether this build declares the Enhanced Security entitlement is unknown.", bundle: .module)
        }
        switch (probe.method, state) {
        case ("tagged_pointer_observation", .present):
            return String(localized: "\(probe.tagged ?? 0) of \(probe.samples ?? 0) heap allocations came back tagged: the OS tags this process's memory. Tags alone do not show that a mismatched access would be stopped.", bundle: .module)
        case ("tagged_pointer_observation", .notPresent):
            return String(localized: "None of \(probe.samples ?? 0) heap allocations carried a tag. \(entitlement)", bundle: .module)
        case ("tagged_pointer_observation", .notApplicable):
            return String(localized: "This kernel reports no memory-tagging hardware, so no process on this device can be tagged.", bundle: .module)
        case ("child_process_tag_mismatch_store", .present):
            return String(localized: "A child process that stored past a heap block was killed by signal \(probe.childSignal ?? 0) at the store: the OS stopped the mismatched access.", bundle: .module)
        case ("child_process_tag_mismatch_store", .notPresent):
            return String(localized: "A child process stored past a heap block and exited normally: no tag check applied to it. \(entitlement)", bundle: .module)
        case (_, .error):
            return String(localized: "The self-test was inconclusive.", bundle: .module)
        default:
            return String(localized: "Measured inside this process.", bundle: .module)
        }
    }
}
