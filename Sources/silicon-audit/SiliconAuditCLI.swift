import ArgumentParser
import Foundation
import SiliconAuditCore

/// `silicon-audit` — command-line front end for the probe engine (macOS).
/// `audit`, `export`, and `keys` arrive in Phase 3; `raw` is the Phase 1 view.
@main
struct SiliconAuditCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "silicon-audit",
        abstract: "Report which CPU security features this device's kernel exposes.",
        version: SiliconAuditCore.version,
        subcommands: [Raw.self],
        defaultSubcommand: Raw.self
    )
}

struct Raw: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dump the unannotated walk and named reads (engine development view)."
    )

    @Flag(name: .long, help: "Include every walked key, not just a summary.")
    var all = false

    func run() throws {
        let result = Auditor().rawAudit()
        let env = result.environment
        print("Environment: \(env.platform.rawValue) \(env.arch.rawValue), OS \(env.osVersion) (\(env.osBuild))")
        print("Kernel:      \(env.kernelVersion)")
        if env.isMisleading {
            print("WARNING:     simulator=\(env.isSimulator) translated=\(env.isTranslated) iOSAppOnMac=\(env.isiOSAppOnMac) virtualMachine=\(env.isVirtualMachine); values describe the host, not the device")
        }
        print("Walk:        root=\(result.walk.root) succeeded=\(result.walk.succeeded) keys=\(result.walk.keys.count) masked=\(result.walk.keys.filter(\.isMasked).count) unnamed=\(result.walk.unnamedOIDCount) notApplicable=\(result.notApplicableCount) restricted=\(result.restrictedCount)")
        if let f = result.walk.failure { print("Walk failure: \(f)") }
        print("OIDFMT:      \(result.kernelFormatsAvailable ? "kernel-declared formats available" : "unavailable; types from inventory")")
        print("")
        print("Named reads:")
        for key in Auditor.namedKeys {
            print("  \(key.padding(toLength: 44, withPad: " ", startingAt: 0)) \(describe(result.namedReads[key]))")
        }
        if all {
            print("")
            print("Walked keys:")
            for k in result.walk.keys {
                print("  \(k.name.padding(toLength: 44, withPad: " ", startingAt: 0)) \(describe(k.outcome))\(k.isMasked ? "  [masked]" : "")")
            }
        }
    }

    private func describe(_ outcome: ProbeOutcome?) -> String {
        switch outcome {
        case nil: return "-"
        case .absent: return "absent (ENOENT)"
        case .restricted: return "restricted (EPERM/EACCES)"
        case .notApplicable: return "not applicable (ENOTSUP)"
        case .error(let e): return "error errno=\(e)"
        case .value(let v):
            let type = (v.format?.typeName ?? "?") + (v.format?.source == .inventory ? "*" : "")
            switch v.payload {
            case .int(let n): return "\(n)  [\(type), \(v.length)B]"
            case .uint(let n): return "\(n)  [\(type), \(v.length)B]"
            case .string(let s): return "\"\(s)\"  [\(type), \(v.length)B]"
            case .bytes: return "0x\(v.hex)  [\(type), \(v.length)B]"
            }
        }
    }
}
