import ArgumentParser
import SiliconAuditCore

/// `silicon-audit` — command-line front end for the probe engine (macOS).
/// Subcommands (`audit`, `export`, `keys`) arrive in Phase 3.
@main
struct SiliconAuditCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "silicon-audit",
        abstract: "Report which CPU security features this device's kernel exposes.",
        version: SiliconAuditCore.version
    )

    func run() throws {
        print("silicon-audit \(SiliconAuditCore.version). Subcommands arrive in a later phase; try --help.")
    }
}
