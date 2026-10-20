import Foundation

/// Rebuildable presentation evidence, never a delegation grant or cost owner.
struct InheritedSubagent: Equatable, Sendable {
    var target: SubagentTarget
    var title: String
    var number: Int
    var forkID: String
}
struct OriginalSubagentAvailability: Equatable, Sendable {
    var title: String
    var reason: String?
    var label: String { "From the original chat · " + title }
}

extension WorkspaceModel {
    func originalAvailability(_ target: SubagentTarget) -> OriginalSubagentAvailability {
        guard let owner = record(target.ownerID) else { return .init(title: "Unavailable", reason: "The original chat was deleted or is unavailable.") }
        let title = owner.title
        guard let project = workspace(for: owner.workspaceID), project.trusted else {
            return .init(title: title, reason: "The original project is unavailable or is not trusted.")
        }
        guard project.roots.allSatisfy({ path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }) else { return .init(title: title, reason: "The original project's folder is unavailable.") }
        guard let child = record(target.sessionID), child.workspaceID == owner.workspaceID,
              let link = child.delegation, target.matchesOrigin(link), child.delegationIssue == nil,
              let path = child.path, FileManager.default.fileExists(atPath: path),
              let parentPath = owner.path, FileManager.default.fileExists(atPath: parentPath) else {
            return .init(title: title, reason: "The original sub-agent or its saved history is unavailable.")
        }
        return .init(title: title)
    }
    func refreshOriginalAvailability() {
        for (id, entries) in inheritedSubagents {
            displays[id]?.originalSubagentAvailability = Dictionary(entries.map { ($0.target.sessionID, originalAvailability($0.target)) }, uniquingKeysWith: { first, _ in first })
        }
        invalidateConversationFamily()
    }
    func readInheritedSubagents(_ item: ChatRecord, current: () -> Bool) async {
        // Whole-chat forks have no sidebar ancestry. The copied plans, not
        // parentSessionID, identify references to another chat's agents.
        guard !item.isSubagent, !item.imported, let path = item.path else { return }
        let plans = (try? await history.subagentPlans(path: URL(fileURLWithPath: path), ownerID: item.id, includeInherited: true)) ?? []
        guard current(), record(item.id)?.path == path else { return }
        let entries = plans.filter { $0.header.link.budgetOwnerSessionID != item.id }.map {
            InheritedSubagent(target: SubagentTarget($0.header.link), title: $0.header.description, number: $0.number ?? 1, forkID: item.id)
        }
        inheritedSubagents[item.id] = entries
        for entry in entries { displays[item.id]?.subagentNumbers[entry.target.sessionID] = entry.number }
        refreshOriginalAvailability()
    }
    func isOriginalSubagentReader(_ id: String) -> Bool { subagentTab(id)?.originalForkID != nil }
    var canStopConversation: Bool { conversationCommandID().map { !isOriginalSubagentReader($0) } ?? false }

    @discardableResult func openOriginalSubagent(_ target: SubagentTarget, from forkID: String, sourceMessage: String? = nil) async -> Bool {
        guard target.isHistorical(in: forkID), record(forkID) != nil,
              originalAvailability(target).reason == nil else { refreshOriginalAvailability(); return false }
        let opening = beginSubagentOpening(target.sessionID)
        opening.reader.originalForkID = forkID
        defer { finishSubagentOpening(opening) }
        do {
            guard let child = record(target.sessionID), let path = child.path else { return false }
            let directory = try subagentDirectory(child.workspaceID)
            _ = try await history.subagentHeader(path: URL(fileURLWithPath: path), directory: directory, expected: target)
            guard opening.isCurrent, !Task.isCancelled, originalAvailability(target).reason == nil else { return false }
            guard let tab = await openSubagentTab(child.id, opening: opening), subagentTabIsShown(child.id) else { return false }
            let message = try await subagentTurnMessage(target, path: URL(fileURLWithPath: path))
            guard !Task.isCancelled, opening.isCurrent, subagentTab(child.id) === tab,
                  subagentTabIsShown(child.id), originalAvailability(target).reason == nil else { return false }
            if let message = sourceMessage ?? message {
                _ = await revealInTranscript(sessionID: child.id, messageID: message, navigation: opening)
            }
            return opening.isCurrent && subagentTabIsShown(child.id)
        } catch { if opening.isCurrent { self.error = error.localizedDescription } }
        return false
    }
    func inspectOriginalSubagent(_ target: SubagentTarget, from forkID: String) {
        guard target.isHistorical(in: forkID), record(forkID) != nil, originalAvailability(target).reason == nil else { return }
        // The Inspector is a capture reader. It issues no run or send commands.
        openInspector(session: target.ownerID, focus: .subagent(target.delegationID), originalForkID: forkID)
    }
    func loadOriginalSubagent(_ child: ChatRecord, view: SessionDisplay, navigation: HostedReaderToken) async {
        let generation = view.presentationGeneration
        defer { view.finishHistoryPresentation(generation); resumeVisibleReaders() }
        func current() -> Bool {
            !Task.isCancelled && navigation.isCurrent && subagentTab(child.id) === navigation.reader &&
                displays[child.id] === view && view.presentationGeneration == generation &&
                child.delegation.map { originalAvailability(SubagentTarget($0)).reason == nil } == true
        }
        do {
            guard current(), let link = child.delegation, let path = child.path else { return }
            if let fork = navigation.reader.originalForkID.flatMap(record) {
                await readInheritedSubagents(fork, current: current)
                guard current() else { return }
            }
            _ = try await history.subagentHeader(path: URL(fileURLWithPath: path), directory: subagentDirectory(child.workspaceID), expected: SubagentTarget(link))
            guard current() else { return }
            if let cost = try await history.subagentCost(path:URL(fileURLWithPath:path),directory:subagentDirectory(child.workspaceID),expected:SubagentTarget(link)) {
                guard current() else { return }
                observeCost(["cost":.object(cost)],sessionID:child.id)
            }
            guard current() else { return }
            try await loadDraftBaseline(view)
            guard current() else { return }
            var page = try await readInitialWindow(child, holding: view.scrollAnchor)
            guard current() else { return }
            page.messages = await withAccounting(page.messages, view: view, workspaceID: child.workspaceID)
            guard current() else { return }
            view.draftReady = true
            adoptInitialHistory(page, into: view)
        } catch is CancellationError {
            if current() { view.historyState = .failed("History reading was interrupted. Try loading it again.") }
        }
        catch { if current() { view.historyState = .failed(error.localizedDescription) } }
    }
}
