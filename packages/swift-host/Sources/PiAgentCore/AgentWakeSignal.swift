import Foundation

/// Lost-wakeup-safe, cancellable waits. No polling task per child/family.
actor AgentWakeSignal {
    private(set) var revision = 0
    private struct Waiter { let continuation: CheckedContinuation<Void,Never>; let timer: Task<Void,Never> }
    private var waiters: [UUID:Waiter] = [:]
    func pulse() {
        revision &+= 1
        for id in Array(waiters.keys) { finish(id) }
    }
    private func finish(_ id: UUID) { if let waiter = waiters.removeValue(forKey:id) { waiter.timer.cancel(); waiter.continuation.resume() } }
    func wait(after: Int, milliseconds: Int = 60_000) async {
        guard after == revision, milliseconds > 0, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || after != revision { continuation.resume(); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for:.milliseconds(milliseconds)) } catch { return }
                    await self?.finish(id)
                }
                waiters[id] = Waiter(continuation:continuation,timer:timer)
            }
        }, onCancel: { Task { await self.finish(id) } })
    }
}
