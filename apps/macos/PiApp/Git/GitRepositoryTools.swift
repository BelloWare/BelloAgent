import AppKit
import Combine
import GitView

/// Presentation lifetime and repository identity are separate from status
/// refreshes. The controller supplies the shared write admission for every
/// branch/stash action, including writes from detached Changes windows.
@MainActor final class GitRepositoryTools {
    let controller: GitController
    let service: GitService
    let questions = PiQuestion()
    private let popup = AnchoredPopover()
    private(set) var sheet: PiSheetWindow?
    private var formSheet: PiSheetWindow?
    private var observation: AnyCancellable?
    private var read: Task<Void, Never>?
    private var token = UUID()
    private(set) var identity: GitController.RepositoryIdentity?
    private weak var parent: NSWindow?
    private weak var anchor: NSView?
    private(set) var branches: GitBranchesPopover?
    private(set) var stashes: GitStashList?
    private var form: GitRepositoryForm?
    init(controller: GitController, service: GitService = .shared) {
        self.controller = controller; self.service = service
        observation = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Resolving another folder temporarily suspends write admission,
                // even when it belongs to this same repository. Keep its form
                // until identity changes; valid() still refuses unresolved writes.
                if self.identity != nil && (controller.repositoryIdentity != self.identity || controller.suspended) { self.close() }
                self.branches?.busy = controller.busy; self.stashes?.busy = controller.busy
            }
        }
        popup.onClose = { [weak self] in self?.read?.cancel(); self?.read = nil }
    }
    deinit { read?.cancel() }
    func close() {
        token = UUID(); read?.cancel(); read = nil
        if questions.asking, let host = questions.askedIn, let asked = host.attachedSheet {
            host.endSheet(asked, returnCode: .alertSecondButtonReturn); asked.orderOut(nil)
        }
        questions.cancel(); popup.close()
        stashes?.cancel(); sheet?.end(animated: false, requested: true); formSheet?.end(animated: false, requested: true)
        sheet = nil; formSheet = nil; branches = nil; stashes = nil; form = nil; identity = nil
    }
    private func begin(from anchor: NSView) -> Bool {
        close()
        guard let identity = controller.repositoryIdentity, controller.acceptsRepository(identity), !controller.busy, let window = anchor.window else { return false }
        self.identity = identity; parent = window; self.anchor = anchor
        return true
    }
    private func valid(_ token: UUID, _ identity: GitController.RepositoryIdentity) -> Bool {
        self.token == token && self.identity == identity && controller.acceptsRepository(identity) && parent != nil
    }
    func showBranches(from anchor: NSView) {
        guard begin(from: anchor), let identity else { return }
        let view = GitBranchesPopover(), token = token
        branches = view
        view.cancel = { [weak self] in self?.close() }
        view.createFromHead = { [weak self] in self?.nameBranch(nil, rename: false, tracking: false) }
        view.action = { [weak self] action, branch in self?.branchAction(action, branch: branch) }
        popup.show(view, width: min(420, max(280, (parent?.contentView?.bounds.width ?? 444) - 24)), below: anchor, focus: view.search.field)
        read = Task { [weak self, service] in
            do {
                let catalog = try await service.branchCatalog(in: identity.root)
                guard let self, !Task.isCancelled, valid(token, identity) else { return }
                view.show(catalog); read = nil
            } catch {
                guard let self, !Task.isCancelled, valid(token, identity) else { return }
                view.setNotice(error.localizedDescription); read = nil
            }
        }
    }
    func branchAction(_ action: GitBranchesPopover.Action, branch: GitBranchReference) {
        guard let identity, valid(token, identity), !controller.busy else { return }
        switch action {
        case .checkout:
            if branch.remote != nil { nameBranch(branch, rename: false, tracking: true) }
            else { Task { await checkout(branch) } }
        case .newBranch: nameBranch(branch, rename: false, tracking: false)
        case .rename: nameBranch(branch, rename: true, tracking: false)
        case .delete: Task { await delete(branch) }
        case .compare: showComparison(branch)
        case .history:
            close(); controller.showBranchHistory(branch.ref, repository: identity)
        }
    }
    func checkout(_ branch: GitBranchReference, newName: String? = nil) async {
        guard let identity, let head = branches?.catalog?.head, valid(token, identity) else { return }
        let token = token
        do {
            let result = try await controller.performRepositoryWrite(repository: identity) { [service] root in
                try await service.checkoutBranch(branch, from: head, newName: newName, in: root)
            }
            guard valid(token, identity) else { return }
            showCheckout(result)
        } catch { if valid(token, identity) { showFailure(error.localizedDescription) } }
    }
    private func showCheckout(_ result: GitBranchCheckoutResult) {
        switch result {
        case .switched: close()
        case .needsStash(let obstruction):
            formSheet?.end(animated: false, requested: true); formSheet = nil; form = nil
            if let branches, let anchor, !popup.isShown { popup.show(branches, width: min(420, max(280, (parent?.contentView?.bounds.width ?? 444) - 24)), below: anchor) }
            branches?.offerRecovery(obstruction.reason) { [weak self] in Task { await self?.recoverCheckout(obstruction) } }
        }
    }
    func recoverCheckout(_ obstruction: GitCheckoutObstruction) async {
        guard let identity, valid(token, identity) else { return }
        let token = token
        do {
            let result = try await controller.performRepositoryWrite(repository: identity) { [service] root in try await service.stashAndCheckout(obstruction, in: root) }
            guard valid(token, identity) else { return }
            showCheckout(result)
        } catch { if valid(token, identity) { showFailure("The stash, if created, was kept. " + error.localizedDescription) } }
    }
    func delete(_ branch: GitBranchReference) async {
        guard let identity, let parent, valid(token, identity), !questions.asking else { return }
        let token = token
        do {
            let review = try await service.reviewBranchDeletion(branch, in: identity.root)
            guard valid(token, identity) else { return }
            popup.close()
            guard await questions.confirm("Delete branch \(branch.name)?", "Remove this local branch at \(branch.oid.prefix(8)). Working files and remote branches stay as they are.",
                                          action: "Delete Branch", destructive: true, cancelIsDefault: true, over: parent), valid(token, identity) else { return }
            if review.unmergedCount > 0 {
                let commits = review.commits.map { "\($0.shortHash)  \($0.subject)" }.joined(separator: "\n")
                let base = review.head.ref?.replacingOccurrences(of: "refs/heads/", with: "") ?? "detached HEAD"
                let detail = "\(review.unmergedCount) commits on \(branch.name) are not in \(base) (\(review.head.oid.prefix(8))). Deleting the branch removes its name and reflog; these commits may become unreachable.\n\n\(commits)" + (review.unmergedCount > review.commits.count ? "\n… and \(review.unmergedCount - review.commits.count) more." : "")
                guard await questions.confirm("Delete unmerged branch \(branch.name)?", detail, action: "Delete Unmerged Branch", destructive: true, cancelIsDefault: true, over: parent), valid(token, identity) else { return }
            }
            let result = try await controller.performRepositoryWrite(repository: identity) { [service] root in try await service.deleteBranch(review, allowUnmerged: review.unmergedCount > 0, in: root) }
            controller.reportRepositoryResult(result, repository: identity)
            if valid(token, identity) { close() }
        } catch { if valid(token, identity) { showFailure(error.localizedDescription) } }
    }
    private func nameBranch(_ branch: GitBranchReference?, rename: Bool, tracking: Bool) {
        guard let identity, let parent, valid(token, identity) else { return }
        let token = token, head = branches?.catalog?.head
        popup.close()
        let title = rename ? "Rename Branch" : tracking ? "New Tracking Branch" : "New Branch"
        let initial = rename ? branch?.name ?? "" : tracking ? String((branch?.name ?? "").dropFirst((branch?.remote?.count ?? 0) + 1)) : ""
        let detail = rename ? "Rename \(branch?.name ?? ""). Existing branches are never overwritten." : "Create from \(branch?.name ?? "HEAD") and check out. Git protects local changes."
        let view = GitRepositoryForm(placeholder: "feature/name", value: initial, detail: detail, action: rename ? "Rename" : "Create")
        form = view
        view.submit = { [weak self, weak view] in
            guard let self, let view, self.form === view, valid(token, identity) else { return }
            let name = view.field.text
            Task { [self] in
                do {
                    view.busy = true
                    if rename, let branch {
                        try await controller.renameBranch(branch, to: name, repository: identity)
                    } else if let branch, let head {
                        let result = try await controller.performRepositoryWrite(repository: identity) { [service] root in
                            try await service.checkoutBranch(branch, from: head, newName: name, in: root)
                        }
                        if valid(token, identity) { view.busy = false; showCheckout(result) }; return
                    } else {
                        // Retain creation on an unborn or detached HEAD too.
                        await controller.createBranch(name, repository: identity)
                        if !controller.notice.isEmpty { throw NSError(domain: controller.notice, code: 1, userInfo: [NSLocalizedDescriptionKey: controller.notice]) }
                    }
                    if valid(token, identity) { close() }
                } catch { if valid(token, identity) { view.busy = false; view.setNotice(error.localizedDescription) } }
            }
        }
        presentForm(view, title: title, parent: parent)
    }
    private func showComparison(_ branch: GitBranchReference) {
        guard let identity, let parent, valid(token, identity) else { return }
        popup.close(); let token = token
        let view = GitBranchCompare(service: service, root: identity.root, branch: branch, valid: { [weak self] in self?.valid(token, identity) == true })
        present(view, title: "Compare with Current", subtitle: branch.name, parent: parent)
    }
    func showStashes(from anchor: NSView) {
        guard begin(from: anchor), let identity, let parent else { return }
        let token = token
        let view = GitStashList(service: service, root: identity.root, valid: { [weak self] in self?.valid(token, identity) == true })
        stashes = view
        view.action = { [weak self] action, stash in Task { await self?.stashAction(action, stash: stash) } }
        let new = PiKit.Button("New Stash…", symbol: "plus", style: .secondary, compact: true) { [weak self, weak view] in
            guard let self, let window = view?.window else { return }; newStash(over: window)
        }
        present(view, title: "Stashes", subtitle: "Saved work in this repository", parent: parent, extra: [new])
    }
    func showNewStash(from anchor: NSView) { guard begin(from: anchor), let parent else { return }; newStash(over: parent) }
    private func newStash(over window: NSWindow) {
        guard let identity, valid(token, identity) else { return }
        let token = token
        let view = GitRepositoryForm(placeholder: "Message (optional)", detail: "Save local changes so they can be applied later.", action: "Stash", stashOptions: true)
        form = view
        view.submit = { [weak self, weak view] in
            guard let self, let view, self.form === view, valid(token, identity) else { return }
            let message = view.field.text, untracked = view.untracked.isOn, keep = view.keepIndex.isOn
            view.busy = true
            Task { [self] in
                do {
                    let result = try await controller.performRepositoryWrite(repository: identity) { [service] root in
                        try await service.createStash(message: message, includeUntracked: untracked, keepIndex: keep, in: root)
                    }
                    guard valid(token, identity) else { return }
                    formSheet?.end(animated: false, requested: true); formSheet = nil; form = nil
                    if let stashes { stashes.setNotice(result); stashes.reload(keepingNotice: true) } else { close() }
                } catch { if valid(token, identity) { view.busy = false; view.setNotice(error.localizedDescription) } }
            }
        }
        presentForm(view, title: "New Stash", parent: window)
    }
    func stashAction(_ action: GitStashList.Action, stash: GitStashRecord) async {
        guard let identity, valid(token, identity), !questions.asking else { return }
        let token = token
        do {
            if action == .drop {
                guard let window = stashes?.window ?? parent else { return }
                guard await questions.confirm("Drop \(stash.selector)?", "Permanently remove “\(stash.message)” from \(stash.branch), commit \(stash.oid.prefix(8)). Saved changes may become unrecoverable.", action: "Drop Stash", destructive: true, cancelIsDefault: true, over: window), valid(token, identity) else { return }
                try await controller.performRepositoryWrite(repository: identity) { [service] root in try await service.dropStash(stash, in: root) }
                if valid(token, identity) { stashes?.setNotice("Stash removed.") }
            } else {
                let pop = action == .pop
                let result = try await controller.performRepositoryWrite(repository: identity) { [service] root in try await service.applyStash(stash, pop: pop, in: root) }
                if valid(token, identity) { stashes?.setNotice(result.message) }
            }
            if valid(token, identity) { stashes?.reload(keepingNotice: true) }
        } catch { if valid(token, identity) { stashes?.setNotice(error.localizedDescription); stashes?.reload(keepingNotice: true) } }
    }
    private func present(_ view: NSView, title: String, subtitle: String?, parent: NSWindow, extra: [NSView] = []) {
        let width = min(1000, max(320, (parent.contentView?.bounds.width ?? 944) - 24))
        let height = min(650, max(380, (parent.contentView?.bounds.height ?? 620) - 40))
        let close = PiKit.Button("Close", style: .ghost, compact: true) { [weak self] in self?.close() }
        let content = PiKit.Sheet(title, subtitle: subtitle, symbol: "arrow.triangle.branch", content: view, actions: extra + [close])
        content.width = width; content.height = height; content.dismiss = { [weak self] in self?.close() }
        sheet = AppKitSheets.present(on: parent, size: NSSize(width: width, height: height)) { _ in content }
        let presentation = token
        sheet?.onEnded = { [weak self] _ in guard let self, self.token == presentation else { return }; self.close() }
    }
    private func presentForm(_ view: GitRepositoryForm, title: String, parent: NSWindow) {
        let width = min(460, max(300, (parent.contentView?.bounds.width ?? 484) - 24))
        let cancel = PiKit.Button("Cancel", style: .ghost, compact: true) { [weak self] in self?.cancelForm() }
        let content = PiKit.Sheet(title, symbol: "arrow.triangle.branch", content: view, actions: [cancel])
        content.width = width; content.height = 330; content.dismiss = { [weak self] in self?.cancelForm() }
        view.field.onCancel = { [weak self] in self?.cancelForm() }
        formSheet = AppKitSheets.present(on: parent, size: NSSize(width: width, height: 330)) { _ in content }
        view.window?.makeFirstResponder(view.field.field)
    }
    private func cancelForm() {
        formSheet?.end(animated: false, requested: true); formSheet = nil; form = nil
        if stashes == nil { close() }
    }
    private func showFailure(_ message: String) {
        if let form { form.setNotice(message); return }
        if let branches, let anchor {
            branches.setNotice(message)
            if !popup.isShown { popup.show(branches, width: min(420, max(280, (parent?.contentView?.bounds.width ?? 444) - 24)), below: anchor) }
        } else { stashes?.setNotice(message) }
    }
}

@MainActor final class GitRepositoryForm: NSView {
    let field: PiKit.TextField
    let untracked = PiKit.Checkbox(isOn: true, label: "Include untracked files")
    let keepIndex = PiKit.Checkbox(isOn: false, label: "Keep staged changes in the index")
    let button: PiKit.Button
    let note: TextBlock
    private let options: Bool
    var submit: (() -> Void)?
    var busy = false { didSet { button.isEnabled = !busy; field.field.isEnabled = !busy; untracked.isEnabled = !busy; keepIndex.isEnabled = !busy } }
    init(placeholder: String, value: String = "", detail: String, action: String, stashOptions: Bool = false) {
        field = PiKit.TextField(placeholder: placeholder, text: value, icon: "text.quote")
        button = PiKit.Button(action, style: .primary)
        note = TextBlock(detail, font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 5)
        options = stashOptions
        super.init(frame: .zero)
        field.field.setAccessibilityLabel(stashOptions ? "Stash message" : "Branch name")
        for view in [field, untracked, keepIndex, button, note] as [NSView] { addSubview(view) }
        untracked.isHidden = !options; keepIndex.isHidden = !options
        button.onPress = { [weak self] in guard let self, !busy else { return }; submit?() }
        field.onSubmit = { [weak self] in guard let self, !busy else { return }; submit?() }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func setNotice(_ value: String) { note.text = value; note.toolTip = value; needsLayout = true }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 32)
        field.frame = CGRect(x: 16, y: 16, width: width, height: 34)
        untracked.frame = CGRect(x: 16, y: 64, width: width, height: 22)
        keepIndex.frame = CGRect(x: 16, y: 94, width: width, height: 22)
        let y: CGFloat = options ? 130 : 64
        note.frame = CGRect(x: 16, y: y, width: width, height: min(88, note.height(forWidth: width)))
        button.frame = CGRect(x: 16, y: max(y + note.frame.height + 12, bounds.height - 48), width: min(width, button.fittingSize.width), height: 32)
    }
}
