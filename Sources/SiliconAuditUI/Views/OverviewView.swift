import SiliconAuditCore
import SwiftUI

/// The plain-language mode (SPEC §6.4): one card per topic with a verdict word, one sentence,
/// and where the answer came from. Tapping a card lists the facts behind it.
public struct OverviewList: View {
    let report: Report
    public init(report: Report) { self.report = report }

    public var body: some View {
        ForEach(Topic.all) { topic in
            let verdict = topic.verdict(in: report)
            NavigationLink {
                TopicDetailView(topic: topic, verdict: verdict, report: report)
            } label: {
                TopicRow(topic: topic, verdict: verdict)
            }
        }
    }
}

struct TopicRow: View {
    let topic: Topic
    let verdict: TopicVerdict

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: topic.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(topic.title).font(.headline)
                    Spacer()
                    VerdictBadge(verdict)
                }
                Text(verdict.sentence)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(sourceLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(topic.title))
        .accessibilityValue(Text("\(verdict.word). \(verdict.sentence) \(sourceLine)"))
    }

    var sourceLine: String {
        switch verdict.provenance {
        case .measured: return String(localized: "Measured on this device", bundle: .module)
        case .documented:
            if let s = verdict.source { return String(localized: "Apple's documentation, published \(s.published)", bundle: .module) }
            return String(localized: "Apple's documentation", bundle: .module)
        case .inferred: return String(localized: "Inferred by this app", bundle: .module)
        case .unknown: return String(localized: "Not determinable", bundle: .module)
        }
    }
}

/// Verdict word with a glyph; never color alone.
struct VerdictBadge: View {
    let verdict: TopicVerdict
    init(_ v: TopicVerdict) { verdict = v }

    var body: some View {
        Label(verdict.word, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
    }

    var symbol: String {
        switch verdict.level {
        case .yes: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .no: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch verdict.level {
        case .yes: return .green
        case .partial: return .orange
        case .no: return .secondary
        case .unknown: return .secondary
        }
    }
}

/// What the topic means, then the facts that decided it.
struct TopicDetailView: View {
    let topic: Topic
    let verdict: TopicVerdict
    let report: Report

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: topic.symbol).font(.title).foregroundStyle(.tint)
                        Spacer()
                        VerdictBadge(verdict)
                    }
                    Text(verdict.sentence).font(.body)
                    Text(topic.plain).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            Section {
                HStack {
                    ProvenanceBadge(verdict.provenance)
                    Text(ProvenanceStyle.explanation(verdict.provenance)).font(.subheadline).foregroundStyle(.secondary)
                }
                if let s = verdict.source {
                    if let url = URL(string: s.url) {
                        Link(destination: url) { Label(String(localized: "Read Apple's page", bundle: .module), systemImage: "safari") }
                    }
                    LabeledContent(String(localized: "Published", bundle: .module), value: s.published)
                    LabeledContent(String(localized: "Last verified by this app", bundle: .module), value: s.verified)
                }
            } header: {
                Text(String(localized: "Where this comes from", bundle: .module))
            }
            Section(String(localized: "The facts behind it", bundle: .module)) {
                ForEach(topic.factIDs, id: \.self) { id in
                    if let fact = report.facts.first(where: { $0.id == id }) {
                        NavigationLink { FactDetailView(fact) } label: { FactRow(fact) }
                    }
                }
            }
        }
        .navigationTitle(topic.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
