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
    private struct Runtime: Sendable { let environment: SubagentEnvironment, child: AgentSession }
    private struct Job: Sendable {
        let plan: SubagentPlan, generation: Int
        let completion: SubagentCompletion
        var runtime: Runtime?
        var status: SubagentStatus = .queued
        var allocated = false, cancelled = false, finishing = false
        var task: Task<Void, Never>?
    }
    private let register: Register
    private var jobs: [SubagentCallKey: Job] = [:]
    private var rejected: [SubagentCallKey: SubagentToolResult] = [:]
    private var queues: [String: [SubagentCallKey]] = [:]
    private var order: [String: [SubagentCallKey]] = [:]
    private var active: [String: Int] = [:]
    private var cancelledThrough: [String: Int] = [:]
    private var revisions: [String: Int] = [:]
    init(register: @escaping Register = { _, _, _, _ in }) { self.register = register }

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
                let plan = SubagentPlan(origin: origin, task: spec.task, resultMessageID: UUID().uuidString); planned = plan
                try await env.parent.registerDelegation(plan, generation: env.generation)
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
                let mode = await env.traces.mode(env.ownerID)
                _ = try await env.traces.command("debug.mode", session: link.childSessionID, params: ["mode":JSON(mode)])
                try await child.setSubagentState(.queued)
                try await register(child, profile, env.apiKey, env.parent)
                jobs[key] = Job(plan: plan, generation: env.generation, completion: SubagentCompletion(), runtime: Runtime(environment: env, child: child))
                queues[env.ownerID, default: []].append(key)
                order[env.ownerID, default: []].append(key)
                await publish(key)
            } catch {
                let result = SubagentToolResult(plan: planned, status: error is CancellationError ? .notExecuted : .failed,
                                               error: (error as? AgentError) ?? AgentError("subagent_not_started", "The delegated task did not start"))
                if let created { try? await created.saveSubagentTerminal(result); await created.close() }
                rejected[key] = result
            }
        }
        if Task.isCancelled { await cancel(owner: env.ownerID, through: env.generation) }
        pump(env.ownerID)
    }

    private func pump(_ owner: String) {
        while active[owner, default: 0] < SubagentPolicy.maximumActiveChildren, let key = queues[owner]?.first {
            queues[owner]?.removeFirst()
            guard var job = jobs[key], !job.status.terminal, !job.cancelled else { continue }
            guard job.generation > cancelledThrough[owner, default: -1] else {
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
            _ = try await runtime.child.submitManaged(Submission(commandID: job.plan.origin.link.delegationID, turnID: UUID().uuidString, text: job.plan.task), steer: false)
            await publish(key)
            await runtime.child.waitForSubagent()
            let result = await runtime.child.subagentResult(job.plan, cancelled: jobs[key]?.cancelled == true)
            await finish(key, result: result)
        } catch {
            await runtime.child.stop(); await runtime.child.waitForSubagent()
            let result = SubagentToolResult(plan: job.plan, status: error is CancellationError ? .notExecuted : .failed,
                                           error: (error as? AgentError) ?? AgentError("subagent_not_started", "The delegated task did not start"))
            await finish(key, result: result)
        }
    }
    private func finish(_ key: SubagentCallKey, result: SubagentToolResult) async {
        guard var job = jobs[key], !job.status.terminal, !job.finishing, let runtime = job.runtime else { return }
        job.finishing = true; jobs[key] = job
        var result = result
        do { try await runtime.child.saveSubagentTerminal(result) }
        catch {
            let failure = AgentError("subagent_persistence", "The child outcome could not be saved. Inspect its journal and effects before continuing.")
            result = SubagentToolResult(plan: job.plan, status: .failed, error: failure, began: job.allocated)
            await runtime.environment.parent.failFamilyAccounting(failure)
        }
        // The saved terminal record precedes resolution of the synchronous call.
        guard var current = jobs[key], !current.status.terminal else { return }
        current.status = result.status; current.task = nil; jobs[key] = current
        if current.allocated { active[key.parentSessionID, default: 0] -= 1 }
        await publish(key)
        // Keep discovery and the saved answer, but release the parent, credentials
        // and runtime graph. The host owns loaded children and normal idle unload.
        jobs[key]?.runtime = nil
        await current.completion.finish(result)
        pump(key.parentSessionID)
    }
    func result(_ key: SubagentCallKey) async -> SubagentToolResult {
        if let result = rejected[key] { return result }
        guard let job = jobs[key] else { return SubagentToolResult(status: .notExecuted, error: AgentError("subagent_not_planned", "The delegated task was not admitted")) }
        return await withTaskCancellationHandler(operation: { await job.completion.wait() }, onCancel: { Task { await self.cancel(key) } })
    }
    func cancel(owner: String, through generation: Int) async {
        cancelledThrough[owner] = max(cancelledThrough[owner, default: -1], generation)
        let keys = jobs.filter { $0.key.parentSessionID == owner && $0.value.generation <= generation && !$0.value.status.terminal }.map(\.key)
        for key in keys { await cancel(key) }
    }
    func cancel(_ key: SubagentCallKey) async {
        guard var job = jobs[key], !job.status.terminal, !job.cancelled, !job.finishing, let runtime = job.runtime else { return }
        job.cancelled = true; job.task?.cancel(); jobs[key] = job
        await runtime.child.stop()
        if !job.allocated {
            await finish(key, result: SubagentToolResult(plan: job.plan, status: .notExecuted,
                                                       error: AgentError("parent_stopped", "Cancelled before execution. This task was not restarted.")))
        }
    }
    private func publish(_ key: SubagentCallKey) async {
        guard let job = jobs[key], let runtime = job.runtime else { return }
        revisions[key.parentSessionID, default: 0] += 1
        await runtime.environment.parent.subagentChanged(SubagentSummary(link: job.plan.origin.link, description: job.plan.origin.description,
                                                                         model: job.plan.origin.model.model, status: job.status, revision: revisions[key.parentSessionID, default: 0]))
    }
    func list(owner: String, cursor: Int = 0, limit: Int = 100) -> JSON {
        let keys = order[owner] ?? [], start = min(max(0, cursor), keys.count), revision = revisions[owner, default: 0]
        let page = keys[start...].prefix(max(1, min(limit, 256))), next = start + page.count
        return ["revision":JSON(revision), "active":JSON(active[owner, default: 0]), "total":JSON(keys.count),
                "cursor":next < keys.count ? JSON(next) : .null, "children":.array(page.compactMap { jobs[$0] }.compactMap {
            try? subagentJSON(SubagentSummary(link: $0.plan.origin.link, description: $0.plan.origin.description, model: $0.plan.origin.model.model, status: $0.status, revision: revision))
        })]
    }
    func stop(owner: String, delegationID: String) async throws {
        guard let key = jobs.first(where: { $0.key.parentSessionID == owner && $0.value.plan.origin.link.delegationID == delegationID })?.key else { throw AgentError("subagent_scope", "This delegation does not belong to the selected parent") }
        await cancel(key)
    }
}
