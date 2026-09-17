import SiliconAuditCore
import SwiftUI

/// One fact in a list: state glyph, name, then "state · provenance" on one quiet line, with a
/// short value at the trailing edge for non-flag readings. Every row shares the same columns.
public struct FactRow: View {
    let fact: Fact
    public init(_ fact: Fact) { self.fact = fact }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StateGlyph(fact.state)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.displayName ?? fact.id)
                    .font(.body)
                Text("\(StateStyle.label(fact.state, provenance: fact.provenance)) · \(Image(systemName: ProvenanceStyle.symbol(fact.provenance))) \(ProvenanceStyle.label(fact.provenance))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let short = FactRow.shortValue(fact) {
                Spacer(minLength: 12)
                Text(short)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(fact.displayName ?? fact.id))
        .accessibilityValue(Text("\(StateStyle.label(fact.state, provenance: fact.provenance)), \(ProvenanceStyle.label(fact.provenance))\(FactRow.shortValue(fact).map { ", \($0)" } ?? "")"))
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
