import SiliconAuditCore
import SwiftUI

/// Everything behind one fact: the raw key, type, length and value; the plain-English
/// meaning; and the provenance chain (SPEC §3, §6.4).
public struct FactDetailView: View {
    let fact: Fact
    public init(_ fact: Fact) { self.fact = fact }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    StateGlyph(fact.state)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(StateStyle.label(fact.state, provenance: fact.provenance)).font(.headline)
                        if fact.probe == nil {
                            // Self-test facts carry their own sentence in `description`; the generic
                            // sysctl wording would mislead there.
                            Text(StateStyle.explanation(fact.state, provenance: fact.provenance)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                if let description = fact.description {
                    Text(description)
                }
            } header: {
                Text(fact.displayName ?? fact.id)
            }

            Section(String(localized: "Provenance", bundle: .module)) {
                HStack {
                    ProvenanceBadge(fact.provenance)
                    Text(ProvenanceStyle.explanation(fact.provenance)).font(.subheadline).foregroundStyle(.secondary)
                }
                if let reasoning = fact.reasoning {
                    LabeledContent(String(localized: "Reasoning", bundle: .module)) {
                        Text(reasoning).font(.callout)
                    }
                }
                if let source = fact.source {
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            Label(String(localized: "Apple's source", bundle: .module), systemImage: "safari")
                        }
                    }
                    LabeledContent(String(localized: "Published", bundle: .module), value: source.published)
                    LabeledContent(String(localized: "Last verified by this app", bundle: .module), value: source.verified)
                    if let note = source.note {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let discovered = fact.discoveredBy {
                    LabeledContent(String(localized: "Found by", bundle: .module), value: discoveredLabel(discovered))
                }
            }

            if let probe = fact.probe {
                Section {
                    LabeledContent(String(localized: "Method", bundle: .module)) {
                        Text(probe.method).font(.callout.monospaced())
                    }
                    if let samples = probe.samples, let tagged = probe.tagged {
                        LabeledContent(String(localized: "Allocations sampled", bundle: .module), value: "\(samples)")
                        LabeledContent(String(localized: "With a nonzero tag", bundle: .module), value: "\(tagged)")
                    }
                    if let distinct = probe.distinctTags {
                        LabeledContent(String(localized: "Distinct tag values", bundle: .module), value: "\(distinct)")
                    }
                    LabeledContent(String(localized: "Enhanced Security entitlement", bundle: .module), value: entitlementLabel(probe.entitlement))
                    if let signal = probe.childSignal {
                        LabeledContent(String(localized: "Child process ended by signal", bundle: .module), value: "\(signal)")
                    }
                    if let status = probe.childExitStatus {
                        LabeledContent(String(localized: "Child process exit status", bundle: .module), value: "\(status)")
                    }
                } header: {
                    Text(String(localized: "Self-test", bundle: .module))
                } footer: {
                    Text(String(localized: "Measured inside this process. It describes this build of the app, not the device: another app on the same device can differ.", bundle: .module))
                }
            }

            if let raw = fact.raw {
                Section(String(localized: "Raw reading", bundle: .module)) {
                    LabeledContent(String(localized: "sysctl key", bundle: .module)) {
                        Text(raw.key).font(.callout.monospaced()).selectableText()
                    }
                    LabeledContent(String(localized: "Type", bundle: .module)) {
                        Text(typeText(raw)).font(.callout.monospaced())
                    }
                    LabeledContent(String(localized: "Length", bundle: .module), value: "\(raw.length) B")
                    if let value = valueText(raw) {
                        LabeledContent(String(localized: "Value", bundle: .module)) {
                            Text(value).font(.callout.monospaced()).selectableText()
                        }
                    }
                    if let errno = raw.errno {
                        LabeledContent(String(localized: "errno", bundle: .module), value: "\(errno) (\(errnoName(errno)))")
                    }
                    if raw.masked == true {
                        Text(String(localized: "Flagged deprecated by the kernel (CTLFLAG_MASKED).", bundle: .module)).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(fact.displayName ?? fact.id)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    func typeText(_ raw: RawReading) -> String {
        guard let format = raw.format else { return String(localized: "unknown", bundle: .module) }
        if raw.formatSource == "inventory" {
            return format + " " + String(localized: "(declared by the app's inventory; the sandbox refused the kernel's type)", bundle: .module)
        }
        return format + " " + String(localized: "(declared by the kernel)", bundle: .module)
    }

    func valueText(_ raw: RawReading) -> String? {
        switch raw.value {
        case .int(let i):
            if raw.key == "hw.cpufamily" { return "\(i) (0x\(String(UInt32(bitPattern: Int32(truncatingIfNeeded: i)), radix: 16)))" }
            return String(i)
        case .uint(let u): return String(u)
        case .string(let s): return s
        case nil: return raw.valueHex.map { "0x" + $0 }
        }
    }

    func discoveredLabel(_ d: DiscoveredBy) -> String {
        switch d {
        case .walk: return String(localized: "MIB walk only", bundle: .module)
        case .knownList: return String(localized: "By name from the inventory", bundle: .module)
        case .both: return String(localized: "MIB walk and by name", bundle: .module)
        case .selfTest: return String(localized: "Measured inside this process", bundle: .module)
        }
    }

    func entitlementLabel(_ e: String) -> String {
        switch e {
        case "declared": return String(localized: "declared by this build", bundle: .module)
        case "not_declared": return String(localized: "not declared by this build", bundle: .module)
        default: return String(localized: "unknown", bundle: .module)
        }
    }

    func errnoName(_ e: Int32) -> String {
        switch e {
        case 1: return "EPERM"
        case 2: return "ENOENT"
        case 13: return "EACCES"
        case 45: return "ENOTSUP"
        default: return String(cString: strerror(e))
        }
    }
}

extension View {
    /// `textSelection` does not exist on watchOS or tvOS; everywhere else the raw key and value are selectable.
    @ViewBuilder
    func selectableText() -> some View {
        #if os(watchOS) || os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}
