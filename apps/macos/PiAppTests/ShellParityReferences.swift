import AppKit
import SwiftUI
@testable import PiApp

// The SwiftUI views the workspace shell's AppKit views replaced, as they
// were when they were ported: `ShellParityTests` draws each next to its
// replacement and compares the pixels. They live here, in the tests, only.

// MARK: - The card

/// The compact preview a resting pointer brings up: the name, what the skill
/// is for, where it comes from and the arguments it was given.
struct RefSkillHoverCard: View {
    let detail: SkillDetail
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "command").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.piAccent)
                Text("/" + detail.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.piInk)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let policy = detail.policyTitle {
                    Text(policy).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).fixedSize()
                }
            }
            if !detail.description.isEmpty {
                Text(detail.description).font(.system(size: 12)).foregroundStyle(Color.piInkSecondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Text(detail.place.sentence).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                .lineLimit(1).truncationMode(.middle)
            if !detail.arguments.isEmpty {
                (Text("Arguments  ").foregroundStyle(Color.piInkTertiary) + Text(detail.arguments).foregroundStyle(Color.piInk))
                    .font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let note = detail.revisionNote, note.warns {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10.5, weight: .medium)).padding(.top, 1)
                    Text(note.text).font(PiFont.caption).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.piWarning)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("skill-hover-card")
    }
}

// MARK: - The popover

/// Everything about one pill's skill: what it is for, the arguments it was
/// given, its source file, where it comes from, its policy and version, and —
/// for a sent message — whether it has changed since.
struct RefSkillPopoverView: View {
    let detail: SkillDetail
    let actions: SkillPopoverActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.piHairline).frame(height: 1)
            // A ScrollView in the app; its content is shorter than the
            // popover's limit here, and a scroll view never settles in a capture.
            Group {
                VStack(alignment: .leading, spacing: 14) {
                    if detail.description.isEmpty {
                        Text("No description").font(PiFont.body).foregroundStyle(Color.piInkTertiary)
                    } else {
                        Text(detail.description).font(PiFont.body).foregroundStyle(Color.piInk)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let note = detail.revisionNote {
                        PiNote(note.text, tone: note.warns ? .warning : .neutral)
                            .accessibilityElement(children: .combine).accessibilityIdentifier("skill-popover-revision")
                    }
                    section("Arguments") {
                        if detail.arguments.isEmpty {
                            Text("None").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                        } else {
                            Text(detail.arguments).font(.system(size: 12.5)).foregroundStyle(Color.piInk)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.piSurfaceSunken, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
                        }
                    }
                    section("Source") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detail.place.file(detail.path)).font(PiFont.mono).foregroundStyle(Color.piInk)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(detail.path)
                            if !detail.place.root.isEmpty {
                                Text("in " + (detail.place.root as NSString).abbreviatingWithTildeInPath).font(PiFont.caption)
                                    .foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.middle).help(detail.place.root)
                            }
                            HStack(spacing: 6) {
                                Button("Open") { actions.open?() }.buttonStyle(.piSecondaryCompact).disabled(actions.open == nil)
                                    .accessibilityIdentifier("skill-popover-open")
                                Button("Reveal in Finder") { actions.reveal?() }.buttonStyle(.piSecondaryCompact).disabled(actions.reveal == nil)
                                    .accessibilityIdentifier("skill-popover-reveal")
                                if actions.open == nil {
                                    Text("File not found").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        fact("Scope", detail.place.title)
                        if let policy = detail.policyTitle {
                            fact("Policy", policy + (detail.policyDetail.map { " · " + $0 } ?? ""))
                        }
                        fact("Version", versionText, mono: true)
                    }
                }
                .padding(.horizontal, PiSpacing.lg).padding(.top, 14).padding(.bottom, PiSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if actions.editable {
                Rectangle().fill(Color.piHairline).frame(height: 1)
                HStack(spacing: PiSpacing.sm) {
                    if let edit = actions.editArguments {
                        Button("Edit Arguments…", action: edit).buttonStyle(.piSecondaryCompact)
                            .accessibilityIdentifier("skill-popover-edit")
                    }
                    Spacer(minLength: 0)
                    if let remove = actions.remove {
                        Button("Remove", action: remove).buttonStyle(.piGhostDanger)
                            .accessibilityIdentifier("skill-popover-remove")
                    }
                }
                .padding(.horizontal, PiSpacing.md).padding(.vertical, 10)
            }
        }
        .foregroundStyle(Color.piInk)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill-popover")
    }

    private var header: some View {
        HStack(spacing: 9) {
            PiIconBadge(symbol: "command", size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("/" + detail.name).font(PiFont.heading).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
                Text(detail.context == .composer ? "Selected for the message you are writing" : "Sent with this message")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
            Spacer(minLength: PiSpacing.sm)
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, 14).padding(.bottom, 12)
    }
    private var versionText: String {
        if case .changed(let now) = detail.revision {
            return detail.context == .sent ? "\(detail.version) · now \(now)" : "\(detail.version) · installed \(now)"
        }
        return detail.version.isEmpty ? "Unknown" : detail.version
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.piInkSecondary)
            content()
        }
    }
    private func fact(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PiSpacing.md) {
            Text(key).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).frame(width: 58, alignment: .leading)
            Text(value).font(mono ? PiFont.mono : PiFont.caption).foregroundStyle(Color.piInk)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Composer (batch 3)

struct RefPillLabel: View {
    let icon: String
    let text: String
    let active: Bool
    let loading: Bool
    let maxWidth: CGFloat
    /// Icon and chevron only, for a bar too narrow for labels; the help text still names the value.
    var compact = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(active ? Color.piAccent : Color.piInkSecondary)
            if !compact {
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: maxWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    // The same label with new words: its text crossfades while the
                    // chip resizes once, rather than a remove and an insert.
                    .contentTransition(.opacity)
            }
            if loading { PiSpinner(size: 6, lineWidth: 1.2).frame(width: 10, height: 10).transition(.opacity) }
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
        }
        .padding(.horizontal, compact ? 7 : 9).padding(.vertical, 4)
        .background(active ? Color.piAccentSoft : Color.piSurface, in: Capsule())
        .overlay(Capsule().stroke(active ? Color.piAccent.opacity(0.45) : Color.piHairlineStrong, lineWidth: 1))
        .contentShape(Capsule())
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.18), value: text)
        .animation(.easeInOut(duration: 0.18), value: active)
        .animation(.easeInOut(duration: 0.15), value: loading)
    }
}

struct RefEditingBanner: View {
    @ObservedObject var session: SessionDisplay
    var blocker: String? = nil
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line").foregroundStyle(Color.piAccent)
                Text("Editing an earlier message").font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 4)
                Button("Cancel", action: cancel).buttonStyle(.piGhost).keyboardShortcut(.cancelAction).disabled(session.editSubmitting)
            }
            Text(blocker ?? session.editNotice).font(PiFont.caption).foregroundStyle(blocker == nil ? Color.piInkSecondary : Color.piDanger).fixedSize(horizontal: false, vertical: true)
            if session.editInputReviewRequired {
                Button("Use text only / I've reselected the needed inputs") { session.editInputReviewRequired = false }.buttonStyle(.piGhost)
            }
        }.padding(8).background(Color.piAccentSoft, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 8).padding(.top, 8)
            .accessibilityElement(children: .contain).accessibilityLabel("Editing an earlier message")
    }
}

struct RefQueueEditBanner: View {
    let steering: Bool
    var resolving = false
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line").foregroundStyle(Color.piAccent)
                Text(steering ? "Editing a steering message" : "Editing a queued message").font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 4)
                if resolving { PiSpinner(controlSize: .mini).accessibilityLabel("Waiting for the helper") }
                Button("Cancel", action: cancel).buttonStyle(.piGhost).keyboardShortcut(.cancelAction).disabled(resolving)
            }
            Text("This message and the others waiting are paused while you edit. Return saves it in its place in the queue.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(8).background(Color.piAccentSoft, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 8).padding(.top, 8)
            .accessibilityElement(children: .contain).accessibilityLabel("Editing a queued message")
    }
}


// MARK: - The queue panel (Workspaces/QueuePanel.swift before batch 5)

struct RefQueuePanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    /// The height the list may take (`QueuePanel.room`).
    var room: CGFloat = .infinity
    private var items: [QueuedMessage] { QueuedMessage.from(session.queue) }
    private var followUps: [QueuedMessage] { items.filter { !$0.steering } }
    private var steering: [QueuedMessage] { items.filter(\.steering) }
    var body: some View {
        let timing = QueueTiming(session)
        let listHeight = QueuePanel.listHeight(rows: items.count, sections: (steering.isEmpty ? 0 : 1) + (followUps.isEmpty ? 0 : 1), room: room)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: PiSpacing.sm) {
                PiIconButton(symbol: session.queueCollapsed ? "chevron.right" : "chevron.down",
                             label: session.queueCollapsed ? "Show waiting messages" : "Hide waiting messages", size: 20) {
                    session.queueCollapsed.toggle()
                }.accessibilityIdentifier("queue-collapse")
                Label(timing.header(count: items.count), systemImage: timing == .editing ? "pause.circle" : "tray.full")
                    .font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                    .accessibilityIdentifier("queue-status")
                if !session.queueCollapsed, followUps.count > 1, session.queueEditHold == nil { Text("Drag to reorder").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                Spacer()
                if session.canResumeQueue {
                    let held = session.queueEditHold != nil
                    Button { model.action("queue.resume", sessionID: session.id) } label: { Label(session.queuePaused ? "Resume" : "Send queued", systemImage: "play.fill") }.buttonStyle(.piSecondaryCompact)
                        .disabled(held).help(held ? "Finish or cancel the queued edit first" : "")
                        .accessibilityHint(held ? "Finish or cancel the queued edit first" : "")
                }
            }
            if !session.queueCollapsed {
                List {
                    // Headings are plain rows on the panel's own background,
                    // not sticky list headers with a bar of their own.
                    if !steering.isEmpty {
                        sectionHeader(timing.steering).refQueueRowInsets().moveDisabled(true)
                        ForEach(steering) { item in row(item, index: nil).refQueueRowInsets().moveDisabled(true) }
                    }
                    if !followUps.isEmpty {
                        sectionHeader(timing.followUps).refQueueRowInsets().moveDisabled(true)
                        ForEach(Array(followUps.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index + 1).refQueueRowInsets()
                        }
                        .onMove(perform: session.queueEditHold != nil ? nil : { source, destination in
                            model.reorderQueued(QueuePanel.reordered(followUps.map(\.id), moving: source, to: destination), sessionID: session.id)
                        })
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .scrollDisabled(listHeight >= CGFloat(items.count) * QueuePanel.rowHeight + CGFloat((steering.isEmpty ? 0 : 1) + (followUps.isEmpty ? 0 : 1)) * QueuePanel.sectionHeaderHeight)
                // Its height, unless the pane can't fit it: then less, down to
                // one row with its heading, so every message stays reachable
                // by scrolling; the panel can be collapsed for the rest.
                .frame(minHeight: min(listHeight, QueuePanel.rowHeight + QueuePanel.sectionHeaderHeight), idealHeight: listHeight, maxHeight: listHeight)
                .accessibilityIdentifier("queue-follow-ups")
                .transition(.opacity)
            }
        }
        .padding(PiSpacing.md)
        .background(Color.piSurfaceSunken, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        // On the panel, not the row: a message that leaves while its detail
        // is open takes no popover with it; the detail says it left. Closing
        // is written after the update that asked for it.
        .popover(isPresented: Binding(get: { session.queueDetailID != nil },
                                      set: { open in if !open { DispatchQueue.main.async { session.queueDetailID = nil } } }), arrowEdge: .top) {
            RefQueuedMessageDetail(model: model, session: session, turnID: session.queueDetailID ?? "")
        }
        .piAnimation(PiMotion.quick, value: session.queueCollapsed)
    }
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(PiFont.micro.weight(.semibold)).foregroundStyle(Color.piInkTertiary)
            .frame(maxWidth: .infinity, minHeight: QueuePanel.sectionHeaderHeight - 4, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
    @ViewBuilder private func row(_ item: QueuedMessage, index: Int?) -> some View {
        let editing = session.queueEditingID == item.id
        // Held by an edit this composer does not own: one a restart left.
        let heldElsewhere = !editing && session.queueEditHold?.turnID == item.id
        // Which message a row's buttons act on, for VoiceOver.
        let spoken = item.steering ? "steering message" : "follow-up \(index ?? 0)"
        HStack(spacing: PiSpacing.sm) {
            if item.steering {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.piAccent).frame(width: 14)
                    .accessibilityHidden(true)
            } else {
                Text(index.map(String.init) ?? "").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).frame(width: 14)
                    .accessibilityHidden(true)
            }
            Text(item.title).lineLimit(1).font(PiFont.body).foregroundStyle(editing ? Color.piInkTertiary : Color.piInk)
            Spacer()
            PiIconButton(symbol: "info.circle", label: "Show the whole message and its model choices", size: 22,
                         spokenLabel: "Show the whole " + spoken + " and its model choices") { session.queueDetailID = item.id }
                .accessibilityIdentifier("queue-detail-" + item.id)
            if editing {
                Label("Editing in the composer", systemImage: "pencil.line").font(PiFont.caption).foregroundStyle(Color.piAccent)
                    .accessibilityIdentifier("queue-editing-" + item.id)
            } else if heldElsewhere, let hold = session.queueEditHold {
                Label("Edit open", systemImage: "pause.circle").font(PiFont.caption).foregroundStyle(Color.piAccent)
                Button("Resume Edit") { model.editQueued(item.id, sessionID: session.id, resuming: hold.editID) }.buttonStyle(.piGhost)
                    .disabled(session.queueEditCancelling == hold.editID)
                    .accessibilityIdentifier("queue-resume-edit-" + item.id)
                Button("Cancel Edit") { model.cancelHeldQueueEdit(sessionID: session.id) }.buttonStyle(.piGhost)
                    .accessibilityIdentifier("queue-cancel-edit-" + item.id)
            } else {
                if !item.steering && session.busy && session.queueEditHold == nil {
                    PiIconButton(symbol: "arrow.turn.up.right", label: "Steer the current run with this message", size: 22,
                                 spokenLabel: "Steer the current run with " + spoken) {
                        model.action("queue.steer", params: ["turnId": .string(item.id)], sessionID: session.id)
                    }.help("Deliver after the current tool batch instead of after the run")
                }
                if session.queueEditPreparing == item.id {
                    PiSpinner(controlSize: .mini).frame(width: 22).help("Pausing the queue and reading the whole message")
                } else {
                    PiIconButton(symbol: "pencil", label: "Edit queued message", size: 22, spokenLabel: "Edit " + spoken) { model.editQueued(item.id, sessionID: session.id) }
                        .disabled(session.queueEditHold != nil)
                }
            }
            PiIconButton(symbol: "xmark", label: "Remove", size: 22, spokenLabel: "Remove " + spoken) {
                // The message being rewritten goes with its hold, in one step.
                if editing { model.removeQueuedEdit(sessionID: session.id) }
                else { model.action("queue.remove", params: ["turnId": .string(item.id)], sessionID: session.id) }
            }.disabled((session.queueEditResolving && editing) || heldElsewhere)
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .contain)
        // The message's text is its own element in the row; the group only
        // says which message it is.
        .accessibilityLabel(item.steering ? "Steering message" : "Follow-up \(index ?? 0)")
        .accessibilityIdentifier("queue-item-" + item.id)
    }
}

private extension View {
    func refQueueRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}

/// A waiting message, whole, with the model choices it was queued with.
/// Reading it takes no hold and leaves the composer alone.
struct RefQueuedMessageDetail: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    let turnID: String
    @State private var whole: String?
    @State private var readFailed = false
    var body: some View {
        let item = QueuedMessage.from(session.queue).first { $0.id == turnID }
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            if let item {
                Text(item.steering ? "Steering message" : "Follow-up").font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInkSecondary)
                ScrollView {
                    Text(whole ?? item.text).font(PiFont.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("queue-detail-text")
                }.frame(maxHeight: 220)
                if item.truncated && whole == nil {
                    Text(readFailed ? "Only the start of the message could be read." : "Reading the whole message…").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                }
                Divider()
                detailRow("Model", item.model ?? "Connection default")
                detailRow("Reasoning", item.thinkingLevel.map { $0 == "default" ? "Model default" : $0.capitalized } ?? "Connection default")
                if let window = item.contextWindow { detailRow("Context", "\(window.formatted()) tokens") }
                if let output = item.maxOutputTokens { detailRow("Output budget", "\(output.formatted()) tokens") }
            } else {
                Text(QueuedMessageDetailView.goneText).font(PiFont.body).foregroundStyle(Color.piInkSecondary)
                    .accessibilityIdentifier("queue-detail-gone")
            }
        }
        .padding(PiSpacing.md).frame(width: 340)
        // What the detail shows, for the chat to read back (tests, and the
        // row's own label): the message, or that it is no longer waiting.
        .onChange(of: item.map { whole ?? $0.text } ?? QueuedMessageDetailView.goneText, initial: true) { _, shown in
            if session.queueDetailShowing != shown { session.queueDetailShowing = shown }
        }
        .onDisappear { session.queueDetailShowing = nil }
        // Keyed by what the row now says: a rewrite saved while the detail
        // is open reads the message again, and an older read is dropped.
        .task(id: item.map(\.contentKey)) {
            whole = nil; readFailed = false
            guard let item, item.truncated else { return }
            let key = item.contentKey
            do {
                let text = try await model.queuedMessageText(turnID: turnID, sessionID: session.id)
                guard !Task.isCancelled, QueuedMessage.from(session.queue).first(where: { $0.id == turnID })?.contentKey == key else { return }
                whole = text
            } catch { if !Task.isCancelled { readFailed = true } }
        }
    }
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Color.piInkSecondary); Spacer(); Text(value).foregroundStyle(Color.piInk) }
            .font(PiFont.caption).accessibilityElement(children: .combine)
    }
}

