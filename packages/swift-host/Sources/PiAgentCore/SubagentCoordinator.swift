import Foundation

private actor SubagentCompletion {
    private var result: SubagentToolResult?
    private var readers: [CheckedContinuation<SubagentToolResult, Never>] = []
    func wait() async -> SubagentToolResult {
        if let result { return result }
        return await withCheckedContinuation { readers.append($0) }
    }
    func finish(_ result: SubagentToolResult) {
        guard self.result == nil else { return }
        self.result = result
        let waiting = readers; readers = []
        for reader in waiting { reader.resume(returning: result) }
    }
}

/// One helper-side coordinator, independent FIFO queues and 16 active runs per
/// budget owner. A slot includes tools, retry waits, summaries and settlement.
actor SubagentCoordinator {
    typealias Register = @Sendable (AgentSession, Profile, String, AgentSession) async throws -> Void
    typealias Settled = @Sendable (AgentSession) async -> Void
    private struct Runtime: Sendable { let environment: SubagentEnvironment, child: AgentSession; let childGeneration: Int }
    private struct Job: Sendable {
        let plan: SubagentPlan, generation: Int, runtimeID: String
        let completion: SubagentCompletion
        var runtime: Runtime?
        var status: SubagentStatus = .queued
        var allocated = false, cancelled = false, finishing = false
        var task: Task<Void, Never>?
        let startedAt = nowMS()
        var progress: SubagentProgress?
    }
    private let register: Register
    private let settled: Settled
    private var jobs: [SubagentCallKey: Job] = [:]
    private struct Rejected: Sendable { let result: SubagentToolResult, runtimeID: String }
    private var rejected: [SubagentCallKey: Rejected] = [:]
    private var queues: [String: [SubagentCallKey]] = [:]
    private var active: [String: Int] = [:]
    private var cancelledThrough: [String: Int] = [:]
    var retainedJobCount: Int { jobs.count + rejected.count }
    init(register: @escaping Register = { _, _, _, _ in }, settled: @escaping Settled = { _ in }) {
        self.register = register; self.settled = settled
    }

    /// Plan and create all queued children in assistant-call order before any
    /// starts. A write failure cannot leave an unobserved run behind this await.
    func prepare(_ calls: [(SubagentCallKey, ToolCall)], environment env: SubagentEnvironment) async {
        for (key, call) in calls where jobs[key] == nil && rejected[key] == nil {
            var planned: SubagentPlan?
            var created: AgentSession?
            do {
                try Task.checkCancellation()
                let spec = try SubagentSpec(call.arguments)
                let available = Set(env.definitions.map(\.name)).subtracting(["subagent"])
                let selected = spec.tools ?? available
                guard selected.isSubset(of: available) else { throw AgentError("subagent_tools", "Requested tools exceed the parent's effective tool set") }
                let (grant, profile) = try SubagentModelGrant.resolve(spec.model, parent: env.profile, grants: env.models)
                let link = SubagentLink(delegationID: UUID().uuidString, childSessionID: UUID().uuidString, budgetOwnerSessionID: env.ownerID,
                                        call: key, parentTurnID: env.turnID, parentExecutionID: env.executionID, parentAttemptID: env.parentAttemptID)
                let origin = SubagentOrigin(link: link, description: spec.description, model: grant, tools: selected.sorted(), readOnly: env.readOnly, resourceRevision: env.resources.revision, mcpPolicy: env.mcpPolicy)
                let proposed = SubagentPlan(origin: origin, task: spec.task, resultMessageID: UUID().uuidString)
                let plan = try await env.parent.registerDelegation(proposed, generation: env.generation); planned = plan
                var snapshot = env.resources
                snapshot.prompt += "\n\nYou are a delegated sub-agent. Perform only the supplied task within the inherited tools and project policy. Return a final answer to the parent. You have no parent conversation or explicit user skill selections. You cannot delegate, change permissions, or change the shared cost limit."
                snapshot.revision = sha256(Data((snapshot.revision + "subagent-v1").utf8))
                let tools = RestrictedTools(base: env.tools, allowed: selected, readOnly: env.readOnly, capabilities: env.capabilities, mcpPolicy: env.mcpPolicy)
                let child = try AgentSession(id: link.childSessionID, profile: profile, apiKey: env.apiKey, cwd: env.cwd, directory: env.directory,
                                             readOnly: env.readOnly, resources: Resources(frozen: snapshot), client: env.client, tools: tools,
                                             traces: env.traces, prepared: nil, subagentOrigin: origin, changed: env.changed)
                created = child
                try await child.bindBudgetOwner(env.parent, generation: env.generation)
                await child.useRetrySettings(env.retry)
                // Capture policy is inherited unchanged; lineage changes no retention limit.
                try await env.traces.inheritCapturePolicy(child: link.childSessionID, owner: link.budgetOwnerSessionID)
                try await child.setSubagentState(.queued)
                let childGeneration = await child.stopCount
                await child.installManagedCancellation(self, key: key)
                try await register(child, profile, env.apiKey, env.parent)
                jobs[key] = Job(plan: plan, generation: env.generation, runtimeID: env.runtimeID, completion: SubagentCompletion(), runtime: Runtime(environment: env, child: child, childGeneration: childGeneration))
                queues[plan.origin.link.budgetOwnerSessionID, default: []].append(key)
                await publish(key)
            } catch {
                let result = SubagentToolResult(plan: planned, status: error is CancellationError ? .notExecuted : .failed,
                                               error: (error as? AgentError) ?? AgentError("subagent_not_started", "The delegated task did not start"))
                if let created { try? await created.saveSubagentTerminal(result); await created.close() }
                rejected[key] = Rejected(result: result, runtimeID: env.runtimeID)
            }
        }
        let currentGeneration = await env.parent.stopCount
        if Task.isCancelled || env.generation != currentGeneration {
            await cancel(owner: env.ownerID, runtimeID: env.runtimeID, through: env.generation)
        }
        pump(env.ownerID)
    }

    private func pump(_ owner: String) {
        while active[owner, default: 0] < SubagentPolicy.maximumActiveChildren, let key = queues[owner]?.first {
            queues[owner]?.removeFirst()
            guard var job = jobs[key], !job.status.terminal, !job.cancelled else { continue }
            guard job.generation > cancelledThrough[job.runtimeID, default: -1] else {
                Task { await self.cancel(key) }; continue
            }
            active[owner, default: 0] += 1; job.allocated = true; job.status = .running
            job.task = Task { await self.run(key) }; jobs[key] = job
        }
    }
    private func run(_ key: SubagentCallKey) async {
        guard let job = jobs[key], let runtime = job.runtime else { return }
        do {
            try Task.checkCancellation()
            try await runtime.child.setSubagentState(.running)
            guard jobs[key]?.cancelled == false else { throw CancellationError() }
            _ = try await runtime.child.submitManaged(Submission(commandID: job.plan.origin.link.delegationID, turnID: UUID().uuidString, text: job.plan.task), steer: false, admittedAt: runtime.childGeneration)
            await publish(key)
            await runtime.child.waitForSubagent()
            let result = await runtime.child.subagentResult(job.plan, cancelled: jobs[key]?.cancelled == true)
            await finish(key, result: result)
        } catch {
            await runtime.child.stop(); await runtime.child.waitForSubagent()
            let result = SubagentToolResult(plan: job.plan, status: error is CancellationError || (error as? AgentError)?.code == "submission_stopped" ? .notExecuted : .failed,
                                           error: (error as? AgentError) ?? AgentError("subagent_not_started", "The delegated task did not start"))
            await finish(key, result: result)
        }
    }
    private func finish(_ key: SubagentCallKey, result: SubagentToolResult) async {
        guard var job = jobs[key], !job.status.terminal, !job.finishing, let runtime = job.runtime else { return }
        job.finishing = true; jobs[key] = job
        var result = result
        await runtime.child.endSubagentProgress()
        let progress = await runtime.child.subagentProgress(elapsed: nowMS() - job.startedAt)
        result.metadata["summary"] = (try? subagentJSON(SubagentSummary(link: job.plan.origin.link, description: job.plan.origin.description,
            model: job.plan.origin.model.model, status: result.status, revision: await runtime.environment.parent.sequence,
            tools: job.plan.origin.tools, progress: progress))) ?? .null
        do { try await runtime.child.saveSubagentTerminal(result) }
        catch {
            let failure = AgentError("subagent_persistence", "The child outcome could not be saved. Inspect its journal and effects before continuing.")
            result = SubagentToolResult(plan: job.plan, status: .failed, error: failure, began: job.allocated)
            await runtime.environment.parent.failFamilyAccounting(failure)
        }
        // The saved terminal record precedes resolution of the synchronous call.
        guard var current = jobs[key], !current.status.terminal else { return }
        current.status = result.status; current.task = nil; jobs[key] = current
        let owner = current.plan.origin.link.budgetOwnerSessionID
        if current.allocated { active[owner, default: 0] -= 1 }
        await publish(key)
        // Release unseen runtimes after their terminal record is durable. The
        // host keeps explicitly opened viewers attached until normal unload.
        jobs[key]?.runtime = nil
        // Stop cancels the producer task. Cleanup still acquires the host's
        // runtime gate and finishes before the parent consumes this result.
        await Task { await settled(runtime.child) }.value
        await current.completion.finish(result)
        pump(owner)
    }
    func result(_ key: SubagentCallKey) async -> SubagentToolResult {
        if let rejected = rejected[key] { return rejected.result }
        guard let job = jobs[key] else { return SubagentToolResult(status: .notExecuted, error: AgentError("subagent_not_planned", "The delegated task was not admitted")) }
        return await withTaskCancellationHandler(operation: { await job.completion.wait() }, onCancel: { Task { await self.cancel(key) } })
    }
    func cancel(owner: String, runtimeID: String, through generation: Int) async {
        cancelledThrough[runtimeID] = max(cancelledThrough[runtimeID, default: -1], generation)
        let keys = jobs.filter { $0.value.plan.origin.link.budgetOwnerSessionID == owner && $0.value.runtimeID == runtimeID && $0.value.generation <= generation && !$0.value.status.terminal }.map(\.key)
        for key in keys { await cancel(key) }
    }
    func cancel(_ key: SubagentCallKey) async {
        guard var job = jobs[key], !job.status.terminal, !job.cancelled, !job.finishing, let runtime = job.runtime else { return }
        job.cancelled = true; job.task?.cancel()
        if job.allocated { job.status = .stopping }
        jobs[key] = job
        await publish(key)
        await runtime.child.stop()
        if !job.allocated {
            await finish(key, result: SubagentToolResult(plan: job.plan, status: .notExecuted,
                                                       error: AgentError("parent_stopped", "Cancelled before execution. This task was not restarted.")))
        }
    }
    func progress(_ key: SubagentCallKey) async {
        guard let job = jobs[key], !job.status.terminal, !job.finishing else { return }
        await publish(key, discovery: false)
    }
    private func publish(_ key: SubagentCallKey, discovery: Bool = true) async {
        guard let job = jobs[key], let runtime = job.runtime else { return }
        let progress = await runtime.child.subagentProgress(elapsed: nowMS() - job.startedAt)
        guard jobs[key]?.status == job.status else { return }
        jobs[key]?.progress = progress
        await runtime.environment.parent.subagentChanged(SubagentSummary(link: job.plan.origin.link, description: job.plan.origin.description,
                                                                         model: job.plan.origin.model.model, status: job.status, revision: await runtime.environment.parent.sequence, tools: job.plan.origin.tools, progress: progress), discovery: discovery)
    }
    /// Parent results and their order are journal-backed. The coordinator keeps
    /// only live jobs and terminal answers awaiting durable parent consumption.
    func list(parent: AgentSession, cursor: Int = 0, limit: Int = 100) async -> JSON {
        let state = await parent.subagents, owner = parent.id, revision = await parent.sequence
        let ids = state.callOrder ?? state.plans.keys.sorted()
        let start = min(max(0, cursor), ids.count), page = ids[start...].prefix(max(1, min(limit, 256))), next = start + page.count
        return ["revision":JSON(revision), "active":JSON(active[owner, default: 0]), "total":JSON(ids.count),
                "cursor":next < ids.count ? JSON(next) : .null, "children":.array(page.compactMap { state.plans[$0] }.compactMap { plan in
            let status = jobs[plan.origin.link.call]?.status ?? state.outcomes?[plan.origin.link.delegationID] ?? .interrupted
            return try? subagentJSON(SubagentSummary(link: plan.origin.link, description: plan.origin.description, model: plan.origin.model.model, status: status, revision: revision, tools: plan.origin.tools, progress: jobs[plan.origin.link.call]?.progress))
        })]
    }
    func consumed(_ keys: [SubagentCallKey]) {
        for key in keys {
            rejected.removeValue(forKey: key)
            guard let job = jobs[key], job.status.terminal else { continue }
            jobs.removeValue(forKey: key)
            let owner = job.plan.origin.link.budgetOwnerSessionID
            queues[owner]?.removeAll { $0 == key }
            if queues[owner]?.isEmpty == true { queues.removeValue(forKey: owner) }
            if active[owner] == 0 { active.removeValue(forKey: owner) }
            if !jobs.values.contains(where: { $0.runtimeID == job.runtimeID }) { cancelledThrough.removeValue(forKey: job.runtimeID) }
        }
    }
    /// Called before the host detaches any child journal. The parent also
    /// awaits these completions through its synchronous tool batch.
    func drain() async {
        let pending = jobs.filter { !$0.value.status.terminal }.map { ($0.key, $0.value.completion) }
        for (key, _) in pending { await cancel(key) }
        for (_, completion) in pending { _ = await completion.wait() }
    }
    func release(owner: String, runtimeID: String) {
        consumed(jobs.filter { $0.value.plan.origin.link.budgetOwnerSessionID == owner && $0.value.runtimeID == runtimeID && $0.value.status.terminal }.map(\.key))
        rejected = rejected.filter { $0.value.runtimeID != runtimeID }
        cancelledThrough.removeValue(forKey: runtimeID)
    }
    func stop(owner: String, delegationID: String) async throws {
        guard let key = jobs.first(where: { $0.value.plan.origin.link.budgetOwnerSessionID == owner && $0.value.plan.origin.link.delegationID == delegationID })?.key else { throw AgentError("subagent_scope", "This delegation does not belong to the selected parent") }
        await cancel(key)
    }
}
