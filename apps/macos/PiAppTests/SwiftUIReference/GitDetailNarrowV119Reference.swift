import AppKit
import SwiftUI
@testable import PiApp
@testable import GitView

// Frozen selected-commit layout from e59e41a7 GitPanel.swift/GitDiffView.swift.
// The card renderer was already native in 0.1.119. Reuse that renderer, but
// preserve the original plain NSScrollView representable factory (including
// the absence of sizeThatFits) and the original hosted SwiftUI heading.
// Neither native DiffView nor native panel sizing participates in this oracle.
@MainActor struct GitPanelDetailNarrowV119Reference: View {
    @ObservedObject var controller: GitController

    var body: some View {
        if let detail = controller.detail {
            if controller.detailDiffDeferred {
                ScrollView {
                    VStack(alignment: .leading, spacing: PiSpacing.md) {
                        commitHeader(detail)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("This commit changes \(detail.summary). Its files are listed above; open one to read its diff.")
                                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                            Button("Show the whole diff") {}.buttonStyle(.piSecondaryCompact)
                        }.padding(.horizontal, PiSpacing.lg)
                    }
                }
            } else {
                let file = controller.detailFile
                let files = file == nil ? controller.detailDiff : controller.detailFileDiff
                let note = controller.revealNote
                let lead = AnyView(commitHeader(detail, note: note).foregroundStyle(Color.piInk).buttonStyle(.piSecondary).toggleStyle(.piSwitch))
                let leadKey = CommitHeaderKey(commit: detail.commit.hash, files: detail.files.count, selected: file,
                                              shown: controller.commitFilesShown, note: note)
                let identity = GitController.diffIdentity(commit: detail.commit.hash, file: file)
                DiffNarrowV119Reference(files: files, title: file, subtitle: file == nil ? nil : "In \(detail.commit.shortHash)",
                                       identity: identity, loading: controller.commitLoading, embedded: true, lead: lead, leadKey: leadKey,
                                       split: controller.presentation.split, expanded: controller.presentation.whole)
            }
        } else {
            Text(controller.commitLoading ? "Loading…" : "Select a commit to see what it changed.")
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func commitHeader(_ detail: GitCommitDetail, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.commit.subject).font(PiFont.title(17)).foregroundStyle(Color.piInk)
            Text("\(detail.commit.author) · \(detail.commit.date.formatted(date: .abbreviated, time: .shortened)) · \(detail.commit.hash)")
                .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textSelection(.enabled)
            if detail.message.contains("\n") {
                Text(detail.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst()
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(PiFont.body).foregroundStyle(Color.piInkSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if detail.commit.parents.count > 1 && detail.files.isEmpty {
                PiBadge(text: "Merge · first parent", tone: .info, icon: "arrow.triangle.merge")
            }
            if let note {
                Label(note, systemImage: "info.circle").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !detail.files.isEmpty {
                HStack(spacing: 8) {
                    Text(detail.summary).font(PiFont.micro.monospacedDigit()).foregroundStyle(Color.piInkSecondary)
                    if detail.commit.parents.count > 1 { PiBadge(text: "Merge · first parent", tone: .info, icon: "arrow.triangle.merge") }
                }
                CommitFileChipsNarrowV119Reference(detail: detail, selected: controller.detailFile, shown: controller.commitFilesShown)
            }
        }.padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.lg)
    }
    private struct CommitHeaderKey: Hashable { let commit: String, files: Int, selected: String?, shown: Int, note: String? }
}

@MainActor private struct CommitFileChipsNarrowV119Reference: NSViewRepresentable {
    let detail: GitCommitDetail
    let selected: String?
    let shown: Int
    func makeNSView(context: Context) -> GitFileChipsView { let view = GitFileChipsView(); update(view); return view }
    func updateNSView(_ view: GitFileChipsView, context: Context) { update(view) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitFileChipsView, context: Context) -> CGSize? {
        let width = proposal.width.map { $0.isFinite ? $0 : nsView.naturalWidth } ?? nsView.naturalWidth
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
    private func update(_ view: GitFileChipsView) {
        let files = detail.files.count <= shown ? detail.files[...] : detail.files[..<shown]
        var chips: [GitFileChip] = [GitFileChip(kind: .all, text: "All \(detail.files.count) files", icon: selected == nil ? "checkmark" : nil)]
        for file in files {
            let stat = detail.stats[file.path]
            let counts = stat.map { $0.binary ? " · binary" : " · +\($0.added) −\($0.removed)" } ?? ""
            let tone: PiTone = selected == file.path ? .accent : file.badge == "D" ? .danger : file.badge == "A" ? .success : .neutral
            chips.append(GitFileChip(kind: .file(file.path), text: "\(file.badge) \((file.path as NSString).lastPathComponent)" + counts,
                                     help: file.path + counts, tone: tone))
        }
        if detail.files.count > shown { chips.append(GitFileChip(kind: .more, text: "\(detail.files.count - shown) more files", icon: "ellipsis")) }
        view.show(chips, press: { _ in }, history: { _ in })
    }
}

@MainActor private struct DiffNarrowV119Reference: View {
    let files: [GitDiffFile]
    let title: String?, subtitle: String?, identity: String
    let loading: Bool, embedded: Bool
    let lead: AnyView
    let leadKey: AnyHashable
    let split: Bool
    let expanded: String?
    @State private var wrap = false
    private var showAll: Bool { expanded == identity }

    var body: some View {
        DiffTableNarrowV119Reference(files: files, split: split, wrap: wrap, showAll: showAll, identity: identity,
                                     top: AnyView(top), topHeightKey: TopHeightKey(title: title != nil, subtitle: subtitle != nil,
                                         note: files.isEmpty && !loading, embedded: embedded, lead: leadKey), loading: loading, more: more)
            .background(Color.piContent)
    }
    private struct TopHeightKey: Hashable { let title: Bool, subtitle: Bool, note: Bool, embedded: Bool, lead: AnyHashable }
    private var top: some View {
        VStack(alignment: .leading, spacing: PiSpacing.md) {
            lead
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(PiFont.heading).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                    if let subtitle { Text(subtitle).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1) }
                }
                Spacer()
                if loading { PiSpinner(controlSize: .small) }
                PiTabs(selection: .constant(split), items: [(false, "Unified"), (true, "Split")])
                Toggle("Wrap", isOn: $wrap).toggleStyle(.piSwitch).controlSize(.mini).font(PiFont.micro)
            }.padding(.horizontal, PiSpacing.lg).padding(.top, embedded ? 0 : PiSpacing.lg)
            if files.isEmpty && !loading {
                Text("No textual changes.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(.horizontal, PiSpacing.lg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .foregroundStyle(Color.piInk).buttonStyle(.piSecondary).toggleStyle(.piSwitch)
    }
    private var more: AnyView? {
        guard files.reduce(0, { $0 + $1.lineCount }) > GitDiffMetrics.rowLimit && !showAll else { return nil }
        return AnyView(Button("Show the whole diff") {}.buttonStyle(.piSecondaryCompact).padding(.horizontal, PiSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading).foregroundStyle(Color.piInk))
    }
}

// This factory is the e59e41a7 GitDiffTable.makeNSView implementation. Its
// sizing stays SwiftUI's default NSViewRepresentable sizing, exactly as
// released. The renderer consumes a hosted heading adapter, measured as
// the original Coordinator's NSHostingController was measured.
@MainActor private struct DiffTableNarrowV119Reference: NSViewRepresentable {
    let files: [GitDiffFile]
    let split: Bool, wrap: Bool, showAll: Bool
    let identity: String
    let top: AnyView
    let topHeightKey: AnyHashable
    let loading: Bool
    let more: AnyView?
    final class Coordinator {
        let table = GitDiffTable.Coordinator()
        let top = HostedDiffAccessoryNarrowV119Reference()
        let more = HostedDiffAccessoryNarrowV119Reference()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let table = GitDiffTableView()
        table.style = .plain
        table.headerView = nil; table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAutomaticRowHeights = false
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator.table; table.delegate = context.coordinator.table
        table.coordinator = context.coordinator.table
        table.setAccessibilityLabel("Diff"); table.setAccessibilityIdentifier("git-diff-table")
        scroll.documentView = table
        context.coordinator.table.table = table
        context.coordinator.table.observe(scroll)
        update(context.coordinator)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { update(context.coordinator) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.table.close()
        (scroll.documentView as? NSTableView)?.delegate = nil; (scroll.documentView as? NSTableView)?.dataSource = nil
    }
    private func update(_ coordinator: Coordinator) {
        coordinator.top.host.rootView = top
        if let more { coordinator.more.host.rootView = more }
        coordinator.table.schedule(GitDiffTable.Coordinator.State(files: files, split: split, wrap: wrap, showAll: showAll, identity: identity,
            top: coordinator.top, topHeightKey: topHeightKey, loading: loading, more: more == nil ? nil : coordinator.more,
            colors: .pi, menu: nil, reveal: nil, revealed: nil))
    }
}

@MainActor private final class HostedDiffAccessoryNarrowV119Reference: NSView, GitDiffAccessory {
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    init() {
        super.init(frame: .zero)
        // The released Coordinator disabled both hosting sizing options.
        host.sizingOptions = []; (host.view as? NSHostingView<AnyView>)?.sizingOptions = []
        host.view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(host.view)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); host.view.frame = bounds }
    func gitDiffHeight(forWidth width: CGFloat) -> CGFloat {
        host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
}
