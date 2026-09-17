import SiliconAuditCore
import SwiftUI

/// The headline card (SPEC §6.4). Leads with what a person recognizes: the chip, the device, the
/// OS, and how the plain-language checks below came out. The inference chain, core family, and
/// collection method live one tap away in `MeasurementView`, so the card never opens with jargon.
public struct SummaryCard: View {
    let report: Report
    let tally: [TopicVerdict.Level: Int]

    public init(report: Report, tally: [TopicVerdict.Level: Int]) {
        self.report = report
        self.tally = tally
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: deviceSymbol)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SummaryCard.chipTitle(for: report))
                        .font(.title2.weight(.semibold))
                    Text(deviceLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let note = chipNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            if !tally.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { tallyLabels }
                        VStack(alignment: .leading, spacing: 6) { tallyLabels }
                    }
                    Text(tallyCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
    }

    private var tallyLabels: some View {
        ForEach(VerdictStyle.order.filter { (tally[$0] ?? 0) > 0 }, id: \.self) { level in
            Label {
                Text("\(tally[level] ?? 0) \(VerdictStyle.word(level))")
                    .monospacedDigit()
            } icon: {
                Image(systemName: VerdictStyle.symbol(level))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(VerdictStyle.tint(level))
        }
    }

    private var tallyCaption: String {
        let total = tally.values.reduce(0, +)
        return String(localized: "How the \(total) checks below came out. Tap any of them for the facts behind it.", bundle: .module)
    }

    /// The chip when the app could name it, otherwise the device: never a made-up name.
    static func chipTitle(for report: Report) -> String {
        let device = report.device
        if device.socId != nil, device.socInferenceConfidence != "none" {
            return stripParenthetical(device.socNameInferred)
        }
        return device.identity
    }

    private var deviceLine: String {
        var parts: [String] = []
        if SummaryCard.chipTitle(for: report) != report.device.identity { parts.append(report.device.identity) }
        parts.append("\(report.environment.platform) \(report.environment.osVersion) (\(report.environment.osBuild))")
        return parts.joined(separator: " · ")
    }

    /// A note under the device line when the chip could not be named.
    private var chipNote: String? {
        let device = report.device
        if device.socId == nil {
            return report.environment.arch == "x86_64"
                ? String(localized: "Intel processor: Apple's chip documentation does not apply.", bundle: .module)
                : String(localized: "The kernel names no Apple silicon target for this device.", bundle: .module)
        }
        if device.socInferenceConfidence == "none" {
            return String(localized: "Chip \(device.socId ?? "") is not in this app's map yet.", bundle: .module)
        }
        return nil
    }

    private var deviceSymbol: String {
        switch report.environment.platform {
        case "iOS": return "iphone"
        case "iPadOS": return "ipad"
        case "macOS": return "desktopcomputer"
        case "watchOS": return "applewatch"
        case "tvOS": return "appletv"
        case "visionOS": return "visionpro"
        default: return "cpu"
        }
    }

    /// "Apple M5 (Pro/Max die; marketing tier unverified)" → "Apple M5". The qualifier is shown in
    /// full on the measurement screen.
    static func stripParenthetical(_ s: String) -> String {
        guard let open = s.firstIndex(of: "(") else { return s }
        return s[..<open].trimmingCharacters(in: .whitespaces)
    }
}

/// Liquid Glass on OS 26, a material elsewhere. tvOS has no glassEffect and visionOS marks it
/// unavailable (its windows are already glass, and a material is the platform's card idiom), so
/// both always use the material. Kept as a modifier so it is the one place the check lives.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS) || os(visionOS)
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        #else
        if #available(iOS 26, macOS 26, watchOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        #endif
    }
}
