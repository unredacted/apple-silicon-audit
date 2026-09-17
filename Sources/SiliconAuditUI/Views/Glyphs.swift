import SiliconAuditCore
import SwiftUI

/// State and provenance are never conveyed by color alone (SPEC §6.4): every state has a
/// distinct SF Symbol, a text label, and an accessibility description; color is a bonus.
public enum StateStyle {
    public static func symbol(_ s: FactState) -> String {
        switch s {
        case .present: return "checkmark.circle.fill"
        case .notPresent: return "circle"
        case .value: return "number.circle"
        case .keyAbsent: return "minus.circle"
        case .restricted: return "lock.circle"
        case .notApplicable: return "xmark.circle"
        case .error: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }

    public static func tint(_ s: FactState) -> Color {
        switch s {
        case .present: return .green
        case .notPresent: return .secondary
        case .value: return .blue
        case .keyAbsent: return .secondary
        case .restricted: return .orange
        case .notApplicable: return .secondary
        case .error: return .red
        case .unknown: return .secondary
        }
    }

    public static func label(_ s: FactState) -> String {
        switch s {
        case .present: return String(localized: "Reported present", bundle: .module)
        case .notPresent: return String(localized: "Reported off", bundle: .module)
        case .value: return String(localized: "Read", bundle: .module)
        case .keyAbsent: return String(localized: "Key absent", bundle: .module)
        case .restricted: return String(localized: "Restricted", bundle: .module)
        case .notApplicable: return String(localized: "Not applicable", bundle: .module)
        case .error: return String(localized: "Error", bundle: .module)
        case .unknown: return String(localized: "Unknown", bundle: .module)
        }
    }

    /// Short state label given where the fact came from: a documented `present` is Apple's word,
    /// not a kernel report.
    public static func label(_ s: FactState, provenance: Provenance) -> String {
        switch provenance {
        case .measured, .unknown:
            return label(s)
        case .documented:
            switch s {
            case .present: return String(localized: "Apple documents it", bundle: .module)
            case .notPresent: return String(localized: "Not in Apple's table", bundle: .module)
            default: return String(localized: "Not documented", bundle: .module)
            }
        case .inferred:
            switch s {
            case .present: return String(localized: "Inference holds", bundle: .module)
            case .notPresent: return String(localized: "Inference contradicted", bundle: .module)
            default: return String(localized: "Could not infer", bundle: .module)
            }
        }
    }

    /// The one-sentence meaning of a state given where the fact came from. A documented fact's
    /// `present` is Apple's table, not a kernel reading; an inferred fact's is the app's reasoning.
    public static func explanation(_ s: FactState, provenance: Provenance) -> String {
        switch provenance {
        case .measured, .unknown:
            return explanation(s)
        case .documented:
            switch s {
            case .present: return String(localized: "Apple's published table lists this protection for this chip family.", bundle: .module)
            case .notPresent: return String(localized: "Apple's published table does not list this protection for this chip family.", bundle: .module)
            default: return String(localized: "Apple has not documented this for this chip family, or does not tabulate it per chip.", bundle: .module)
            }
        case .inferred:
            switch s {
            case .present: return String(localized: "The app's reasoning supports this; the chain is shown below.", bundle: .module)
            case .notPresent: return String(localized: "The app's reasoning found a contradiction; the chain is shown below.", bundle: .module)
            default: return String(localized: "The app could not complete this inference; the reason is shown below.", bundle: .module)
            }
        }
    }

    /// The one-sentence meaning of a measured state, for detail views and VoiceOver.
    public static func explanation(_ s: FactState) -> String {
        switch s {
        case .present: return String(localized: "This kernel reports the feature as on.", bundle: .module)
        case .notPresent: return String(localized: "This kernel knows the key and reports the feature as off.", bundle: .module)
        case .value: return String(localized: "A value was read; it is not an on/off flag.", bundle: .module)
        case .keyAbsent: return String(localized: "This kernel has no such key, typically an older OS or a platform where the concept does not apply.", bundle: .module)
        case .restricted: return String(localized: "The sandbox or kernel refused the read.", bundle: .module)
        case .notApplicable: return String(localized: "The key is registered for another CPU architecture.", bundle: .module)
        case .error: return String(localized: "The read failed or the value could not be decoded.", bundle: .module)
        case .unknown: return String(localized: "Not determinable from what this device and Apple's documentation provide.", bundle: .module)
        }
    }
}

public enum ProvenanceStyle {
    public static func symbol(_ p: Provenance) -> String {
        switch p {
        case .measured: return "waveform.path.ecg"
        case .documented: return "doc.text"
        case .inferred: return "arrow.triangle.branch"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    public static func label(_ p: Provenance) -> String {
        switch p {
        case .measured: return String(localized: "Measured", bundle: .module)
        case .documented: return String(localized: "Documented", bundle: .module)
        case .inferred: return String(localized: "Inferred", bundle: .module)
        case .unknown: return String(localized: "Unknown", bundle: .module)
        }
    }

    public static func explanation(_ p: Provenance) -> String {
        switch p {
        case .measured: return String(localized: "Read from this device's kernel at runtime.", bundle: .module)
        case .documented: return String(localized: "Apple's published claim for this chip family, with its source and dates.", bundle: .module)
        case .inferred: return String(localized: "Derived by this app's reasoning; the chain is shown.", bundle: .module)
        case .unknown: return String(localized: "Neither measured, documented, nor inferable.", bundle: .module)
        }
    }

    /// The same, in a few characters for the watch: "Measured", "Apple, 2026-01-28".
    public static func shortSource(_ p: Provenance, source: FactSource?) -> String {
        switch p {
        case .measured: return String(localized: "Measured", bundle: .module)
        case .documented:
            if let source { return String(localized: "Apple, \(source.published)", bundle: .module) }
            return String(localized: "Apple", bundle: .module)
        case .inferred: return String(localized: "Inferred", bundle: .module)
        case .unknown: return String(localized: "Unknown", bundle: .module)
        }
    }

    /// Where an answer came from, in a sentence a non-specialist can use.
    public static func plainSource(_ p: Provenance, source: FactSource?) -> String {
        switch p {
        case .measured: return String(localized: "Measured on this device", bundle: .module)
        case .documented:
            if let source { return String(localized: "Apple's documentation, \(source.published)", bundle: .module) }
            return String(localized: "Apple's documentation", bundle: .module)
        case .inferred: return String(localized: "Inferred by this app", bundle: .module)
        case .unknown: return String(localized: "Not determinable", bundle: .module)
        }
    }
}

/// Verdict words share one look everywhere (SPEC §6.4): a glyph, the word, and a tint that is
/// never the only signal. "No" and "Unknown" stay neutral: an older chip that lacks a protection
/// is a fact, not an alarm.
public enum VerdictStyle {
    public static func symbol(_ level: TopicVerdict.Level) -> String {
        switch level {
        case .yes: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .no: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    public static func tint(_ level: TopicVerdict.Level) -> Color {
        switch level {
        case .yes: return .green
        case .partial: return .orange
        case .no: return .secondary
        case .unknown: return .secondary
        }
    }

    /// Lower-case word for tallies ("5 yes, 1 partial").
    public static func word(_ level: TopicVerdict.Level) -> String {
        switch level {
        case .yes: return String(localized: "yes", bundle: .module)
        case .partial: return String(localized: "partial", bundle: .module)
        case .no: return String(localized: "no", bundle: .module)
        case .unknown: return String(localized: "unknown", bundle: .module)
        }
    }

    public static let order: [TopicVerdict.Level] = [.yes, .partial, .no, .unknown]
}

/// Capsule badge: glyph plus text on a soft tint. Used for provenance and for verdicts so the two
/// kinds of badge read as one family.
struct CapsuleBadge: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

public struct ProvenanceBadge: View {
    let provenance: Provenance
    public init(_ provenance: Provenance) { self.provenance = provenance }

    public var body: some View {
        CapsuleBadge(text: ProvenanceStyle.label(provenance), symbol: ProvenanceStyle.symbol(provenance), tint: .secondary)
            .accessibilityLabel(Text("\(ProvenanceStyle.label(provenance)). \(ProvenanceStyle.explanation(provenance))"))
    }
}

/// Verdict word with a glyph; never color alone.
public struct VerdictBadge: View {
    let verdict: TopicVerdict
    public init(_ verdict: TopicVerdict) { self.verdict = verdict }

    public var body: some View {
        CapsuleBadge(text: verdict.word, symbol: VerdictStyle.symbol(verdict.level), tint: VerdictStyle.tint(verdict.level))
    }
}

public struct StateGlyph: View {
    let state: FactState
    public init(_ state: FactState) { self.state = state }

    public var body: some View {
        Image(systemName: StateStyle.symbol(state))
            .foregroundStyle(StateStyle.tint(state))
            .imageScale(.large)
            .accessibilityHidden(true)   // the row carries the text label
    }
}

/// A symbol on a soft rounded tile, the way Settings marks its rows. One fixed size per platform
/// so every row's text starts on the same column.
struct IconTile: View {
    let symbol: String
    var tint: Color = .accentColor

    private var side: CGFloat {
        #if os(watchOS)
        28
        #elseif os(tvOS)
        56
        #else
        36
        #endif
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .imageScale(.medium)
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}
