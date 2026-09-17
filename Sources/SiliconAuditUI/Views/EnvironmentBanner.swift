import SiliconAuditCore
import SwiftUI

/// Persistent, non-dismissable warning when the numbers describe the host or a hypervisor
/// rather than the device (SPEC §6.2, §14). Symbol plus text; color is secondary.
public struct EnvironmentBanner: View {
    let environment: Report.Environment
    public init(_ environment: Report.Environment) { self.environment = environment }

    public var body: some View {
        if environment.isMisleading {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    #if os(watchOS)
                    Text(String(localized: "Host values, not this device. Do not submit.", bundle: .module))
                        .font(.caption2)
                    #else
                    Text(String(localized: "These readings describe the computer running this copy, not a real device. Do not submit them to the results database.", bundle: .module))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    var title: String {
        var reasons: [String] = []
        #if os(watchOS)
        if environment.isSimulator { reasons.append(String(localized: "Simulator", bundle: .module)) }
        if environment.isTranslated { reasons.append(String(localized: "Rosetta", bundle: .module)) }
        if environment.isiOSAppOnMac { reasons.append(String(localized: "On a Mac", bundle: .module)) }
        if environment.isVirtualMachine { reasons.append(String(localized: "Virtual machine", bundle: .module)) }
        #else
        if environment.isSimulator { reasons.append(String(localized: "Running in the Simulator", bundle: .module)) }
        if environment.isTranslated { reasons.append(String(localized: "Running under Rosetta", bundle: .module)) }
        if environment.isiOSAppOnMac { reasons.append(String(localized: "iPhone app running on a Mac", bundle: .module)) }
        if environment.isVirtualMachine { reasons.append(String(localized: "Running in a virtual machine", bundle: .module)) }
        #endif
        return reasons.joined(separator: " · ")
    }
}
