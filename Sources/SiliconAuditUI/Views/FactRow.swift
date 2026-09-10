import SiliconAuditCore
import SwiftUI

/// One fact in a list: glyph, name, state label, provenance badge. Tapping opens the detail.
public struct FactRow: View {
    let fact: Fact
    public init(_ fact: Fact) { self.fact = fact }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StateGlyph(fact.state)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(fact.displayName ?? fact.id)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(StateStyle.label(fact.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let short = FactRow.shortValue(fact) {
                        Text(short)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            ProvenanceBadge(fact.provenance)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(fact.displayName ?? fact.id))
        .accessibilityValue(Text("\(StateStyle.label(fact.state)), \(ProvenanceStyle.label(fact.provenance))"))
        .accessibilityHint(Text(String(localized: "Opens the raw reading and its provenance.", bundle: .module)))
    }

    /// A short inline rendering of a non-flag value.
    static func shortValue(_ f: Fact) -> String? {
        guard f.state == .value, let raw = f.raw else { return nil }
        switch raw.value {
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .string(let s): return s
        case nil: return raw.valueHex.map { "0x" + String($0.prefix(16)) + ($0.count > 16 ? "…" : "") }
        }
    }
}
