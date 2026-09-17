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
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(topic.title))
            .accessibilityValue(Text("\(verdict.word). \(verdict.sentence) \(ProvenanceStyle.plainSource(verdict.provenance, source: verdict.source))"))
    }

    @ViewBuilder
    private var content: some View {
        #if os(watchOS)
        // 40–46mm: no tile, the symbol sits in the title line, the verdict and a short source
        // share one line, and the sentence gets three lines at most.
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: topic.symbol).font(.caption).foregroundStyle(.tint).accessibilityHidden(true)
                Text(topic.title).font(.headline).lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    VerdictBadge(verdict).fixedSize()
                    shortSource.lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    VerdictBadge(verdict).fixedSize()
                    shortSource
                }
            }
            Text(verdict.sentence).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(.vertical, 2)
        #else
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: topic.symbol)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(topic.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                // Verdict and source side by side when they fit, stacked when they do not; the
                // verdict itself never truncates.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) {
                        VerdictBadge(verdict).fixedSize()
                        sourceText.lineLimit(1)
                    }
                    stackedVerdict
                }
                Text(verdict.sentence)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        #endif
    }

    #if os(watchOS)
    private var shortSource: some View {
        Text(ProvenanceStyle.shortSource(verdict.provenance, source: verdict.source))
            .font(.caption2).foregroundStyle(.secondary)
    }
    #endif

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
