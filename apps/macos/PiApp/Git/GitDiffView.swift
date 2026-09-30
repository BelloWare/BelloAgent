import SwiftUI
import AppKit

// Drawing a diff: its heading, and the unified or side-by-side cards the
// hunks become (`GitDiffTable`). A commit's file chips are `GitFileChips`.

/// The diff's layout and its whole-diff gate. Only the diff observes them.
@MainActor final class GitDiffPresentation: ObservableObject {
    @Published var split = false
    /// Which diff the reader asked to see in full. It names the diff, so the
    /// row gate comes back for the next file or commit.
    @Published var whole: String?
}

/// A diff that follows its presentation: the layout and the gate change it,
/// and nothing else around it is drawn again.
struct GitDiffPane<Content: View>: View {
    @ObservedObject var presentation: GitDiffPresentation
    @ViewBuilder let content: (_ split: Binding<Bool>, _ expanded: Binding<String?>) -> Content
    var body: some View { content($presentation.split, $presentation.whole) }
}

/// Unified or side-by-side diff rendered as file cards with hunk headers,
/// old/new line numbers and tinted added/removed rows. The heading is SwiftUI;
/// the cards are a native table (`GitDiffTable`), and the heading scrolls
/// away with them in its first row.
struct DiffView: View {
    let files: [GitDiffFile]
    let title: String?
    let subtitle: String?
    /// Names the diff on screen: the file selected, or the commit and the file
    /// chosen inside it. The "whole diff" gate is remembered against it.
    let identity: String
    var loading = false
    var embedded = false
    /// What scrolls above the heading: a commit's own header. `leadKey`
    /// changes whenever its height may.
    var lead: AnyView? = nil
    var leadKey: AnyHashable = 0
    @Binding var split: Bool
    /// The diff the reader asked to see in full, by identity. Held by the
    /// controller, so choosing another file or commit closes the gate again.
    @Binding var expanded: String?
    @State private var wrap = false
    private static let rowLimit = GitDiffMetrics.rowLimit
    private var showAll: Bool { expanded == identity }

    var body: some View {
        GitDiffTable(files: files, split: split, wrap: wrap, showAll: showAll, identity: identity,
                     top: AnyView(top), topKey: TopKey(title: title, subtitle: subtitle, loading: loading, empty: files.isEmpty, embedded: embedded, lead: leadKey),
                     topHeightKey: TopHeightKey(title: title != nil, subtitle: subtitle != nil, note: files.isEmpty && !loading, embedded: embedded, lead: leadKey),
                     loading: loading, more: more)
            .background(Color.piContent)
    }

    private struct TopKey: Hashable {
        let title: String?, subtitle: String?, loading: Bool, empty: Bool, embedded: Bool, lead: AnyHashable
    }
    /// What the heading's height depends on: its title and subtitle are one
    /// line each whatever they say, and the spinner is shorter than the tabs.
    private struct TopHeightKey: Hashable {
        let title: Bool, subtitle: Bool, note: Bool, embedded: Bool, lead: AnyHashable
    }

    /// Counted from what the parser already totalled, not by walking the lines again.
    private var totalRows: Int { files.reduce(0) { $0 + $1.lineCount } }

    /// The lead, the heading and "No textual changes.", 12 points apart, as
    /// the cards' stack had them. PiSheet's styles, which a hosted view does
    /// not inherit, are set again.
    private var top: some View {
        VStack(alignment: .leading, spacing: PiSpacing.md) {
            if let lead { lead }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(PiFont.heading).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                    if let subtitle { Text(subtitle).font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                }
                Spacer()
                if loading { PiSpinner(controlSize: .small) }
                PiTabs(selection: $split, items: [(false, "Unified"), (true, "Split")]).accessibilityIdentifier("git-diff-layout")
                Toggle("Wrap", isOn: $wrap).toggleStyle(.piSwitch).controlSize(.mini).font(PiFont.micro)
            }.padding(.horizontal, PiSpacing.lg).padding(.top, embedded ? 0 : PiSpacing.lg)
            if files.isEmpty && !loading {
                Text("No textual changes.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(.horizontal, PiSpacing.lg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .foregroundStyle(Color.piInk)
        .buttonStyle(.piSecondary)
        .toggleStyle(.piSwitch)
    }

    private var more: AnyView? {
        guard totalRows > Self.rowLimit && !showAll else { return nil }
        let identity = identity, expanded = $expanded
        return AnyView(
            Button("Show the whole diff") { expanded.wrappedValue = identity }.buttonStyle(.piSecondaryCompact).padding(.horizontal, PiSpacing.lg)
                .accessibilityIdentifier("git-diff-show-all")
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .foregroundStyle(Color.piInk)
        )
    }
}
