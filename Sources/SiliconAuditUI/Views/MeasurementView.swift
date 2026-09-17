import SiliconAuditCore
import SwiftUI

/// How the report was produced: what the device is, how the chip was identified, what could be
/// read and how, and what the numbers add up to. This is where the technical identity that used
/// to crowd the summary card lives (SPEC §6.4 "Summary first", §4.2, §6.2).
public struct MeasurementView: View {
    let model: ReportModel
    public init(model: ReportModel) { self.model = model }

    public var body: some View {
        if let report = model.report {
            List {
                Section {
                    LabeledContent(String(localized: "Device", bundle: .module), value: report.device.identity)
                    wrapping(String(localized: "Chip", bundle: .module), chipText(report))
                    if let soc = report.device.socId {
                        LabeledContent(String(localized: "Kernel target", bundle: .module)) {
                            Text(soc).font(.callout.monospaced())
                        }
                    }
                    LabeledContent(String(localized: "Core family", bundle: .module), value: coreFamily(report))
                    LabeledContent(String(localized: "System", bundle: .module), value: "\(report.environment.platform) \(report.environment.osVersion) (\(report.environment.osBuild))")
                    LabeledContent(String(localized: "Architecture", bundle: .module), value: report.environment.arch)
                } header: {
                    Text(String(localized: "This device", bundle: .module))
                } footer: {
                    Text(chipFooter(report))
                }

                Section {
                    wrapping(String(localized: "Kernel walk", bundle: .module), walkText(report))
                    LabeledContent(String(localized: "Value types", bundle: .module), value: report.collection.kernelFormatsAvailable
                                   ? String(localized: "Declared by the kernel", bundle: .module)
                                   : String(localized: "From the app's inventory", bundle: .module))
                    LabeledContent(String(localized: "Environment", bundle: .module), value: environmentText(report))
                } header: {
                    Text(String(localized: "How it was collected", bundle: .module))
                } footer: {
                    Text(String(localized: "The app walks the kernel's sysctl tree and also asks for every key in its inventory by name, so a key the sandbox hides from the walk is still found, and a key the inventory does not know yet still appears.", bundle: .module))
                }

                Section {
                    LabeledContent(String(localized: "Facts", bundle: .module), value: "\(model.factCount)")
                    // Keys the inventory does not know are measured too; they live in `unrecognizedKeys`.
                    LabeledContent(String(localized: "Measured", bundle: .module), value: "\(report.measuredFacts.count + report.unrecognizedKeys.filter { $0.provenance == .measured }.count)")
                    LabeledContent(String(localized: "Documented by Apple", bundle: .module), value: "\(report.documentedFacts.count)")
                    LabeledContent(String(localized: "Inferred", bundle: .module), value: "\(report.inferredFacts.count)")
                    LabeledContent(String(localized: "New keys not in the inventory", bundle: .module), value: "\(report.unrecognizedKeys.count)")
                    LabeledContent(String(localized: "Security flags reported present", bundle: .module),
                                   value: String(localized: "\(model.securitySummary.present) of \(model.securitySummary.total)", bundle: .module))
                } header: {
                    Text(String(localized: "What it adds up to", bundle: .module))
                } footer: {
                    Text(String(localized: "Measured means reported by this kernel, not proven in the silicon; a kernel can mask a feature it has not enabled. Inventory \(report.collection.knownKeysVersion ?? "unknown"), engine \(report.appVersion), export schema \(report.schemaVersion).", bundle: .module))
                }
            }
            .navigationTitle(String(localized: "How this was measured", bundle: .module))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    /// A `LabeledContent` whose value wraps instead of truncating in a narrow Mac window.
    private func wrapping(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chipText(_ report: Report) -> String {
        let d = report.device
        if d.socId == nil { return String(localized: "No Apple silicon target", bundle: .module) }
        if d.socInferenceConfidence == "none" { return String(localized: "Not in the app's map", bundle: .module) }
        return d.socNameInferred
    }

    private func chipFooter(_ report: Report) -> String {
        let d = report.device
        guard let soc = d.socId else {
            return String(localized: "kern.version names no RELEASE_ARM64_T target on this device, so no chip can be looked up in Apple's table. Expected on Intel Macs.", bundle: .module)
        }
        switch d.socInferenceConfidence {
        case "verified": return String(localized: "The chip name is inferred from kernel target \(soc), a verified entry in the app's map. The kernel target and core family are measured; the name is not.", bundle: .module)
        case "reported": return String(localized: "The chip name is inferred from kernel target \(soc), an entry in the app's map that has been reported but not verified on hardware.", bundle: .module)
        default: return String(localized: "Kernel target \(soc) is not in the app's map yet, so Apple's documentation is not applied to this device. A data update fills this in.", bundle: .module)
        }
    }

    private func coreFamily(_ report: Report) -> String {
        let d = report.device
        if d.cpufamilyName == "unrecognized" { return String(localized: "Unrecognized (\(d.cpufamily ?? "?"))", bundle: .module) }
        return d.cpufamilyName.replacingOccurrences(of: "CPUFAMILY_ARM_", with: "").replacingOccurrences(of: "CPUFAMILY_", with: "")
    }

    private func walkText(_ report: Report) -> String {
        if report.collection.walkSucceeded { return String(localized: "Succeeded", bundle: .module) }
        if let failure = report.collection.walkFailure, failure.contains("errno 1 ") || failure.contains("errno 13 ") {
            return String(localized: "Refused by the sandbox", bundle: .module)
        }
        if let failure = report.collection.walkFailure { return String(localized: "Failed: \(failure)", bundle: .module) }
        return String(localized: "Failed", bundle: .module)
    }

    private func environmentText(_ report: Report) -> String {
        let e = report.environment
        var parts: [String] = []
        if e.isSimulator { parts.append(String(localized: "Simulator", bundle: .module)) }
        if e.isTranslated { parts.append(String(localized: "Rosetta", bundle: .module)) }
        if e.isiOSAppOnMac { parts.append(String(localized: "iPhone app on a Mac", bundle: .module)) }
        if e.isVirtualMachine { parts.append(String(localized: "Virtual machine", bundle: .module)) }
        if e.isCatalyst { parts.append(String(localized: "Mac Catalyst", bundle: .module)) }
        return parts.isEmpty ? String(localized: "The device itself", bundle: .module) : parts.joined(separator: ", ")
    }
}
