import Foundation

/// How and where the audit ran. This is the only file in the core allowed to use
/// `#if os(...)`, `#if arch(...)`, or `#if targetEnvironment(...)` (spec §6.1). Named `AuditEnvironment` to stay clear of SwiftUI's `Environment`.
///
/// Every field here exists because it changes how a result must be read:
/// a simulator, a translated process, or an iOS app on a Mac reports the host's
/// chip, not the device the user thinks they are auditing (spec §6.2, §14).
public struct AuditEnvironment: Equatable, Hashable, Sendable {
    public enum Platform: String, Codable, Sendable {
        case iOS, iPadOS, macOS, watchOS, tvOS, visionOS, unknown
    }

    public enum Arch: String, Codable, Sendable {
        case arm64, arm64e, x86_64, unknown
    }

    public let platform: Platform
    public let arch: Arch
    /// Marketing version, e.g. "26.6.2" (`kern.osproductversion`).
    public let osVersion: String
    /// Build, e.g. "25G83" (`kern.osversion`). The conflict key for the results database.
    public let osBuild: String
    /// Full `kern.version` string; also the source of `soc_id`.
    public let kernelVersion: String
    public let isSimulator: Bool
    /// Rosetta: `sysctl.proc_translated == 1`.
    public let isTranslated: Bool
    public let isiOSAppOnMac: Bool
    public let isCatalyst: Bool
    /// macOS guest (CI runner, Virtualization.framework VM): `kern.hv_vmm_present == 1`,
    /// a `VMAPPLE` kernel target, or a `VirtualMac` model. The guest sees what the
    /// hypervisor exposes, not a chip.
    public let isVirtualMachine: Bool

    /// True when the numbers this process sees are not the device's own.
    public var isMisleading: Bool { isSimulator || isTranslated || isiOSAppOnMac || isVirtualMachine }

    public init(platform: Platform, arch: Arch, osVersion: String, osBuild: String, kernelVersion: String,
                isSimulator: Bool, isTranslated: Bool, isiOSAppOnMac: Bool, isCatalyst: Bool, isVirtualMachine: Bool = false) {
        self.platform = platform
        self.arch = arch
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.kernelVersion = kernelVersion
        self.isSimulator = isSimulator
        self.isTranslated = isTranslated
        self.isiOSAppOnMac = isiOSAppOnMac
        self.isCatalyst = isCatalyst
        self.isVirtualMachine = isVirtualMachine
    }

    /// Detects the current environment. Compile-time facts come from the build;
    /// everything else is read through `sysctl` so fixtures can drive it.
    public static func detect(using sysctl: any SysctlReading, processInfo: ProcessInfo = .processInfo) -> AuditEnvironment {
        let productName = sysctl.read("hw.product").value?.payload.stringValue
            ?? sysctl.read("hw.machine").value?.payload.stringValue
            ?? ""
        let model = sysctl.read("hw.model").value?.payload.stringValue ?? ""
        let kernel = sysctl.read("kern.version").value?.payload.stringValue ?? ""
        let hvGuest = sysctl.read("kern.hv_vmm_present").flagIsSet ?? false

        return AuditEnvironment(
            platform: compiledPlatform(productName: productName),
            arch: compiledArch,
            osVersion: sysctl.read("kern.osproductversion").value?.payload.stringValue
                ?? fallbackOSVersion(processInfo),
            osBuild: sysctl.read("kern.osversion").value?.payload.stringValue ?? "",
            kernelVersion: kernel,
            isSimulator: compiledSimulator || processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil,
            isTranslated: sysctl.read("sysctl.proc_translated").flagIsSet ?? false,
            isiOSAppOnMac: processInfo.isiOSAppOnMac,
            isCatalyst: compiledCatalyst,
            isVirtualMachine: hvGuest || kernel.contains("VMAPPLE") || model.hasPrefix("VirtualMac")
        )
    }

    // MARK: - Compile-time facts

    static func compiledPlatform(productName: String) -> Platform {
        // Catalyst compiles with os(iOS) true; it must be classified as macOS (spec §6.2).
        #if targetEnvironment(macCatalyst)
        return .macOS
        #elseif os(watchOS)
        return .watchOS
        #elseif os(tvOS)
        return .tvOS
        #elseif os(visionOS)
        return .visionOS
        #elseif os(macOS)
        return .macOS
        #elseif os(iOS)
        // UIKit is off-limits in the core; the product string tells iPad from iPhone.
        return productName.hasPrefix("iPad") ? .iPadOS : .iOS
        #else
        return .unknown
        #endif
    }

    static var compiledArch: Arch {
        #if arch(arm64) && _ptrauth(_arm64e)
        return .arm64e
        #elseif arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .unknown
        #endif
    }

    static var compiledSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static var compiledCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    private static func fallbackOSVersion(_ processInfo: ProcessInfo) -> String {
        let v = processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
