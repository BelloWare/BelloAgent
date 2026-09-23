import SwiftUI
import AppKit

/// What the cost-limit notice in a transcript asks for.
enum CostLimitNoticeAction: Sendable { case raise, continueRun }

// Each chat's cost limit: the Settings default, a chat's own choice, and the
// helper session that enforces it. The helper checks the chat's reported
// spend against the limit before every model request; the app decides which
// limit that is and tells the helper whenever it changes.
extension WorkspaceModel {
    /// The limit every chat without its own runs under.
    var defaultCostLimit: CostLimit { configuration.defaultChatCostLimit }
    /// The limit a chat runs under: its own, else the Settings default.
    func costLimit(for item: ChatRecord) -> CostLimit { item.costLimit ?? defaultCostLimit }
    func costLimit(for id: String) -> CostLimit { record(id).map(costLimit(for:)) ?? defaultCostLimit }

    /// The chat's reading with its current limit and what its helper last
    /// said of its spend.
    func costReading(for id: String) -> SessionCostReading {
        var reading = displays[id]?.footer.cost ?? SessionCostReading()
        reading.override = record(id)?.costLimit; reading.defaultLimit = defaultCostLimit; reading.limit = costLimit(for: id)
        return reading
    }
    /// Puts a chat's limit on its display: the footer's figure and the stop notice.
    func refreshCostReading(_ id: String) {
        displays[id]?.applyCostReading(costReading(for: id))
    }

    /// Sets a chat's own limit, or with nil lets it follow the default. The
    /// choice is saved with the chat and reaches its helper session at once:
    /// the next model request is checked against it, in a run that is going too.
    func setCostLimit(_ limit: CostLimit?, for id: String) async throws {
        if let limit, !limit.isValid { throw HostError.failure("Enter an amount in US dollars above $0, up to $1,000,000.") }
        if let index = chats.firstIndex(where: { $0.id == id }) {
            if chats[index].costLimit != limit {
                chats[index].costLimit = limit
                // A chat not yet sent has no record; its first message writes it, limit included.
                if !pendingChatIDs.contains(id) {
                    guard let store else { throw StoreError.unavailable }
                    try await store.put(chats[index], kind: "chat", id: id)
                }
            }
        } else if let side = side(id) {
            sides[side.parentID]?.costLimit = limit
        } else { throw HostError.failure("This chat is no longer available.") }
        refreshCostReading(id); displays[id]?.costLimitChanged()
        await sendCostLimit(id)
    }
    /// Saves the Settings default. Every chat that follows it is told.
    func setDefaultCostLimit(_ limit: CostLimit) async throws {
        guard limit.isValid else { throw HostError.failure("Enter an amount in US dollars above $0, up to $1,000,000.") }
        try await updateConfiguration { $0.chatCostLimit = limit }
    }
    /// The default changed (Settings saved, the vault read again): every
    /// open chat that follows it shows and enforces the new one.
    func defaultCostLimitChanged() {
        for (id, view) in displays {
            refreshCostReading(id)
            if record(id).map({ $0.costLimit == nil }) ?? false { view.costLimitChanged() }
        }
        for id in opened where record(id).map({ $0.costLimit == nil }) ?? false { Task { await sendCostLimit(id) } }
    }
    /// Tells a chat's loaded helper session the limit it runs under. A chat
    /// with no session loaded is told when one opens (`costLimitParams`).
    func sendCostLimit(_ id: String) async {
        guard opened.contains(id), let item = record(id), let host = hosts[item.workspaceID], host.isReady else { return }
        let limit = costLimit(for: item)
        displays[id]?.costLimitSent = limit
        // A failed send is not retried from here: the next change sends again,
        // and a snapshot showing the old limit asks only for a limit not yet tried.
        do { _ = try await host.request("session.configure", sessionID: id, params: ["costLimit": limit.wire]) }
        catch { displays[id]?.notice = "The new cost limit did not reach this chat's helper: " + error.localizedDescription }
        refresh(id)
    }
    /// What a session open carries: the chat's limit, and for a chat whose
    /// journal predates cost records, what the request log holds of its spend
    /// so far. The helper takes that figure once and records costs itself from then on.
    func costLimitParams(for item: ChatRecord) async -> [String: WireValue] {
        var params: [String: WireValue] = ["costLimit": costLimit(for: item).wire]
        if let seed = await costSeed(for: item) { params["costSeed"] = seed }
        displays[item.id]?.costLimitSent = costLimit(for: item)
        return params
    }
    private func costSeed(for item: ChatRecord) async -> WireValue? {
        // A chat whose journal the helper creates records every cost from its first request.
        guard item.path != nil else { return nil }
        var totals = displays[item.id]?.footer.gateway ?? chatStats[item.id]
        if (totals?.requests ?? 0) == 0 {
            totals = try? await traces.gatewayAccounting(sessionID: item.id, workspaceID: item.workspaceID, messages: []).session
        }
        guard let totals, totals.requests > 0 else { return nil }
        let reported = max(0, totals.costSamples)
        return .object(["usd": .number(reported > 0 ? max(0, totals.costUSD ?? 0) : 0), "reported": .number(Double(reported)),
                        "unreported": .number(Double(max(0, totals.requests - reported)))])
    }
    /// A snapshot's `cost`: what the helper counted, and the limit it runs
    /// under. A helper that runs under another limit than the chat's (a
    /// change it missed) is told the chat's once.
    func observeCost(_ snapshot: [String: WireValue], view: SessionDisplay) {
        guard let cost = snapshot["cost"]?.object else { return }
        var reading = costReading(for: view.id)
        reading.spentUSD = cost["spentUSD"]?.number
        reading.reportedRequests = cost["reportedRequests"]?.nonnegativeInteger ?? 0
        reading.unreportedRequests = cost["unreportedRequests"]?.nonnegativeInteger ?? 0
        view.applyCostReading(reading)
        let helper: CostLimit = cost["limitUSD"]?.number.map(CostLimit.usd) ?? .unlimited
        if helper != reading.limit, view.costLimitSent != reading.limit {
            view.costLimitSent = reading.limit
            let id = view.id
            Task { await sendCostLimit(id) }
        }
    }

    /// The notice's two actions: open the limit editor over the button, or
    /// carry on from where the run stopped once the limit is above the spend.
    func costLimitNotice(_ action: CostLimitNoticeAction, sessionID: String, anchor: NSView?) {
        switch action {
        case .raise:
            guard let anchor, let view = displays[sessionID] else { return }
            CostLimitPopover.shared.toggle(model: self, footer: view.footer, sessionID: sessionID, anchor: anchor)
        case .continueRun: continueAfterCostLimit(sessionID)
        }
    }
    /// Continues a chat stopped at its limit: the stopped turn is sent again
    /// from where it stopped, with the chat's current choices, and queued
    /// follow-ups go on after it; a run that stopped between turns resumes
    /// its queue instead.
    func continueAfterCostLimit(_ id: String) {
        guard !installPreparing, let item = record(id), !costReading(for: id).reached else { return }
        guard !item.isArchived else { displays[id]?.notice = Self.archivedNotice; return }
        Task {
            do {
                let lease = try connectionLease(for: item)
                let host = try await open(item)
                try requireConnection(lease)
                do { _ = try await host.request("turn.retry", sessionID: id, params: TurnOverrides.params(for: item)) }
                catch HostError.rejected(let code, _) where code == "nothing_to_retry" {
                    _ = try await host.request("queue.resume", sessionID: id)
                }
                refresh(id)
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// The popover "Raise limit…" opens over its button: the chat's limit editor.
/// One app-owned popover at a time, like the stats pills' and the skills'.
@MainActor final class CostLimitPopover {
    static let shared = CostLimitPopover()
    let presenter = PiPopoverPresenter()
    /// The chat whose limit the open popover edits (a test seam).
    private(set) var sessionID: String?
    static let width: CGFloat = 380
    func toggle(model: WorkspaceModel, footer: SessionMetrics, sessionID: String, anchor: NSView) {
        if presenter.isShown, self.sessionID == sessionID { close(); return }
        self.sessionID = sessionID
        let reduce = PiMotion.reducesMotion
        presenter.show(from: anchor, width: Self.width, maximumHeight: 460, animates: !reduce) {
            AnyView(CostLimitLiveEditor(footer: footer, title: "Raise this chat's limit", choose: { limit in
                try await model.setCostLimit(limit, for: sessionID)
                // Chosen: the popover has done its job.
                CostLimitPopover.shared.close()
            })
            .padding(PiSpacing.lg)
            .environment(\.piReduceMotion, reduce).tint(Color.piAccent))
        }
    }
    func close() { presenter.close(); sessionID = nil }
}
