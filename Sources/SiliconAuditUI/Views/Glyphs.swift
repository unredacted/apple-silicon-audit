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

    /// The one-sentence meaning of a state, for detail views and VoiceOver.
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
}

/// Compact capsule badge with icon and text.
public struct ProvenanceBadge: View {
    let provenance: Provenance
    public init(_ provenance: Provenance) { self.provenance = provenance }

    public var body: some View {
        Label(ProvenanceStyle.label(provenance), systemImage: ProvenanceStyle.symbol(provenance))
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(Text("\(ProvenanceStyle.label(provenance)). \(ProvenanceStyle.explanation(provenance))"))
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
