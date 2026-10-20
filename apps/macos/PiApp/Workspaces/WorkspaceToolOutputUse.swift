import Foundation

/// A reference may be held only by an asynchronous operation, between its
/// old display/record and its new durable holder. Until publication finishes
/// we cannot inventory all of that operation's references; retain all output.
enum ToolOutputProducer: String, CaseIterable {
    case sideDraft, draftWrite, draftFlush, draftRecovery, draftMaterialization, submission, messageEdit, queuedEdit
    case sidePublication, sideClose, sideHandoff, keep, keepRegistration, keepDismissal, fork, recovery, handoff, importChat, export
}

struct ToolOutputUse {
    let id: UUID
    let producer: ToolOutputProducer
    let recycling: Task<Void, Error>?
}

extension WorkspaceModel {
    /// Register synchronously, before clearing the old holder or queuing work.
    func beginToolOutputUse(_ producer: ToolOutputProducer) -> ToolOutputUse {
        let use = ToolOutputUse(id: UUID(), producer: producer, recycling: toolOutputRecycling?.task)
        toolOutputProducers[use.id] = producer
        toolOutputProducerRevision &+= 1
        return use
    }

    /// A recycle already submitted to the filesystem must finish before a new
    /// producer reads or publishes. Subsequent sweeps see its registration.
    func prepareToolOutputUse(_ use: ToolOutputUse) async throws {
        if let recycling = use.recycling { _ = await recycling.result }
        try Task.checkCancellation()
        try await toolOutputProducerStep?(use.producer)
    }

    func finishToolOutputUse(_ use: ToolOutputUse) {
        toolOutputProducers.removeValue(forKey: use.id)
        toolOutputProducerRevision &+= 1
        if toolOutputCollectionDeferred, toolOutputProducers.isEmpty { scheduleToolOutputCleanup() }
    }

    func deferToolOutputCollection(since revision: UInt64) -> Bool {
        guard !toolOutputProducers.isEmpty || toolOutputProducerRevision != revision else { return false }
        toolOutputCollectionDeferred = true
        return true
    }
}
