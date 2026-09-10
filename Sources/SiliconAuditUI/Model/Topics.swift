import Foundation
import SiliconAuditCore

/// Presentation modes (SPEC §6.4). `overview` is the default: a handful of plain-language
/// topics with a verdict word each. `details` is the full fact-level view.
public enum PresentationMode: String, CaseIterable, Identifiable, Sendable {
    case overview, details
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return String(localized: "Overview", bundle: .module)
        case .details: return String(localized: "Details", bundle: .module)
        }
    }
}

/// A plain-language verdict derived from facts. The provenance is never dropped: a topic built
/// from measurements says so, one built from Apple's documentation says so and carries the date.
public struct TopicVerdict: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case yes, partial, no, unknown
    }

    public let level: Level
    /// One word or short phrase: "Yes", "No", "Partial", "Not documented", "Not readable".
    public let word: String
    /// One plain-English sentence about what was found.
    public let sentence: String
    public let provenance: Provenance
    /// Set for documented topics.
    public let source: FactSource?
}

/// One overview card: what the feature is, in words a non-specialist can use, and which facts
/// decide its verdict.
public struct Topic: Identifiable, Equatable, Sendable {
    public enum Rule: Equatable, Sendable {
        /// One measured flag decides; the rest are shown as supporting facts.
        case flag(primary: String, supporting: [String])
        /// Several measured flags; verdict is how many are present.
        case group([String])
        /// One documented claim decides.
        case documented(String)
        /// Several documented claims; verdict is how many Apple lists for this chip family.
        case documentedGroup([String])
        /// A measured gauge: nonzero means active now.
        case gauge(String)
        /// A measurement made inside this process (SPEC §11): the self-test fact with this id.
        case selfTest(String)
    }

    /// Device topics describe the chip and kernel; process topics describe this build of the app
    /// (SPEC §11) and are listed under their own heading so nobody reads them as chip properties.
    public enum Scope: Equatable, Sendable { case device, process }

    public let id: String
    public let title: String
    public let symbol: String
    /// What this protection does, in one or two plain sentences.
    public let plain: String
    public let rule: Rule
    public var scope: Scope = .device

    public static var deviceTopics: [Topic] { all.filter { $0.scope == .device } }
    public static var processTopics: [Topic] { all.filter { $0.scope == .process } }

    /// Every fact id the topic draws on, for the drill-down list.
    public var factIDs: [String] {
        switch rule {
        case .flag(let p, let s): return [p] + s
        case .group(let ids), .documentedGroup(let ids): return ids
        case .documented(let id), .gauge(let id), .selfTest(let id): return [id]
        }
    }

    public static let all: [Topic] = [
        Topic(id: "memory_tagging", title: String(localized: "Memory tagging hardware", bundle: .module), symbol: "tag.fill",
              plain: String(localized: "Lets the chip catch a program reading or writing memory it should not touch. This is the hardware behind Apple's Memory Integrity Enforcement.", bundle: .module),
              rule: .flag(primary: "arm.FEAT_MTE4", supporting: ["arm.FEAT_MTE", "arm.FEAT_MTE2", "arm.FEAT_MTE_CANONICAL_TAGS", "arm.FEAT_MTE_STORE_ONLY", "arm.FEAT_MTE_NO_ADDRESS_TAGS", "arm.FEAT_MTE3", "arm.FEAT_MTE_ASYNC"])),
        Topic(id: "mie", title: String(localized: "Memory Integrity Enforcement", bundle: .module), symbol: "shield.lefthalf.filled",
              plain: String(localized: "Apple's always-on memory-safety defense: tagging hardware in strict mode, hardened allocators, and protections against leaking the tags. The hardware flag alone does not make this true; this card reports what Apple documents.", bundle: .module),
              rule: .documented("mie")),
        Topic(id: "pointer_authentication", title: String(localized: "Pointer authentication", bundle: .module), symbol: "signature",
              plain: String(localized: "Signs pointers so that hijacked code paths fail instead of running attacker-chosen code.", bundle: .module),
              rule: .flag(primary: "arm.FEAT_PAuth", supporting: ["arm.FEAT_PAuth2", "arm.FEAT_FPAC", "arm.FEAT_FPACCOMBINE", "arm.FEAT_PACIMP"])),
        Topic(id: "control_flow", title: String(localized: "Branch target protection", bundle: .module), symbol: "arrow.triangle.turn.up.right.diamond",
              plain: String(localized: "Restricts where indirect jumps may land, blocking a common way of stitching together attack code.", bundle: .module),
              rule: .flag(primary: "arm.FEAT_BTI", supporting: [])),
        Topic(id: "speculation", title: String(localized: "Speculation hardening", bundle: .module), symbol: "bolt.shield",
              plain: String(localized: "Hardware answers to Spectre-style attacks that read secrets through the processor's guesswork.", bundle: .module),
              rule: .group(["arm.FEAT_CSV2", "arm.FEAT_CSV3", "arm.FEAT_SB", "arm.FEAT_SSBS", "arm.FEAT_SPECRES", "arm.FEAT_SPECRES2"])),
        Topic(id: "constant_time", title: String(localized: "Constant-time computing", bundle: .module), symbol: "timer",
              plain: String(localized: "Lets cryptography run in the same time regardless of the secret, so timing cannot leak keys.", bundle: .module),
              rule: .flag(primary: "arm.FEAT_DIT", supporting: [])),
        Topic(id: "kernel_integrity", title: String(localized: "Kernel protections Apple documents", bundle: .module), symbol: "lock.doc",
              plain: String(localized: "Apple's published list of protections that keep the operating system's core from being modified at runtime, for this chip family.", bundle: .module),
              rule: .documentedGroup(["kip", "fast_permission_restrictions", "scip", "pac", "ppl", "sptm"])),
        Topic(id: "os_memory_tagging", title: String(localized: "Memory tagging active right now", bundle: .module), symbol: "waveform.path.ecg",
              plain: String(localized: "Whether the operating system is tagging memory at this moment. Only macOS lets an app read this: iPhone refuses the read, and the Watch kernel has no such counters.", bundle: .module),
              rule: .gauge("vm.mte.tagged")),
        Topic(id: "enforcement", title: String(localized: "Memory tagging active for this app", bundle: .module), symbol: "checkmark.seal",
              plain: String(localized: "Whether the operating system tags this app's own memory, measured from inside the app. It says something about this build, not about the device.", bundle: .module),
              rule: .selfTest("self_test.tagged_pointers"), scope: .process),
    ]

    // MARK: - Verdicts

    public func verdict(in report: Report) -> TopicVerdict {
        func fact(_ id: String) -> Fact? { report.facts.first { $0.id == id } }
        switch rule {
        case .flag(let primary, _):
            guard let f = fact(primary) else { return unreadable() }
            return measured(f)
        case .group(let ids):
            let facts = ids.compactMap(fact)
            let readable = facts.filter { $0.state == .present || $0.state == .notPresent }
            guard !readable.isEmpty else { return unreadable() }
            let present = readable.filter { $0.state == .present }.count
            let level: TopicVerdict.Level = present == readable.count ? .yes : (present == 0 ? .no : .partial)
            let word = present == readable.count ? String(localized: "Yes", bundle: .module)
                : present == 0 ? String(localized: "No", bundle: .module)
                : String(localized: "Partial", bundle: .module)
            return TopicVerdict(level: level, word: word,
                                sentence: String(localized: "This device's kernel reports \(present) of \(readable.count) mitigations as on.", bundle: .module),
                                provenance: .measured, source: nil)
        case .documented(let id):
            guard let f = fact(id) else { return unreadable() }
            return documented(f)
        case .documentedGroup(let ids):
            let facts = ids.compactMap(fact)
            guard let first = facts.first else { return unreadable() }
            if facts.allSatisfy({ $0.state == .unknown }) {
                return TopicVerdict(level: .unknown, word: String(localized: "Not documented", bundle: .module),
                                    sentence: String(localized: "Apple has not published this chip family in its table yet.", bundle: .module),
                                    provenance: .documented, source: first.source)
            }
            let present = facts.filter { $0.state == .present }.count
            return TopicVerdict(level: present == facts.count ? .yes : (present == 0 ? .no : .partial),
                                word: String(localized: "\(present) of \(facts.count)", bundle: .module),
                                sentence: String(localized: "Apple documents \(present) of these \(facts.count) protections for this chip family.", bundle: .module),
                                provenance: .documented, source: first.source)
        case .selfTest(let id):
            guard let f = fact(id) else { return unreadable() }
            return selfTest(f)
        case .gauge(let id):
            guard let f = fact(id) else { return unreadable() }
            switch f.state {
            case .value:
                // Gauges may be declared signed (`I`) or unsigned (`IU`); both count.
                let n: UInt64 = f.raw?.value.flatMap { (v: RawValue) -> UInt64? in
                    switch v {
                    case .int(let i): return i > 0 ? UInt64(i) : 0
                    case .uint(let u): return u
                    case .string: return nil
                    }
                } ?? 0
                return TopicVerdict(level: n > 0 ? .yes : .no, word: n > 0 ? String(localized: "Yes", bundle: .module) : String(localized: "No", bundle: .module),
                                    sentence: n > 0 ? String(localized: "The kernel reports \(n) tagged pages right now.", bundle: .module)
                                                    : String(localized: "The kernel reports no tagged pages right now.", bundle: .module),
                                    provenance: .measured, source: nil)
            case .restricted:
                return TopicVerdict(level: .unknown, word: String(localized: "Not readable", bundle: .module),
                                    sentence: String(localized: "This platform does not let apps read the kernel's tagging counters.", bundle: .module),
                                    provenance: .measured, source: nil)
            case .keyAbsent:
                return TopicVerdict(level: .unknown, word: String(localized: "Not present", bundle: .module),
                                    sentence: String(localized: "This kernel has no memory-tagging counters at all.", bundle: .module),
                                    provenance: .measured, source: nil)
            default:
                return unreadable()
            }
        }
    }

    private func measured(_ f: Fact) -> TopicVerdict {
        switch f.state {
        case .present:
            return TopicVerdict(level: .yes, word: String(localized: "Yes", bundle: .module),
                                sentence: String(localized: "This device's kernel reports \(f.displayName ?? f.id) as on.", bundle: .module),
                                provenance: .measured, source: nil)
        case .notPresent:
            return TopicVerdict(level: .no, word: String(localized: "No", bundle: .module),
                                sentence: String(localized: "This device's kernel knows \(f.displayName ?? f.id) and reports it off. A kernel can also mask a feature it has not enabled.", bundle: .module),
                                provenance: .measured, source: nil)
        case .keyAbsent:
            return TopicVerdict(level: .unknown, word: String(localized: "Unknown", bundle: .module),
                                sentence: String(localized: "This kernel has no entry for \(f.displayName ?? f.id); it is too old to say, or the concept does not apply here.", bundle: .module),
                                provenance: .measured, source: nil)
        case .restricted:
            return TopicVerdict(level: .unknown, word: String(localized: "Not readable", bundle: .module),
                                sentence: String(localized: "This platform refused to let the app read \(f.displayName ?? f.id).", bundle: .module),
                                provenance: .measured, source: nil)
        default:
            return unreadable()
        }
    }

    private func documented(_ f: Fact) -> TopicVerdict {
        switch f.state {
        case .present:
            return TopicVerdict(level: .yes, word: String(localized: "Apple says yes", bundle: .module),
                                sentence: String(localized: "Apple documents \(f.displayName ?? f.id) for this chip family.", bundle: .module),
                                provenance: .documented, source: f.source)
        case .notPresent:
            return TopicVerdict(level: .no, word: String(localized: "Apple says no", bundle: .module),
                                sentence: String(localized: "Apple's table does not list \(f.displayName ?? f.id) for this chip family.", bundle: .module),
                                provenance: .documented, source: f.source)
        default:
            return TopicVerdict(level: .unknown, word: String(localized: "Not documented", bundle: .module),
                                sentence: String(localized: "Apple has not documented this chip family yet, so the app will not guess.", bundle: .module),
                                provenance: .documented, source: f.source)
        }
    }

    /// SPEC §11: a per-process fact, worded so nobody reads it as a device property.
    private func selfTest(_ f: Fact) -> TopicVerdict {
        switch f.state {
        case .present:
            return TopicVerdict(level: .yes, word: String(localized: "Yes", bundle: .module),
                                sentence: String(localized: "This app's own heap allocations carry memory tags: the OS tags this process's memory. Tags alone do not show that a mismatched access would be stopped.", bundle: .module),
                                provenance: .measured, source: nil)
        case .notPresent:
            let sentence: String
            switch f.probe?.entitlement {
            case "declared":
                sentence = String(localized: "This app's allocations carry no tags even though this build declares the Enhanced Security entitlement.", bundle: .module)
            case "not_declared":
                sentence = String(localized: "This app's allocations carry no tags. This build does not declare the Enhanced Security entitlement, so the OS does not tag its memory.", bundle: .module)
            default:
                sentence = String(localized: "This app's allocations carry no tags. Whether this build declares the Enhanced Security entitlement could not be determined.", bundle: .module)
            }
            return TopicVerdict(level: .no, word: String(localized: "No", bundle: .module), sentence: sentence, provenance: .measured, source: nil)
        case .notApplicable:
            return TopicVerdict(level: .unknown, word: String(localized: "No hardware", bundle: .module),
                                sentence: String(localized: "This chip's kernel reports no memory-tagging hardware, so no app on this device can be tagged.", bundle: .module),
                                provenance: .measured, source: nil)
        default:
            return unreadable()
        }
    }

    private func unreadable() -> TopicVerdict {
        TopicVerdict(level: .unknown, word: String(localized: "Unknown", bundle: .module),
                     sentence: String(localized: "Nothing about this could be read on this device.", bundle: .module),
                     provenance: .unknown, source: nil)
    }
}
