import SiliconAuditCore
import SwiftUI

/// The headline card (SPEC §6.4): device, SoC with its inference chain, the security-flag
/// count, OS build, and how the data was collected.
public struct SummaryCard: View {
    let report: Report
    let summary: (present: Int, total: Int)

    public init(report: Report, summary: (present: Int, total: Int)) {
        self.report = report
        self.summary = summary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.device.identity)
                        .font(.title2.weight(.semibold))
                    Text("\(report.environment.platform) \(report.environment.osVersion) (\(report.environment.osBuild))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(summary.present)/\(summary.total)")
                        .font(.title.weight(.bold).monospacedDigit())
                    Text(String(localized: "security flags reported present", bundle: .module))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .accessibilityElement(children: .combine)

            Divider()

            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(report.device.socNameInferred)
                    Text(socChain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } label: {
                Label(String(localized: "System on chip", bundle: .module), systemImage: "cpu")
            }
            LabeledContent {
                Text(report.device.cpufamilyName == "unrecognized"
                     ? String(localized: "unrecognized \(report.device.cpufamily ?? "")", bundle: .module)
                     : report.device.cpufamilyName.replacingOccurrences(of: "CPUFAMILY_ARM_", with: "").replacingOccurrences(of: "CPUFAMILY_", with: ""))
            } label: {
                Label(String(localized: "Core family", bundle: .module), systemImage: "memorychip")
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(String(localized: "Collection", bundle: .module), systemImage: "list.bullet.rectangle")
                Text(collectionText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
            .accessibilityElement(children: .combine)
        }
        .font(.callout)
        .padding(16)
        .modifier(CardBackground())
    }

    var socChain: String {
        guard let soc = report.device.socId else { return String(localized: "no kernel target in kern.version", bundle: .module) }
        switch report.device.socInferenceConfidence {
        case "verified": return String(localized: "inferred from kernel target \(soc), verified map entry", bundle: .module)
        case "reported": return String(localized: "inferred from kernel target \(soc), unverified map entry", bundle: .module)
        default: return String(localized: "kernel target \(soc) is not in the app's map", bundle: .module)
        }
    }

    var collectionText: String {
        var parts: [String] = []
        if report.collection.walkSucceeded {
            parts.append(String(localized: "MIB walk and inventory", bundle: .module))
        } else if let failure = report.collection.walkFailure, failure.contains("errno 1 ") || failure.contains("errno 13 ") {
            parts.append(String(localized: "inventory only; walk refused by the sandbox", bundle: .module))
        } else if let failure = report.collection.walkFailure {
            parts.append(String(localized: "inventory plus a failed walk: \(failure)", bundle: .module))
        } else {
            parts.append(String(localized: "inventory only; walk failed", bundle: .module))
        }
        parts.append(report.collection.kernelFormatsAvailable
                     ? String(localized: "kernel-declared types", bundle: .module)
                     : String(localized: "types from the inventory", bundle: .module))
        return parts.joined(separator: " · ")
    }
}

/// Liquid Glass on OS 26, a material elsewhere. Kept as a modifier so it is the one place
/// the availability check lives.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, visionOS 26, watchOS 26, tvOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
