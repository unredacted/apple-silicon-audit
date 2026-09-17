import SiliconAuditCore
import SwiftUI

/// The plain-language layer (SPEC §6.4): one row per topic with a verdict word, one sentence,
/// and where the answer came from. Tapping a row lists the facts behind it.
public struct OverviewList: View {
    let report: Report
    let scope: Topic.Scope
    public init(report: Report, scope: Topic.Scope = .device) {
        self.report = report
        self.scope = scope
    }

    /// Whether any topic of this scope has a fact to draw on in the report (imported or fixture
    /// reports may carry no self-test, and then the per-app section is not shown at all).
    public static func hasContent(_ scope: Topic.Scope, in report: Report) -> Bool {
        Topic.all.contains { topic in topic.scope == scope && topic.factIDs.contains { id in report.facts.contains { $0.id == id } } }
    }

    public var body: some View {
        ForEach(Topic.all.filter { $0.scope == scope }) { topic in
            let verdict = topic.verdict(in: report)
            NavigationLink {
                TopicDetailView(topic: topic, verdict: verdict, report: report)
            } label: {
                TopicRow(topic: topic, verdict: verdict)
            }
        }
    }
}

/// Title, then the verdict and its source, then the sentence. Everything hangs off one left
/// column so titles never fight a trailing badge for width.
struct TopicRow: View {
    let topic: Topic
    let verdict: TopicVerdict

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: topic.symbol)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(topic.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                // Verdict and source side by side when they fit, stacked when they do not; the
                // verdict itself never truncates. The watch is always too narrow for the pair.
                #if os(watchOS)
                stackedVerdict
                #else
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) {
                        VerdictBadge(verdict).fixedSize()
                        sourceText.lineLimit(1)
                    }
                    stackedVerdict
                }
                #endif
                Text(verdict.sentence)
                    .font(sentenceFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(topic.title))
        .accessibilityValue(Text("\(verdict.word). \(verdict.sentence) \(ProvenanceStyle.plainSource(verdict.provenance, source: verdict.source))"))
    }

    private var stackedVerdict: some View {
        VStack(alignment: .leading, spacing: 4) {
            VerdictBadge(verdict).fixedSize()
            sourceText.fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceText: some View {
        Text(ProvenanceStyle.plainSource(verdict.provenance, source: verdict.source))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var sentenceFont: Font {
        #if os(watchOS)
        .caption2
        #else
        .subheadline
        #endif
    }
}

/// What was found, what the protection is, where the answer came from, then the facts.
struct TopicDetailView: View {
    let topic: Topic
    let verdict: TopicVerdict
    let report: Report

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        IconTile(symbol: topic.symbol)
                        VerdictBadge(verdict)
                    }
                    Text(verdict.sentence)
                        .font(.body)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section {
                Text(topic.plain)
                    .font(.callout)
            } header: {
                Text(String(localized: "What it is", bundle: .module))
            }

            Section {
                HStack(alignment: .center, spacing: 12) {
                    ProvenanceBadge(verdict.provenance)
                    Text(ProvenanceStyle.explanation(verdict.provenance))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

            Section {
                ForEach(topic.factIDs, id: \.self) { id in
                    if let fact = report.facts.first(where: { $0.id == id }) {
                        NavigationLink { FactDetailView(fact) } label: { FactRow(fact) }
                    }
                }
            } header: {
                Text(String(localized: "The facts behind it", bundle: .module))
            } footer: {
                Text(String(localized: "Each fact opens to its raw reading.", bundle: .module))
            }
        }
        .navigationTitle(topic.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
