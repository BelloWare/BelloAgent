import AppKit
import Combine
import GitView

/// One visible review owns a bounded snapshot. Its display can survive an
/// unrelated status refresh; permission to act always needs the newest index.
@MainActor final class GitHunkReview {
    private weak var controller: GitController?
    private let service: GitService
    private var observation: AnyCancellable?
    private var read: Task<Void, Never>?
    private var generation = 0
    private var input: Input?
    private var owner: Owner?
    private var reading = false
    private var externalBusy = false
    private var failureNotice: String?
    private var displayed: [GitDiffFile]?
    private var displayedRaw: Data?
    private var stagingOwner: Owner?
    private var stagedRepository: GitController.RepositoryIdentity?
    private(set) var review: GitPatchReview?
    private(set) var busy = false
    private(set) var message = ""
    private(set) var stagedPath: String?
    private(set) var revision = 0
    var changed: (() -> Void)?
    private struct Owner: Equatable {
        let repository: GitController.RepositoryIdentity?
        let selection: GitController.Selection?
    }
    private struct Input: Equatable {
        let context: GitController.RepositoryContext?
        let selection: GitController.Selection?
        let files: GitDiffArray
        let loading: Bool
    }
    init(controller: GitController, service: GitService = .shared) {
        self.controller = controller; self.service = service
        observation = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.synchronize() }
        }
    }
    deinit { read?.cancel() }
    private func publish() { revision &+= 1; changed?() }
    func suspend() {
        generation &+= 1; read?.cancel(); read = nil; review = nil; input = nil; reading = false
        owner = nil; displayed = nil; displayedRaw = nil; failureNotice = nil
        stagedPath = nil; stagedRepository = nil; message = ""
        publish()
    }
    func displayFiles(for identity: String) -> [GitDiffFile]? {
        guard let controller, let owner, controller.acceptsRepository(owner.repository),
              let selection = owner.selection, controller.selection == selection,
              identity == GitController.diffIdentity(path: selection.path, staged: selection.staged) else { return nil }
        return displayed
    }
    /// Keep the offer visible when the last unstaged hunk removes its row.
    var offerSelection: GitController.Selection? {
        let repository = stagedPath == nil ? stagingOwner?.repository : stagedRepository
        guard let path = stagedPath ?? (busy ? stagingOwner?.selection?.path : nil), controller?.acceptsRepository(repository) == true else { return nil }
        return GitController.Selection(path: path, staged: false)
    }
    func synchronize() {
        guard let controller, controller.panel == .changes, controller.accepts(controller.repositoryContext) else {
            if input != nil { suspend() }; return
        }
        let nextOwner = Owner(repository: controller.repositoryIdentity, selection: controller.selection)
        let ownerChanged = owner != nextOwner
        if ownerChanged {
            owner = nextOwner; displayed = nil; displayedRaw = nil; failureNotice = nil; message = ""
        }
        if !controller.acceptsRepository(stagedRepository) || (nextOwner.selection != nil && stagedPath != nextOwner.selection?.path) {
            stagedPath = nil; stagedRepository = nil
        }
        let next = Input(context: controller.repositoryContext, selection: controller.selection, files: GitDiffArray(controller.diff), loading: controller.diffLoading)
        guard next != input || ownerChanged else {
            if externalBusy != controller.busy { externalBusy = controller.busy; publish() }
            return
        }
        externalBusy = controller.busy
        generation &+= 1; read?.cancel(); read = nil
        input = next; review = nil; reading = false
        // A write keeps its captured snapshot, but navigation must release the
        // old visible review synchronously, even while that write is running.
        guard !busy else { publish(); return }
        guard let context = next.context, let selection = next.selection, !controller.diffLoading else {
            message = next.selection == nil ? "" : "Reading changes…"; publish(); return
        }
        message = "Checking hunk actions…"; reading = true; publish()
        let token = generation
        read = Task { [weak self, service] in
            do {
                let result = try await service.patchReview(in: context.root, path: selection.path, staged: selection.staged)
                guard let self, !Task.isCancelled, self.generation == token, controller.accepts(context), controller.selection == selection else { return }
                // Reuse the parsed array's storage when only the index/status
                // changed. Table selection is anchored to that display identity.
                if self.displayedRaw != result.patch.raw { self.displayed = result.files; self.displayedRaw = result.patch.raw }
                self.review = result; self.message = self.failureNotice ?? ""; self.reading = false; self.read = nil; self.publish()
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, controller.accepts(context), controller.selection == selection else { return }
                self.displayed = nil; self.displayedRaw = nil
                self.message = "Hunks unavailable. " + error.localizedDescription
                self.reading = false; self.read = nil; self.publish()
            }
        }
    }
    var enabled: Bool {
        guard let controller, let input else { return false }
        return !busy && !reading && !controller.busy && !controller.diffLoading && controller.accepts(input.context)
            && controller.selection == input.selection && review != nil
    }
    func activate(_ hunk: Int, reviewID: UUID) {
        guard enabled, let review, review.id == reviewID, let controller, let owner else { return }
        failureNotice = nil; stagingOwner = review.staged ? nil : owner
        busy = true; message = review.staged ? "Unstaging hunk…" : "Staging hunk…"; publish()
        // Keep an authorized operation alive through navigation, never replay it.
        Task { [self, service] in
            var failure: String?
            do { try await service.applyHunk(hunk, from: review) } catch { failure = error.localizedDescription }
            self.review = nil
            if controller.acceptsRepository(owner.repository) {
                if failure == nil, !review.staged, controller.panel == .changes, controller.selection == owner.selection || controller.selection == nil {
                    stagedPath = review.path; stagedRepository = owner.repository
                }
                await controller.refresh()
            }
            busy = false; stagingOwner = nil
            let stillOwned = controller.acceptsRepository(owner.repository) && controller.selection == owner.selection
            failureNotice = stillOwned ? failure : nil
            input = nil; synchronize()
            if stillOwned, let failure { message = failure; publish() }
        }
    }
    func reviewStaged() {
        guard !busy, let controller, let selection = offerSelection else { return }
        stagedPath = nil; stagedRepository = nil
        controller.panel = .changes
        controller.selection = GitController.Selection(path: selection.path, staged: true)
    }

    func control(_ location: GitDiffHunkLocation) -> NSView? {
        guard let review, Data(location.path.utf8) == Data(review.path.utf8), review.patch.hunks.indices.contains(location.hunk) else { return nil }
        let staged = review.staged, id = review.id, hunk = location.hunk
        let box = PiKit.Checkbox(isOn: staged, label: staged ? "Unstage hunk" : "Stage hunk")
        box.labelFont = PiKit.Font.micro
        box.isEnabled = enabled && location.fullyShown
        box.setAccessibilityIdentifier("git-hunk-\(hunk)")
        box.setAccessibilityLabel("\(box.label), change \(hunk + 1), \(review.path), \(review.patch.hunks[hunk].header)")
        box.toolTip = location.fullyShown ? "Only this hunk. Working file and commit scope stay as they are. Space activates."
            : "Show the whole diff to review this entire hunk before staging it."
        // Recycled cells must not retain whole index/blob snapshots.
        box.onChange = { [weak self, weak box] _ in
            box?.isOn = staged
            self?.activate(hunk, reviewID: id)
        }
        return box
    }
}
