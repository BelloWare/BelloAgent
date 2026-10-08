import AppKit

/// The workspace hands its native transcript the current chat and actions directly.
extension NativeTranscriptPane {
    func showTranscript(model: WorkspaceModel, session: SessionDisplay, state: String, canFork: Bool, canQuote: Bool, enabled: Bool) {
        onAnchorChanged = { [weak model, weak session] anchor in
            guard let model, let session else { return }
            session.scrollAnchor = anchor; model.anchorChanged(session)
        }
        onReadReply = { [weak model] sessionID, messageID in model?.acknowledgeVisibleReply(sessionID: sessionID, messageID: messageID) }
        onLoadEarlier = { [weak model] in model?.loadEarlier(sessionID: $0) }
        onLoadNewer = { [weak model] in model?.loadNewer(sessionID: $0) }
        onPrefetchEarlier = { [weak model] in model?.loadEarlier(sessionID: $0, automatic: true) }
        onPrefetchNewer = { [weak model] in model?.loadNewer(sessionID: $0, automatic: true) }
        onLatest = { [weak model] in model?.latest(sessionID: $0) }
        onStart = { [weak model] id in Task { await model?.revealStartOfChat(sessionID: id) } }
        find.search = { [weak model] id, query, start in
            guard let model else { throw CancellationError() }
            return try await model.searchConversation(id, query: query, start: start)
        }
        find.reveal = { [weak model] id, messageID in await model?.revealInTranscript(sessionID: id, messageID: messageID, fromFind: true) ?? false }
        onViewportReady = { [weak model] in model?.historyViewportReady($0, generation: $1) }
        var environment = TranscriptRowEnvironment(view: self)
        environment.isEnabled = enabled; environment.forks = canFork; environment.opensFiles = true
        update(session: session, state: state, actions: TranscriptActions(inspect: { model.showMessageDetail(session.id, messageID: $0) },
                                                        edit: { model.editMessage($0, sessionID: session.id) },
                                                        copyMessage: { id in
                                                            guard let message = session.presentedMessages.first(where: { $0.id == id }) else { return }
                                                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
                                                        },
                                                        stop: { model.stop(sessionID: session.id) },
                                                        // The retry carries this chat's current model, effort and budgets, as a send would.
                                                        retry: { model.action("turn.retry", params: model.record(session.id).map { model.turnOverrides(for: $0) } ?? [:], sessionID: session.id) },
                                                        quoteReply: canQuote ? { quote in model.openQuotedSide(parentID: session.id, quote: quote) } : nil,
                                                        inspectTurn: { [weak model] turn in
                                                            model?.openInspector(session: session.id, focus: WorkspaceModel.inspectorFocus(for: turn))
                                                        },
                                                        skillPressed: { [weak model, weak session] messageID, use, anchor in
                                                            guard let model, let session else { return }
                                                            SkillPopovers.shared.pressSent(use: use, messageID: messageID, anchor: anchor, model: model, session: session)
                                                        },
                                                        skillHovered: { [weak session] _, use, anchor, inside in
                                                            guard let session else { return }
                                                            SkillPopovers.shared.hoverSent(inside, use: use, anchor: anchor, session: session)
                                                        },
                                                        costLimit: { [weak model] action, anchor in model?.costLimitNotice(action, sessionID: session.id, anchor: anchor) },
                                                        fork: { [weak model, id = session.id] messageID in model?.forkFromReply(sessionID: id, messageID: messageID) },
                                                        switchVersion: { [weak model] messageID, step in model?.showVersion(sessionID: session.id, messageID: messageID, step: step) },
                                                        latestVersion: { [weak model] in model?.latestVersion(sessionID: session.id) },
                                                        openFile: { [weak model] path, lines in model?.openFile(fromChat: session.id, path: path, lines: lines) },
                                                        resolveReplyFile: { [weak model] text in await model?.resolveReplyFile(text, fromChat: session.id) }), environment: environment, reduceMotion: piReducesMotion)
    }
}
