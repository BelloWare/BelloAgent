import Foundation

/// One sidebar choice, independent of the selected chat and of project folds.
/// An explicit false is durable: legacy per-project Flat choices only seed it once.
struct SidebarViewState: Codable, Sendable, Equatable {
    static let recordKind = "sidebar-view"
    static let recordID = "main"
    var flat = false
    var shownRoots: [String: Int] = [:]
    var revision: Int64 = 0

    var sanitized: SidebarViewState? {
        guard revision >= 0, revision < Int64.max else { return nil }
        var value = self
        value.shownRoots = shownRoots.filter {
            SidebarSessionPresentation.isCombinedGroup($0.key) && $0.value > 0 && $0.value <= ProjectSidebarState.maximumShownRoots
        }
        return value
    }
}

extension WorkspaceModel {
    var sidebarListsFlat: Bool { sidebarViewState.flat }

    func setSidebarFlat(_ flat: Bool) {
        guard sidebarListsFlat != flat || sidebarViewState.revision == 0 else { return }
        var next = sidebarViewState; next.flat = flat
        sidebarViewModeChanged = true
        saveSidebarViewState(next)
    }

    /// Read all legacy rows, even those whose project is no longer listed.
    /// A choice made while the store was being read takes precedence.
    func restoreSidebarViewState(legacy: [ProjectSidebarState], unlessChangedSince revision: Int64) async throws {
        let saved = try await store?.get(SidebarViewState.self, kind: SidebarViewState.recordKind, id: SidebarViewState.recordID)?.sanitized
        if sidebarViewState.revision == revision, !dirtySidebarViewState {
            if let saved { sidebarViewState = saved }
            else { saveSidebarViewState(SidebarViewState(flat: legacy.contains { $0.revision >= 0 && $0.revision < Int64.max && $0.flatTopics == true })) }
        } else if dirtySidebarViewState, let saved {
            adoptSidebarViewState(saved, preservingChanges: true)
        }
        applySidebarViewPages()
    }

    func saveSidebarViewState(_ proposed: SidebarViewState) {
        var value = proposed
        value.revision = max(min(sidebarViewState.revision, Int64.max - 2) + 1, Int64(Date().timeIntervalSince1970 * 1_000_000))
        sidebarViewState = value; dirtySidebarViewState = true
        scheduleSidebarViewWrite()
    }

    private func scheduleSidebarViewWrite() {
        guard sidebarViewWrite == nil else { return }
        sidebarViewWrite = Task { [weak self] in
            guard let self else { return }
            defer { self.sidebarViewWrite = nil }
            while self.dirtySidebarViewState {
                let value = self.sidebarViewState
                do {
                    guard let store = self.store else { throw StoreError.unavailable }
                    let saved = try await store.mergeSidebarViewState(value, modeChanged: self.sidebarViewModeChanged, pagesChanged: self.sidebarViewPagesChanged)
                    let changedAgain = self.sidebarViewState.revision != value.revision
                    self.adoptSidebarViewState(saved, preservingChanges: changedAgain)
                    if !changedAgain {
                        self.dirtySidebarViewState = false
                        self.sidebarViewModeChanged = false; self.sidebarViewPagesChanged.removeAll()
                    }
                    self.applySidebarViewPages()
                } catch {
                    self.error = "Sidebar preferences could not be saved. \(error.localizedDescription)"
                    break
                }
            }
        }
    }

    /// Overlay only fields the reader actually changed. A mode click before
    /// restore must not overwrite saved pages; a late read must not undo it.
    private func adoptSidebarViewState(_ saved: SidebarViewState, preservingChanges: Bool) {
        var next = saved
        if preservingChanges {
            if sidebarViewModeChanged { next.flat = sidebarViewState.flat }
            for group in sidebarViewPagesChanged { next.shownRoots[group] = sidebarViewState.shownRoots[group] }
            next.revision = max(next.revision, sidebarViewState.revision)
        }
        sidebarViewState = next
    }

    private func applySidebarViewPages() {
        let active = SidebarSessionPresentation.combinedFlatGroupID
        for group in [active, SidebarSessionPresentation.archiveGroupID(active)] {
            if sidebarPageSizes[group] != sidebarViewState.shownRoots[group] { sidebarPageSizes[group] = sidebarViewState.shownRoots[group] }
        }
    }

    /// Shares the project-sidebar quit/update flush boundary and bounded retry.
    func flushSidebarViewState(timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var retried = false
        while dirtySidebarViewState || sidebarViewWrite != nil {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            if dirtySidebarViewState, sidebarViewWrite == nil, !retried { retried = true; scheduleSidebarViewWrite() }
            if sidebarViewWrite == nil { return !dirtySidebarViewState }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return true
    }

    /// Flat has no project headers. Use the project Flat is narrowed to, the
    /// focused/selected chat's project, then the chosen or last remembered
    /// workspace, then the first trusted one.
    var flatNewChatProjectID: String? {
        let trusted = Set(workspaces.filter { $0.trusted && !$0.isScratch }.map(\.id))
        let candidates = [sidebarFlatProject, focusedSessionID.flatMap(record)?.workspaceID, selectedID.flatMap(record)?.workspaceID,
                          selectedWorkspaceID, selectionMemory.remembered?.projectID]
        return candidates.compactMap { $0 }.first { trusted.contains($0) }
            ?? workspaces.first { trusted.contains($0.id) }?.id
    }

    var canStartSidebarChat: Bool {
        if sidebarListsFlat { return flatNewChatProjectID != nil }
        return workspaces.contains { $0.id == selectedWorkspaceID && $0.trusted }
    }
}

// Merge and reserve the next revision in one store turn. This also covers a
// first menu click that beats restore, including a clock behind the saved one.
extension MetadataStore {
    func mergeSidebarViewState(_ proposed: SidebarViewState, modeChanged: Bool, pagesChanged: Set<String>) throws -> SidebarViewState {
        let saved = try get(SidebarViewState.self, kind: SidebarViewState.recordKind, id: SidebarViewState.recordID)?.sanitized
        var next: SidebarViewState
        if let saved { next = saved }
        else {
            let legacy = try list(ProjectSidebarState.self, kind: "project-sidebar")
            next = SidebarViewState(flat: legacy.contains { $0.revision >= 0 && $0.revision < Int64.max && $0.flatTopics == true })
        }
        if modeChanged { next.flat = proposed.flat }
        for group in pagesChanged { next.shownRoots[group] = proposed.shownRoots[group] }
        let previous = max(next.revision, proposed.revision)
        guard previous < Int64.max - 1 else { throw StoreError.invalidRecord }
        next.revision = previous + 1
        try put(next, kind: SidebarViewState.recordKind, id: SidebarViewState.recordID, revision: next.revision)
        return next
    }
}
