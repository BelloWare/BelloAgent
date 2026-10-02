import AppKit
import SwiftUI
import FileView
import GitView

// Who last changed each line of a file in a tab (`FileTab`), as Git says:
// shown beside the line numbers, and for the selected line in a bar under
// the header, from where its change opens in the project's Changes → History.
// Blamed is exactly the text shown — the document's own bytes handed to git —
// and read again when the file is, when the repository's HEAD or index moves
// (a commit of the file changes what is "not committed yet"), and when the
// tab is shown again. Hidden, closed or no longer trusted, nothing is read
// and what was read is let go of.

@MainActor final class FileBlame: ObservableObject {
    enum State: Equatable {
        case off
        case reading
        case shown(GitBlame)
        case unavailable(String)
    }
    @Published private(set) var state = State.off
    /// The selected line (from 0), for the bar.
    @Published private(set) var line = 0
    /// The repository the blame was read in (its top) and the file's path there.
    private(set) var repository: String?
    private(set) var path: String?
    weak var tab: FileTab?
    private var token = 0
    /// The read under way: cancelled by the next, by hiding and by closing,
    /// so its git process stops rather than finishing into nothing.
    private var reading: Task<Void, Never>?
    private var watch: GitStateWatch?
    private var watched: String?
    /// The service blame is read with; a test's own otherwise.
    static var service = GitService.shared

    var isOn: Bool { state != .off }

    func toggle() { isOn ? hide() : show() }
    func show() {
        guard !isOn else { return }
        state = .reading
        attach()
        read()
    }
    /// Off: nothing more read, the column gone, what was read let go of.
    func hide() {
        token &+= 1; answer &+= 1
        reading?.cancel(); reading = nil
        state = .off
        stopWatching()
        repository = nil; path = nil
        if let numbers = tab?.scrollIfMade?.numbers { numbers.annotations = nil; numbers.annotationClicked = nil }
        tab?.scrollIfMade?.textView.selectionDidChange = nil
    }
    /// Hidden: no reading and no watching; shown again, read again.
    func suspend() { token &+= 1; reading?.cancel(); reading = nil; stopWatching() }
    func resume() { if isOn { read(fresh: true) } }
    /// The tab's text was read again (saved, replaced, recreated): what was
    /// said of the old text goes at once — its lines are not these.
    func documentChanged() { if isOn { attach(); read(fresh: true) } }

    /// The column and the selection's line, on the tab's text view.
    private func attach() {
        guard let scroll = tab?.scrollIfMade else { return }
        scroll.numbers.annotations = { [weak self] line in self?.annotation(ofLine: line) }
        scroll.numbers.annotationClicked = { [weak self] line in self?.openChange(ofLine: line) }
        scroll.textView.selectionDidChange = { [weak self, weak view = scroll.textView] in
            guard let self, let view else { return }
            let line = view.selectedRange.start.line
            if self.line != line { self.line = line }
        }
        line = scroll.textView.selectedRange.start.line
    }

    /// Reads the blame of the text shown now. A newer read, a hide or a
    /// reload in between and its answer is dropped. `fresh`: the text is new,
    /// and what was shown of the last goes now; otherwise (the repository
    /// moved, the text the same) it stays until the new answer.
    private func read(fresh: Bool = false) {
        guard let tab, tab.readable, tab.isShownNow else { return }
        token &+= 1
        let token = token
        reading?.cancel(); reading = nil
        if fresh { state = .reading; answer &+= 1; tab.scrollIfMade?.numbers.needsDisplay = true }
        else if case .shown = state {} else { state = .reading }
        guard let document = tab.document, tab.status == .ready else {
            switch tab.status {
            case .binary: state = .unavailable("Not text: there are no lines to annotate.")
            case .truncated: state = .unavailable("Shown only in part (it is too large), so its lines can't be annotated.")
            case .failed: state = .unavailable("The file can't be read, so it can't be annotated.")
            default: break   // read once the text is in (`documentChanged`)
            }
            return
        }
        if document.encoding == .utf16LittleEndian || document.encoding == .utf16BigEndian {
            state = .unavailable("Git counts lines in bytes, and this file is UTF-16: its lines can't be matched to Git's.")
            return
        }
        let url = tab.url, service = Self.service
        reading = Task { [weak self] in
            guard let top = await service.repositoryRoot(of: url.deletingLastPathComponent().path) else {
                self?.finish(token, .unavailable("Not in a Git repository: there is no history to annotate.")); return
            }
            guard !Task.isCancelled, let self, token == self.token else { return }
            // Watched from here, whatever the answer: a file not committed
            // yet that is committed is read again.
            self.watchRepository(top)
            let resolvedTop = URL(fileURLWithPath: top).resolvingSymlinksInPath().path
            guard url.path.hasPrefix(resolvedTop + "/") else {
                self.finish(token, .unavailable("This file is outside its repository's working tree.")); return
            }
            let relative = String(url.path.dropFirst(resolvedTop.count + 1))
            guard let bytes = await document.snapshot(limit: GitService.blameByteLimit) else {
                // Changed since it was read: the reload reads it again.
                guard token == self.token else { return }
                if await document.hasChanged() { return }
                self.finish(token, .unavailable("Too large to annotate: blame covers files of up to \(GitService.blameByteLimit >> 20) MB."))
                return
            }
            do {
                let blame = try await service.blame(path: relative, contents: bytes, in: top)
                guard !Task.isCancelled, token == self.token, let tab = self.tab, tab.document === document, tab.readable else { return }
                self.repository = top; self.path = relative
                self.finish(token, .shown(blame))
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.finish(token, .unavailable(error.localizedDescription))
            }
        }
    }
    private func finish(_ token: Int, _ state: State) {
        guard token == self.token, isOn else { return }
        answer &+= 1
        self.state = state
        tab?.scrollIfMade?.numbers.needsDisplay = true
    }

    /// A commit, a checkout or a stage changes what git says of the file
    /// even when the file stays the same.
    private func watchRepository(_ top: String) {
        guard watched != top || watch?.isWatching != true else { return }
        stopWatching()
        let watch = GitStateWatch(root: top) { [weak self] in self?.read() }
        // A watch on the repository the file is in, not one it left.
        watch.start()
        self.watch = watch; watched = top
    }
    private func stopWatching() { watch?.stop(); watch = nil; watched = nil }

    // MARK: What a line shows

    var blame: GitBlame? { if case .shown(let blame) = state { return blame }; return nil }
    /// The line's attribution: nil for the empty line after a final newline,
    /// which Git does not count.
    func entry(ofLine line: Int) -> (line: GitBlameLine, commit: GitBlameCommit?)? {
        guard let blame, blame.lines.indices.contains(line) else { return nil }
        let entry = blame.lines[line]
        return (entry, entry.commit.flatMap { blame.commits[$0] })
    }
    func annotation(ofLine line: Int) -> FileLineAnnotation? {
        guard let (_, commit) = entry(ofLine: line) else { return nil }
        guard let commit else { return FileLineAnnotation(text: "Not committed", detail: "Not committed yet", actionable: false) }
        return FileLineAnnotation(text: "\(commit.shortHash) \(commit.author)", detail: Self.detail(commit), actionable: canOpen(commit))
    }
    static func detail(_ commit: GitBlameCommit) -> String {
        "\(commit.shortHash) · \(commit.author) <\(commit.email)> · \(commit.date.formatted(date: .abbreviated, time: .shortened))\n\(commit.summary)"
    }
    /// A change opens in the project's Changes; the history before a shallow
    /// clone's edge is not there to compare with.
    func canOpen(_ commit: GitBlameCommit) -> Bool { tab?.projectID != nil && !commit.historyMissing }

    // MARK: Opening the change

    /// What the app does to show a change: set once by the app.
    /// `still` says whether the ask still stands: the same text, blamed the
    /// same, still readable.
    static var openChange: (FileTab, GitHistoryTarget, String, @escaping @MainActor () -> Bool) -> Void = { _, _, _, _ in }
    /// Which blame answer is shown: a newer one, or none, is another.
    private(set) var answer = 0
    func openChange(ofLine line: Int) {
        guard let tab, tab.readable, let repository, let (entry, commit) = entry(ofLine: line), let commit, canOpen(commit) else { return }
        guard let document = tab.documentIfMade else { return }
        let answer = answer
        Self.openChange(tab, GitHistoryTarget(commit: commit.hash, path: entry.path, line: entry.line), repository) { [weak self, weak tab, weak document] in
            // The tab still open and the blame still the one asked from,
            // then the same text, still the file on disk: nothing opened to
            // find out, and a file replaced while its tab is hidden counts.
            guard let self, let tab, tab.container != nil, tab.readable, self.isOn, self.answer == answer, self.blame != nil,
                  let document, tab.documentIfMade === document else { return false }
            return document.isUnchanged
        }
    }
}

/// The selected line's attribution, under the file's header while blame is
/// shown: what the gutter says, readable and reachable by the keys.
struct FileBlameBar: View {
    @ObservedObject var blame: FileBlame
    var body: some View {
        HStack(spacing: PiSpacing.sm) {
            Image(systemName: "person.text.rectangle").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary)
                .accessibilityHidden(true)
            content
            Spacer(minLength: 0)
            PiIconButton(symbol: "xmark", label: "Hide Blame", size: 24) { blame.hide() }
                .accessibilityIdentifier("file-blame-hide")
        }
        .padding(.horizontal, PiSpacing.md).frame(height: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.piHairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-blame-bar")
    }

    @ViewBuilder private var content: some View {
        switch blame.state {
        case .off: EmptyView()
        case .reading:
            PiSpinner(controlSize: .small)
            Text("Reading who changed each line…").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
        case .unavailable(let reason):
            Text(reason).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(2)
                .accessibilityIdentifier("file-blame-unavailable")
        case .shown:
            if let (entry, commit) = blame.entry(ofLine: blame.line) {
                if let commit {
                    let summary = "Line \(blame.line + 1) · \(commit.shortHash) · \(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .omitted)) · \(commit.summary)"
                    Text(summary).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.tail)
                        .help(FileBlame.detail(commit))
                        .accessibilityLabel(summary)
                        .accessibilityIdentifier("file-blame-line")
                    if commit.historyMissing {
                        Text("Earlier history isn't in this clone").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                    }
                    Button("Show Change") { blame.openChange(ofLine: blame.line) }
                        .buttonStyle(.piSecondaryCompact).fixedSize()
                        .disabled(!blame.canOpen(commit))
                        .help(blame.tab?.projectID == nil ? "Open the file from a project to see its history." : "Open this commit's change to \(entry.path), at line \(entry.line), in Changes.")
                        .accessibilityIdentifier("file-blame-show-change")
                    PiIconButton(symbol: "doc.on.doc", label: "Copy Commit ID", size: 24) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash, forType: .string)
                    }
                } else {
                    Text("Line \(blame.line + 1) · Not committed yet").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        .accessibilityIdentifier("file-blame-line")
                }
            } else {
                Text("Line \(blame.line + 1) · No line here in Git's count").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .accessibilityIdentifier("file-blame-line")
            }
        }
    }
}

/// The bar, while blame is on.
struct FileBlameBarSlot: View {
    @ObservedObject var blame: FileBlame
    var body: some View { if blame.isOn { FileBlameBar(blame: blame) } }
}

/// Show Blame / Hide Blame in the file's header.
struct FileBlameToggle: View {
    @ObservedObject var blame: FileBlame
    var body: some View {
        PiIconButton(symbol: "person.text.rectangle", label: blame.isOn ? "Hide Blame" : "Show Blame", tone: blame.isOn ? .accent : .neutral,
                     size: 26, filled: blame.isOn) { blame.toggle() }
            .accessibilityIdentifier("file-blame-toggle")
    }
}
