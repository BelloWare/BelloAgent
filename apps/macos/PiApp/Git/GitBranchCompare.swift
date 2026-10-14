import AppKit
import GitView

/// Comparisons keep resolved OIDs across pages. Their rows use the same
/// content component as History; selecting one never changes commit scope.
@MainActor final class GitBranchCompare: NSView {
    private let currentLabel = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let targetLabel = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    let currentList = LazyStackView(), targetList = LazyStackView()
    let more = PiKit.Button("Load More", style: .secondary, compact: true)
    let note = PiKit.TextLine(PiKit.Line("Reading comparison…", font: PiKit.Font.caption, color: .piInkSecondary))
    private let rule = HairlineView()
    private var task: Task<Void, Never>?
    private var comparison: GitBranchComparison?
    private var ours: [GitCommit] = [], theirs: [GitCommit] = []
    private let service: GitService, root: String, branch: GitBranchReference
    private let valid: () -> Bool
    private var page = 0
    init(service: GitService, root: String, branch: GitBranchReference, valid: @escaping () -> Bool) {
        self.service = service; self.root = root; self.branch = branch; self.valid = valid
        super.init(frame: .zero)
        for list in [currentList, targetList] { list.insets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12); list.spacing = 3 }
        for view in [currentLabel, targetLabel, currentList, targetList, rule, note, more] as [NSView] { addSubview(view) }
        more.onPress = { [weak self] in self?.load() }; more.isEnabled = false
        currentLabel.truncation = .middle; targetLabel.truncation = .middle
        load()
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }
    override var isFlipped: Bool { true }
    func cancel() { task?.cancel(); task = nil }
    private var wasAttached = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { wasAttached = true } else if wasAttached { cancel() }
    }
    private func load() {
        guard task == nil, valid() else { return }
        more.isEnabled = false
        task = Task { [weak self, service, root, branch, comparison, page] in
            do {
                let result: GitBranchComparison
                if let comparison { result = try await service.compareBranch(branch, current: comparison.current, in: root, skip: page * 50) }
                else { result = try await service.compareBranch(branch, in: root) }
                guard let self, !Task.isCancelled, valid() else { return }
                self.comparison = result; ours += result.onlyCurrent; theirs += result.onlyTarget; self.page += 1
                currentLabel.line.text = "Only in current · \(result.currentCount)"
                targetLabel.line.text = "Only in \(branch.name) · \(result.targetCount)"
                currentLabel.toolTip = result.current.ref ?? "Detached HEAD"
                targetLabel.toolTip = branch.ref
                note.line.text = "\(result.current.oid.prefix(8)) ↔ \(branch.oid.prefix(8)) · read only"
                show(ours, in: currentList); show(theirs, in: targetList)
                more.isEnabled = ours.count < result.currentCount || theirs.count < result.targetCount
                task = nil; needsLayout = true
            } catch {
                guard let self, !Task.isCancelled, valid() else { return }
                note.line.text = error.localizedDescription; note.toolTip = error.localizedDescription
                task = nil; more.isEnabled = true
            }
        }
    }
    private func show(_ commits: [GitCommit], in list: LazyStackView) {
        if commits.isEmpty {
            list.reload(.init(count: 1, key: { _ in "empty" }, height: { _, _ in 48 }, view: { _, _ in
                PiKit.TextLine(PiKit.Line("No unique commits", font: PiKit.Font.body, color: .piInkTertiary))
            })); return
        }
        list.reload(.init(count: commits.count, key: { commits[$0].hash }, height: { index, width in
            GitCommitRowView.height(of: commits[index], width: width)
        }, view: { index, existing in
            let row = (existing as? GitCompareCommitRow) ?? GitCompareCommitRow()
            row.show(commits[index]); return row
        }))
    }
    override func layout() {
        super.layout()
        let width = bounds.width, height = max(0, bounds.height - 44)
        if width >= 640 {
            let half = (width - 1) / 2
            currentLabel.frame = CGRect(x: 16, y: 12, width: max(0, half - 32), height: 20)
            targetLabel.frame = CGRect(x: half + 17, y: 12, width: max(0, half - 32), height: 20)
            currentList.frame = CGRect(x: 0, y: 38, width: half, height: max(0, height - 38))
            targetList.frame = CGRect(x: half + 1, y: 38, width: half, height: max(0, height - 38))
            rule.frame = CGRect(x: half, y: 0, width: 1, height: height)
        } else {
            let half = height / 2
            currentLabel.frame = CGRect(x: 16, y: 8, width: max(0, width - 32), height: 20)
            targetLabel.frame = CGRect(x: 16, y: half + 8, width: max(0, width - 32), height: 20)
            currentList.frame = CGRect(x: 0, y: 32, width: width, height: max(0, half - 32))
            targetList.frame = CGRect(x: 0, y: half + 32, width: width, height: max(0, half - 32))
            rule.frame = CGRect(x: 0, y: half, width: width, height: 1)
        }
        more.frame = CGRect(x: max(0, width - 114), y: height + 8, width: 100, height: 28)
        note.frame = CGRect(x: 16, y: height + 13, width: max(0, width - 140), height: 18)
    }
}

@MainActor private final class GitCompareCommitRow: NSView {
    private let content = GitCommitRowContent()
    init() { super.init(frame: .zero); addSubview(content); setAccessibilityElement(true); setAccessibilityRole(.staticText) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); content.frame = bounds.insetBy(dx: 8, dy: 5) }
    func show(_ commit: GitCommit) { content.apply(commit); setAccessibilityLabel(content.spokenText); toolTip = commit.hash + "\n" + commit.subject }
}
