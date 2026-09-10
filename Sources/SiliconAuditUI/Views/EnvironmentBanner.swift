import SiliconAuditCore
import SwiftUI

/// Persistent, non-dismissable warning when the numbers describe the host or a hypervisor
/// rather than the device (SPEC §6.2, §14). Symbol plus text; color is secondary.
public struct EnvironmentBanner: View {
    let environment: Report.Environment
    public init(_ environment: Report.Environment) { self.environment = environment }

    public var body: some View {
        if environment.isMisleading {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(String(localized: "These values describe the host, not a real device. Do not submit them to the results database.", bundle: .module))
                        .font(.caption)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    var title: String {
        var reasons: [String] = []
        if environment.isSimulator { reasons.append(String(localized: "Simulator", bundle: .module)) }
        if environment.isTranslated { reasons.append(String(localized: "Rosetta translation", bundle: .module)) }
        if environment.isiOSAppOnMac { reasons.append(String(localized: "iOS app running on a Mac", bundle: .module)) }
        if environment.isVirtualMachine { reasons.append(String(localized: "Virtual machine", bundle: .module)) }
        return reasons.joined(separator: " · ")
    }
}
