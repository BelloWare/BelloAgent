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


// MARK: - The terminal panel (Workspaces/TerminalPanel.swift before batch 5b)

private struct RefTerminalHost: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        let view = session.view
        // Switching projects used to leave the previous project's terminal
        // stacked underneath this one, still in the window and still drawing.
        for other in container.subviews where other !== view { other.removeFromSuperview() }
        if view.superview !== container {
            view.removeFromSuperview()
            view.frame = container.bounds; view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        session.applyColors()
    }
}

/// The panel under the transcript: the project's terminals as tabs, a new
/// one, and the shown one's name, shell title, rename, restart and close,
/// then the terminal. Height drags on its top edge and is remembered.
struct RefTerminalPanel: View {
    @ObservedObject var model: WorkspaceModel
    let workspace: WorkspaceRecord
    @ObservedObject private var registry = TerminalRegistry.shared
    @AppStorage("terminalHeight") private var storedHeight: Double = 240
    @State private var dragging: CGFloat?
    @State private var startHeight: CGFloat?
    /// The window this panel is in, for its questions.
    @State private var window: NSWindow?
    @State private var tabsWidth: CGFloat = 0
    @State private var headerWidth: CGFloat = 0
    @State private var controlsWidth: CGFloat = 0
    private struct TabsWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    private struct HeaderWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    private struct ControlsWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    private var height: CGFloat { TerminalPanel.clampHeight(dragging ?? CGFloat(storedHeight)) }
    private var session: TerminalSession? { registry.selected(for: workspace.id) }
    private var sessions: [TerminalSession] { registry.sessions(for: workspace.id) }
    /// What the keyboard follows: the shown terminal, and its restarts.
    private var shown: String { session.map { "\($0.id)/\($0.generation)" } ?? "none" }

    var body: some View {
        VStack(spacing: 0) {
            PiResizeHandle(orientation: .horizontal, label: "Resize terminal",
                           hint: "Drag up or down",
                           dragging: dragging != nil,
                           changed: { translation in
                               let base = startHeight ?? height
                               if startHeight == nil { startHeight = height }
                               dragging = TerminalPanel.clampHeight(base - translation)
                           },
                           ended: { translation in
                               storedHeight = Double(TerminalPanel.clampHeight((startHeight ?? height) - translation))
                               startHeight = nil; dragging = nil
                           })
            header.padding(.horizontal, PiSpacing.md).padding(.vertical, 5).background(Color.piWindow)
            if let session {
                // Its height, unless the pane can't fit it: then less, down to
                // its minimum, never pushing the window taller. The height it
                // was dragged to is kept for when there is room again.
                RefTerminalHost(session: session).frame(minHeight: min(height, TerminalPanel.minimumHeight), idealHeight: height, maxHeight: height)
            } else {
                ZStack {
                    Color.piTerminalSurface
                    VStack(spacing: PiSpacing.sm) {
                        Text("No terminals in this project").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        Button { registry.create(for: workspace) } label: { Label("New Terminal", systemImage: "plus") }
                            .buttonStyle(.piSecondaryCompact)
                    }
                }.frame(minHeight: min(height, TerminalPanel.minimumHeight), idealHeight: height, maxHeight: height)
            }
        }
        .background(HostingWindowReader { window = $0 })
        .onAppear {
            registry.ensureInitialSession(for: workspace)
            DispatchQueue.main.async { session?.focus() }
        }
        .onChange(of: workspace.id) { _, _ in
            // The old project's view leaves the window with the keyboard, so
            // the new project's shell has to be given it back.
            registry.ensureInitialSession(for: workspace)
            DispatchQueue.main.async { session?.focus() }
        }
        .onChange(of: shown) { _, _ in DispatchQueue.main.async { session?.focus() } }
        .accessibilityIdentifier("terminal-panel")
    }

    private var projectName: some View {
        Text((workspace.path as NSString).lastPathComponent).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.middle)
    }
    @ViewBuilder private var header: some View {
        HStack(spacing: PiSpacing.sm) {
            Image(systemName: "terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piInkSecondary)
                .accessibilityHidden(true)
            if !sessions.isEmpty {
                ScrollViewReader { proxy in
                    // As wide as the tabs, up to a limit past which they scroll,
                    // so the buttons after them always stay in reach.
                    ScrollView(.horizontal, showsIndicators: false) {
                        PiTabs(selection: Binding(get: { session?.id ?? UUID() }, set: { registry.select($0, in: workspace.id) }),
                               items: sessions.map { ($0.id, $0.displayName) },
                               accessibilityName: "Terminals in \((workspace.path as NSString).lastPathComponent)")
                            .background(GeometryReader { Color.clear.preference(key: TabsWidth.self, value: $0.size.width) })
                    }
                    .frame(width: min(max(tabsWidth, 1), tabsRoom))
                    // A row that scrolls fades at its end, so it reads as more.
                    .mask {
                        HStack(spacing: 0) {
                            Color.black
                            if tabsWidth > tabsRoom { LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24) }
                        }
                    }
                    .onPreferenceChange(TabsWidth.self) { tabsWidth = $0 }
                    .onChange(of: session?.id) { _, id in if let id { withAnimation(PiMotion.quick) { proxy.scrollTo(id) } } }
                    // Shown again with a terminal past the row's end chosen: in view.
                    .onAppear { if let id = session?.id { DispatchQueue.main.async { proxy.scrollTo(id) } } }
                }
            }
            PiIconButton(symbol: "plus", label: "New terminal", size: 22) { registry.create(for: workspace) }
                .help("Open another terminal in this project")
            // The shell's title and the project folder give way, whole, to
            // the buttons when the pane is narrow.
            ViewThatFits(in: .horizontal) {
                // The folder name may shorten, down to a few letters, before it goes.
                HStack(spacing: PiSpacing.sm) { RefShellTitle(session: session); projectName.frame(minWidth: 40, idealWidth: 40, maxWidth: 320, alignment: .leading) }
                RefShellTitle(session: session)
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: PiSpacing.sm)
            HStack(spacing: PiSpacing.sm) {
                RefShellState(session: session)
                if let session {
                    // The terminal as it is when clicked: a click that waited
                    // behind a restart doesn't act on the new shell.
                    let id = session.id, generation = session.generation
                    let name = session.displayName
                    PiIconButton(symbol: "pencil", label: "Rename terminal", size: 22, spokenLabel: "Rename " + name) {
                        Task { await registry.requestRename(id, generation: generation, in: workspace.id, over: window) }
                    }.help("Give this terminal a name of your own")
                    PiIconButton(symbol: "arrow.clockwise", label: "Restart terminal", size: 22, spokenLabel: "Restart " + name) {
                        Task { await registry.requestEnding(.restart, id, generation: generation, in: workspace, over: window) }
                    }.help("Starts a new shell in this terminal. Its scrollback is removed. Asks first while the shell is running.")
                    PiIconButton(symbol: "trash", label: "Close terminal", size: 22, spokenLabel: "Close " + name) {
                        Task { await registry.requestEnding(.close, id, generation: generation, in: workspace, over: window) }
                    }.help("Ends this terminal's shell and removes its output. Asks first while the shell is running.")
                }
                PiIconButton(symbol: "xmark", label: "Hide terminal (⌃`)", size: 22) { model.toggleTerminal() }
                    .help("Hide the terminals; they keep running")
            }
            .fixedSize()
            .background(GeometryReader { Color.clear.preference(key: ControlsWidth.self, value: $0.size.width) })
        }
        .background(GeometryReader { Color.clear.preference(key: HeaderWidth.self, value: $0.size.width) })
        .onPreferenceChange(ControlsWidth.self) { controlsWidth = $0 }
        .onPreferenceChange(HeaderWidth.self) { headerWidth = $0 }
    }
    /// How wide the tab row may be: its tabs, but never more than leaves room
    /// for the icon, New and the controls after it; at least one tab's worth.
    private var tabsRoom: CGFloat {
        let others = controlsWidth + 16 + 22 + PiSpacing.sm * 5
        let room = headerWidth > 0 ? headerWidth - others : TerminalPanel.tabsLimit
        return max(72, min(TerminalPanel.tabsLimit, room))
    }
}

/// The shown terminal's shell title, observed on the session itself so the
/// header follows the shell as it renames its window.
private struct RefShellTitle: View {
    let session: TerminalSession?
    var body: some View { if let session { Observed(session: session) } }
    private struct Observed: View {
        @ObservedObject var session: TerminalSession
        var body: some View {
            if !session.shellTitle.isEmpty {
                Text(session.shellTitle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).fixedSize()
            }
        }
    }
}

/// Whether the shown terminal's shell exited or failed, which always shows.
private struct RefShellState: View {
    let session: TerminalSession?
    var body: some View { if let session { Observed(session: session) } }
    private struct Observed: View {
        @ObservedObject var session: TerminalSession
        var body: some View {
            // A short badge, so the buttons beside it stay in reach in a narrow
            // pane; the whole message is its help and what VoiceOver reads.
            if let failure = session.failure {
                PiBadge(text: "Terminal error", tone: .danger).help(failure)
                    .accessibilityElement(children: .ignore).accessibilityLabel("Terminal error: " + failure)
            }
            else if session.exited { PiBadge(text: "Shell exited", tone: .warning) }
        }
    }
}

// MARK: - The tab strip (Tabs/TabStrip.swift before batch 6; pointer and drop views left out)

struct RefTabStrip: View {
    @ObservedObject var host: TabHost
    @ObservedObject var container: TabContainer
    /// The chat's side, in the pane when the chat has one.
    let side: SideTabItem?
    /// Room before the first tab: a window's buttons.
    var leadingInset: CGFloat = PiSpacing.sm
    static let height: CGFloat = 36
    @State private var frames: [String: CGRect] = [:]
    @State private var insertion: Int?

    private static let sideID = "side"
    private var shownID: String? {
        container.shownTab(sideAvailable: side != nil).map { $0.id.uuidString } ?? (side != nil ? Self.sideID : nil)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    if let side {
                        RefTabStripItem(title: side.title, symbol: "arrow.triangle.branch", help: side.help, selected: shownID == Self.sideID, closable: false,
                                     events: RefTabItemEvents(select: { host.showSide() }))
                            .id(Self.sideID)
                    }
                    ForEach(Array(container.tabs.enumerated()), id: \.element.id) { index, tab in
                        RefTabStripTabItem(tab: tab, selected: shownID == tab.id.uuidString, insertionBefore: insertion == index,
                                        events: events(for: tab))
                            .id(tab.id.uuidString)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: RefTabFramesKey.self, value: [tab.id.uuidString: geometry.frame(in: .global)])
                            })
                    }
                    if insertion == container.tabs.count { RefTabInsertionMark() }
                }
                .padding(.leading, leadingInset).padding(.trailing, PiSpacing.sm)
                .frame(height: Self.height)
            }
            .onAppear { if let shownID { proxy.scrollTo(shownID) } }
            .onChange(of: shownID) { _, shown in if let shown { proxy.scrollTo(shown) } }
        }
        .onPreferenceChange(RefTabFramesKey.self) { frames = $0 }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.piContent)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.piHairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(container.isPane ? "Tabs beside the chat" : "Tabs")
    }

    private func events(for tab: HostedTab) -> RefTabItemEvents {
        RefTabItemEvents(select: { host.activate(tab) }, close: { host.close(tab) }, menu: { [weak host] in
            guard let host else { return [] }
            var entries: [PiMenuEntry] = [.button("Close Tab", identifier: "tab-close") { host.close(tab) }]
            if tab.container?.tabs.count ?? 0 > 1 { entries.append(.button("Close Other Tabs", identifier: "tab-close-others") { host.closeOthers(than: tab) }) }
            entries.append(.separator)
            if tab.container?.isPane == true { entries.append(.button("Open in Window", identifier: "tab-pop-out") { host.popOut(tab) }) }
            else { entries.append(.button("Move to Pane", identifier: "tab-to-pane") { host.moveToPane(tab) }) }
            let own = tab.menuEntries()
            if !own.isEmpty { entries.append(.separator); entries.append(contentsOf: own) }
            return entries
        }, drag: { tab.id.uuidString }, poppedOut: { [weak host] point in host?.popOut(tab, at: point) })
    }
    /// Where a tab dropped at a point along the strip goes: before the first
    /// tab whose middle is right of it.
    private func index(atWindowX x: CGFloat) -> Int {
        for (index, tab) in container.tabs.enumerated() {
            if let frame = frames[tab.id.uuidString], x < frame.midX { return index }
        }
        return container.tabs.count
    }
}

private struct RefTabFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Where a dragged tab would go.
private struct RefTabInsertionMark: View {
    var body: some View { Capsule().fill(Color.piAccent).frame(width: 2, height: 20) }
}

/// A hosted tab, following its title and symbol as they change.
private struct RefTabStripTabItem: View {
    @ObservedObject var tab: HostedTab
    let selected: Bool
    let insertionBefore: Bool
    let events: RefTabItemEvents
    var body: some View {
        HStack(spacing: 3) {
            if insertionBefore { RefTabInsertionMark() }
            RefTabStripItem(title: tab.title, symbol: tab.symbol, help: tab.help, selected: selected, closable: true, events: events)
        }
    }
}

/// What a tab does with the pointer: shown on a click, closed by a middle
/// click, its menu on a secondary click, and dragged.
struct RefTabItemEvents {
    var select: () -> Void
    var close: (() -> Void)? = nil
    var menu: (() -> [PiMenuEntry])? = nil
    /// What a drag carries: the tab's id; nil for a tab that stays put.
    var drag: (() -> String)? = nil
    /// Let go of outside every strip: a window of its own, there.
    var poppedOut: ((NSPoint) -> Void)? = nil
}

struct RefTabStripItem: View {
    let title: String
    let symbol: String
    let help: String
    let selected: Bool
    let closable: Bool
    let events: RefTabItemEvents
    @State private var hovering = false
    @State private var closeHovering = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.piAccent : Color.piInkTertiary)
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.piInk : Color.piInkSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, 10).padding(.trailing, closable ? 4 : 10)
            .frame(height: 26)
            .contentShape(Rectangle())
            
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { events.select() }
            if closable, let close = events.close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(closeHovering ? Color.piInk : Color.piInkTertiary)
                        .frame(width: 16, height: 16)
                        .background(closeHovering ? Color.piFillStrong : Color.clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).piPointer()
                .onHover { closeHovering = $0 }
                .opacity(selected || hovering ? 1 : 0)
                .padding(.trailing, 6)
                .help("Close Tab (⌘W)")
                .accessibilityLabel("Close \(title)")
            }
        }
        .frame(maxWidth: 240)
        .background(selected ? Color.piSurface : hovering ? Color.piFill : Color.clear, in: shape)
        .overlay(shape.stroke(selected ? Color.piHairlineStrong : Color.clear, lineWidth: 1))
        .onHover { hovering = $0 }
        .piAnimation(PiMotion.quick, value: hovering)
        .help(help)
    }
}


// MARK: - TopicSheet.swift before batch 7

/// A topic is local organization within a project; creating one neither opens
/// a session nor changes a session's working directory or model.
struct RefTopicSheet: View {
    @ObservedObject var model: WorkspaceModel
    let target: TopicEditorTarget
    @State private var title = ""
    @State private var saving = false
    @State private var notice = ""
    @PiDismiss private var dismiss
    private var editing: Bool { target.topicID != nil }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        PiSheet(editing ? "Rename topic" : "New topic", subtitle: "Group related chats inside this project.", symbol: "folder", width: 480, height: 260, cancelDisabled: saving) {
            VStack(alignment: .leading, spacing: PiSpacing.md) {
                PiTextField(placeholder: "Topic name", text: $title, icon: "folder", onSubmit: save)
                    .accessibilityLabel("Topic name").accessibilityIdentifier("topicTitle")
                Text("Topics keep chats together without changing their context or project folders.")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                PiStatusLine(text: notice, tone: .danger)
            }.padding(PiSpacing.xl)
        } actions: {
            Button("Cancel") { dismiss() }.disabled(saving)
        } footer: {
            HStack {
                Spacer()
                Button(saving ? "Saving…" : editing ? "Rename" : "Create Topic", action: save)
                    .buttonStyle(.piPrimary).disabled(saving || trimmedTitle.isEmpty)
                    .accessibilityIdentifier("saveTopic")
            }
        }
        .onAppear { if let id = target.topicID { title = model.topics.first { $0.id == id }?.title ?? "" } }
    }
    private func save() {
        guard !saving, !trimmedTitle.isEmpty else { return }
        saving = true; notice = ""
        let value = trimmedTitle
        Task {
            defer { saving = false }
            do {
                if let id = target.topicID { try await model.renameTopic(id, title: value) }
                else { _ = try await model.createTopic(in: target.projectID, title: value) }
                dismiss()
            } catch { notice = error.localizedDescription }
        }
    }
}

// MARK: - RenameChatSheet.swift before batch 7

/// Rename a chat by hand or from three mini-model suggestions drawn from its
/// first message. Suggestions need the connection's mini model, like titles.
struct RefRenameChatSheet: View {
    @ObservedObject var model: WorkspaceModel
    let chatID: String
    @State private var title = ""
    @State private var suggestions: [String] = []
    @State private var suggesting = false
    @State private var notice = ""
    @State private var saving = false
    /// A suggestion asked for with the button; it ends with the sheet.
    @State private var requested: Task<Void, Never>?
    @PiDismiss private var dismiss
    private var chat: ChatRecord? { model.record(chatID) }
    private var canSuggest: Bool { chat.flatMap { item in model.profiles.first { $0.id == item.profileID } }.map { model.titleSuggestionsAvailable(for: $0) } ?? false }

    var body: some View {
        PiSheet("Rename chat", subtitle: chat?.title, symbol: "pencil", width: 520, height: 400, cancelDisabled: saving) {
            VStack(alignment: .leading, spacing: PiSpacing.md) {
                PiTextField(placeholder: "Chat title", text: $title, icon: "text.cursor", onSubmit: { save() })
                    .accessibilityIdentifier("sessionTitle")
                HStack {
                    Text("Suggestions").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
                    Spacer()
                    if suggesting { PiSpinner(controlSize: .small) }
                    Button { requested?.cancel(); requested = Task { await suggest() } } label: { Label(suggestions.isEmpty ? "Suggest titles" : "Suggest again", systemImage: "sparkles") }
                        .buttonStyle(.piSecondaryCompact).disabled(suggesting || !canSuggest)
                        .help(canSuggest ? "Ask the connection's mini model for three titles" : "Suggestions need a mini model for this connection; choose one in Settings.")
                }
                if suggestions.isEmpty {
                    Text(canSuggest ? (suggesting ? "Asking the mini model…" : "The mini model reads the first message and proposes three titles.") : "Choose a mini model for this connection in Settings to get suggestions.")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 4) {
                        // The three titles arrive one after another.
                        ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                            PiSelectableRow(selected: title == suggestion, action: { title = suggestion }) {
                                HStack { Text(suggestion).font(PiFont.body).foregroundStyle(Color.piInk).lineLimit(2); Spacer() }
                            }.accessibilityIdentifier("title-suggestion").piStaggered(index)
                        }
                    }
                    .transition(.opacity)
                }
                PiStatusLine(text: notice, tone: .danger)
            }.padding(PiSpacing.xl)
        } actions: {
            Button("Cancel") { dismiss() }.disabled(saving)
        } footer: {
            HStack {
                Spacer()
                Button(saving ? "Renaming…" : "Rename") { save() }.buttonStyle(.piPrimary)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { title = chat?.title ?? "" }
        // The suggestions are a request to the mini model that polls for its
        // answer. They belong to the sheet: closing it cancels them, where an
        // unowned task went on polling for up to 45 seconds.
        .task { if canSuggest { await suggest() } }
        .onDisappear { requested?.cancel() }
    }

    private func suggest() async {
        guard !suggesting else { return }
        suggesting = true; notice = ""
        defer { suggesting = false }
        do { suggestions = try await model.suggestTitles(for: chatID) }
        catch { notice = error.localizedDescription }
    }

    private func save() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await model.setSessionTitle(chatID, title: value); dismiss() }
            catch { notice = error.localizedDescription }
        }
    }
}

// MARK: - WebhookPreviewSheet.swift before batch 7

/// Chat ⋯ ▸ Preview Webhook…: the request this chat sends when it finishes,
/// made now from the chat as it is, the mini model's parameters included.
/// Send Now tries it against the address.
struct RefWebhookPreviewSheet: View {
    @ObservedObject var model: WorkspaceModel
    let chatID: String
    @State private var preparation: WebhookPreparation?
    @State private var preparing = false
    @State private var sending = false
    @State private var showsPrompt = false
    @State private var notice = ""
    @State private var tone: PiTone = .neutral
    /// A request asked for with Ask Again; it ends with the sheet.
    @State private var requested: Task<Void, Never>?
    @PiDismiss private var dismiss
    private var chat: ChatRecord? { model.chatRecord(chatID) }
    private var settings: WebhookSettings? { model.activeWebhook }

    var body: some View {
        PiSheet("Webhook preview", subtitle: chat?.title, symbol: "paperplane", width: 640, height: 660, cancelDisabled: sending) {
            ScrollView {
                VStack(alignment: .leading, spacing: PiSpacing.lg) {
                    if settings == nil {
                        PiNote("The webhook is off. Turn it on in Settings → Chats & notifications.", tone: .warning)
                    } else if chat?.webhookOff == true {
                        PiNote("This chat sends no webhook when it finishes; its ⋯ menu turns it back on. Send Now still sends this one.", tone: .warning)
                    }
                    if preparing {
                        HStack(spacing: PiSpacing.sm) {
                            PiSpinner(controlSize: .small)
                            Text("Asking the mini model…").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        }
                    }
                    if let preparation { request(preparation) }
                    PiStatusLine(text: notice, tone: tone)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PiSpacing.xl)
            }
        } actions: {
            Button("Close") { dismiss() }.disabled(sending)
        } footer: {
            HStack(spacing: PiSpacing.sm) {
                Button { requested?.cancel(); requested = Task { await prepare() } } label: { Label("Ask Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.piSecondaryCompact).fixedSize()
                    .disabled(preparing || sending || settings == nil)
                    .help("Ask the mini model again and rebuild the request")
                Spacer(minLength: PiSpacing.md)
                Button(sending ? "Sending…" : "Send Now") { Task { await send() } }.buttonStyle(.piPrimary).fixedSize()
                    .disabled(preparation == nil || preparing || sending)
                    .help("Send this request to the webhook's address now")
                    .accessibilityIdentifier("webhook-preview-send")
            }
        }
        // The mini model's request belongs to the sheet: closing it ends the request.
        .task { await prepare() }
        .onDisappear { requested?.cancel() }
    }

    @ViewBuilder private func request(_ preparation: WebhookPreparation) -> some View {
        let request = preparation.request
        section("Request") {
            Text(request.method + " " + request.url.absoluteString).font(PiFont.mono).foregroundStyle(Color.piInk)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("webhook-preview-address")
        }
        if !request.headers.isEmpty {
            section("Headers") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(request.headers.enumerated()), id: \.offset) { _, header in
                        Text(header.name + ": " + header.value).font(PiFont.mono).foregroundStyle(Color.piInk)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if request.body != nil {
            section("Body") {
                Text(request.bodyText).font(PiFont.mono).foregroundStyle(Color.piInk)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("webhook-preview-body")
            }
        }
        if !request.unknown.isEmpty {
            PiNote("Nothing fills " + request.unknown.map { "{{\($0)}}" }.joined(separator: ", ") + "; sent empty.", tone: .warning)
        }
        if !preparation.parameters.isEmpty {
            section(preparation.model.map { "Written by the mini model · " + $0 } ?? "Written by the mini model") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(preparation.parameters.enumerated()), id: \.offset) { _, parameter in
                        HStack(alignment: .firstTextBaseline, spacing: PiSpacing.md) {
                            Text(parameter.name).font(PiFont.mono).foregroundStyle(Color.piInkSecondary).frame(width: 120, alignment: .leading)
                            Text(parameter.value.isEmpty ? "—" : parameter.value).font(PiFont.caption).foregroundStyle(Color.piInk)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    if let note = preparation.modelNote {
                        PiNote(note + " The chat's title stands in for title; other parameters are sent empty.", tone: .warning)
                    } else if !preparation.missing.isEmpty {
                        PiNote("The mini model left out " + preparation.missing.joined(separator: ", ") + "; the chat's title stands in for title, and the rest are sent empty.", tone: .warning)
                    }
                    if let prompt = preparation.prompt {
                        Button { withAnimation(PiMotion.quick) { showsPrompt.toggle() } } label: {
                            Label(showsPrompt ? "Hide what the mini model was asked" : "Show what the mini model was asked", systemImage: showsPrompt ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.piGhost).fixedSize()
                        if showsPrompt {
                            Text(prompt + (preparation.reply.map { "\n\n— Reply —\n" + $0 } ?? "")).font(PiFont.mono).foregroundStyle(Color.piInkSecondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .padding(PiSpacing.md).frame(maxWidth: .infinity, alignment: .leading).piInset(sunken: true)
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            Text(title).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
            content().padding(PiSpacing.md).frame(maxWidth: .infinity, alignment: .leading).piInset(sunken: true)
        }
    }

    private func prepare() async {
        guard let settings, !preparing else { return }
        preparing = true; notice = ""
        defer { preparing = false }
        do { preparation = try await model.prepareWebhook(for: chatID, settings: settings) }
        catch is CancellationError {}
        catch { notice = error.localizedDescription; tone = .danger }
    }

    private func send() async {
        guard let request = preparation?.request, !sending else { return }
        sending = true; notice = ""
        defer { sending = false }
        do {
            let status = try await model.deliverWebhook(request)
            notice = "Sent. \(request.url.host ?? "The address") answered HTTP \(status)."; tone = .success
        } catch {
            notice = "Not sent: " + error.localizedDescription; tone = .danger
        }
    }
}

// MARK: - SidePane and SideHandoff (WorkspaceSides.swift before batch 7)

struct RefSidePane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    let info: SideRecord
    /// The share of the content column this side has, for the composer bar.
    let paneWidth: CGFloat
    @State private var handoff = false
    var body: some View {
        // The hairline that used to start this pane is the split's draggable
        // divider now, drawn once by the workspace between the two panes.
        ConversationPane(model: model, session: session, chat: model.record(info.id) ?? info.chat, paneWidth: paneWidth, side: info,
                         sideActions: SideActions(bringBack: { handoff = true }, keep: { model.keepSide(info.id) }, close: { model.closeSide(info.id) }))
        .piSheetWindow(isPresented: $handoff) { RefSideHandoff(model: model, session: session) }
    }
}
struct RefSideHandoff: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @State private var text = ""
    @State private var error = ""
    @PiDismiss private var dismiss
    var body: some View {
        PiSheet("Bring back to parent draft", subtitle: "Edit this summary or selection. Bringing it back only changes the parent draft; review it before sending.", symbol: "arrow.uturn.backward", width: 720, height: 480) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                NativeCodeEditor(text: $text, accessibilityLabel: "Editable side summary").piInset().frame(maxHeight: .infinity)
                PiStatusLine(text: error, tone: .danger)
            }.padding(PiSpacing.xl)
        } actions: {
            Button("Cancel") { dismiss() }
        } footer: {
            HStack {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Spacer()
                Button("Replace Parent Draft") { insert(replace: true) }
                Button("Insert in Parent Draft") { insert(replace: false) }.buttonStyle(.piPrimary)
            }.disabled(text.isEmpty)
        }
        .onAppear { text = session.messages.last(where: { $0.role == "assistant" && !$0.isStreaming })?.text ?? "" }
    }
    private func insert(replace: Bool) { do { try model.bringBack(text, from: session.id, replace: replace); dismiss() } catch { self.error = error.localizedDescription } }
}

// MARK: - CatalogModelPicker.swift before batch 8

/// A live native catalog view. Unlike a tracking NSMenu snapshot, its contents
/// update while a fetch is in flight. Opening it always checks the source's TTL,
/// whether invoked with the pointer or keyboard. Search includes every model,
/// not just a first menu page.
struct RefCatalogModelPicker: View {
    /// A connection as the Settings sheet edits it: listed on its own, with the key typed there.
    struct DraftListing: Equatable { var profile: ProfileRecord; var key: String }
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var catalog: ModelCatalog
    let profile: ProfileRecord
    let current: String?
    var draft: DraftListing? = nil
    var allowsCatalogSelection = false
    var defaultTitle: String?
    var defaultSelected = false
    var useDefault: (() -> Void)?
    /// Called with an alias typed into the picker; empty means the connection default.
    var manualEntry: ((String) -> Void)?
    let choose: (ModelDescriptor) -> Void
    @State private var query = ""
    @State private var enteringAlias = false
    @State private var alias = ""
    @StateObject private var refresh = ModelCatalogRefreshState()

    init(model: WorkspaceModel, profile: ProfileRecord, current: String?, draft: DraftListing? = nil, allowsCatalogSelection: Bool = false,
         defaultTitle: String? = nil, defaultSelected: Bool = false,
         useDefault: (() -> Void)? = nil, manualEntry: ((String) -> Void)? = nil,
         choose: @escaping (ModelDescriptor) -> Void) {
        self.model = model; self.catalog = model.modelCatalog; self.profile = profile; self.draft = draft
        self.current = current; self.defaultTitle = defaultTitle; self.defaultSelected = defaultSelected
        self.allowsCatalogSelection = allowsCatalogSelection
        self.useDefault = useDefault; self.manualEntry = manualEntry; self.choose = choose
    }

    var body: some View {
        // A popover can outlive a Settings/vault reload. Resolve only its own
        // saved ID, so its rows and source label follow the newly saved revision.
        // A draft being edited in Settings is listed as given, with the typed key.
        let profile = draft == nil ? (model.profiles.first(where: { $0.id == self.profile.id }) ?? self.profile) : self.profile
        let source = draft == nil ? model.catalogProfile(for: profile) : self.profile
        let entry = catalog.entry(for: source)
        let offered = entry.offered(current: current)
        let matches = Self.filtered(offered, query: query)
        let loading = refresh.loading || entry.loading
        let repairs = allowsCatalogSelection ? model.catalogRepairChoices(for: profile) : []
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ModelCatalog.catalogConfigured(source) ? "Model catalog" : "Bello model catalog").font(.headline)
                    Text(source.name).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    Text(Self.sourceLabel(source)).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(2)
                        .accessibilityIdentifier("model-picker-source")
                }
                Spacer(minLength: 8)
                if loading { PiSpinner(controlSize: .small) }
                Button {
                    Task {
                        if let draft { await model.listModels(forDraft: draft.profile, typedKey: draft.key, force: true) }
                        else { await refresh.refresh(model: model, profileID: profile.id) }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(loading).help("Reload this saved connection and refresh its model list")
                    .accessibilityLabel("Refresh models")
                    .accessibilityIdentifier("refresh-model-catalog")
            }
            if allowsCatalogSelection, model.profiles.filter({ $0.api == LiteLLMConfiguration.supportedAPI }).count > 1 {
                if !repairs.isEmpty { catalogRepairNotice(profile: profile, choices: repairs, loading: loading) }
                sourceSelector(profile: profile, source: source, loading: loading)
            }
            PiTextField(placeholder: "Search model names or aliases", text: $query, icon: "magnifyingglass")
                .accessibilityIdentifier("model-catalog-search")
            if let defaultTitle, let useDefault {
                Button(action: useDefault) {
                    HStack {
                        Image(systemName: defaultSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(defaultSelected ? Color.piAccent : Color.piInkTertiary)
                        Text(defaultTitle).lineLimit(2)
                        Spacer()
                    }.font(PiFont.caption).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if let error = refresh.error ?? entry.error {
                VStack(alignment: .leading, spacing: 3) {
                    if !offered.isEmpty { Text("Refresh failed · showing the last list").fontWeight(.medium) }
                    Text(error)
                }.font(PiFont.caption).foregroundStyle(Color.piWarning).fixedSize(horizontal: false, vertical: true)
            }
            if matches.isEmpty {
                Text(loading ? "Loading models…" : offered.isEmpty ? "No models are listed by this connection." : "No matching models.")
                    .font(PiFont.body).foregroundStyle(Color.piInkSecondary).frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { item in
                            Button { choose(item) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: !defaultSelected && current == item.id ? "checkmark" : "cpu")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(!defaultSelected && current == item.id ? Color.piAccent : Color.piInkTertiary)
                                        .frame(width: 14).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                                            Text(item.displayName).font(PiFont.body).foregroundStyle(Color.piInk)
                                            if item.mini == true { Text("Mini").font(PiFont.caption).foregroundStyle(Color.piAccent) }
                                            if item.takesImages { Text("Images").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                                            if item.deprecated { Text("Deprecated").font(PiFont.caption).foregroundStyle(Color.piWarning) }
                                        }
                                        if item.displayName != item.id { Text(item.id).font(PiFont.mono).foregroundStyle(Color.piInkSecondary) }
                                        if !item.description.isEmpty { Text(item.description).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(2) }
                                        if let context = item.contextLabel { Text(context).font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }
                                        if let output = item.outputLimitLabel { Text(output).font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(!defaultSelected && current == item.id ? Color.piAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("catalog-choice-\(item.id)")
                            .accessibilityLabel(ModelSwitchPills.menuTitle(item))
                        }
                    }
                }.frame(height: min(340, CGFloat(matches.count) * 68))
            }
            if let current, !current.isEmpty, !offered.contains(where: { $0.id == current }), entry.fetchedAt != nil {
                Text("Current selection “\(current)” is not listed by this source. It remains selected until you choose another model.")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(offered.count) models").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                if !loading, entry.error == nil, let date = entry.fetchedAt {
                    Text("Updated \(date.formatted(date: .omitted, time: .standard))")
                        .font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                        .accessibilityIdentifier("model-catalog-refreshed-at")
                }
                Spacer()
                if manualEntry != nil { Button(enteringAlias ? "Hide alias field" : "Enter alias…") { withAnimation(PiMotion.quick) { enteringAlias.toggle() } }.buttonStyle(.plain).font(PiFont.caption).accessibilityIdentifier("model-enter-alias") }
            }
            if let manualEntry, enteringAlias {
                // Any alias the gateway routes, typed here; empty returns to the connection default.
                HStack(spacing: 6) {
                    PiTextField(placeholder: profile.modelId, text: $alias, icon: "cpu", mono: true, onSubmit: { manualEntry(alias.trimmingCharacters(in: .whitespacesAndNewlines)) })
                        .accessibilityIdentifier("model-alias-field")
                    Button("Use") { manualEntry(alias.trimmingCharacters(in: .whitespacesAndNewlines)) }.buttonStyle(.piPrimaryCompact).fixedSize()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !ModelCatalog.catalogConfigured(source) {
                Text("Included models change with app updates. Choose a saved custom catalog above or set its URL in Settings.")
                    .font(PiFont.caption).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 390).background(Color.piSurface)
        .task(id: [source.id, source.baseUrl, source.catalogUrl ?? "", draft?.key ?? ""]) {
            if let draft { await model.listModels(forDraft: draft.profile, typedKey: draft.key) } else { await model.listModels(for: profile) }
        }
        .onChange(of: profile.id) { _, _ in query = "" }
        .onChange(of: source.id) { _, _ in query = "" }
    }

    private func catalogRepairNotice(profile: ProfileRecord, choices: [ProfileRecord], loading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This chat uses its original model list.")
                .font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInk)
            Text("Another catalog is saved for this gateway. Refresh reloads the list shown above.")
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            if choices.count == 1, let candidate = choices.first {
                Text("Available: \(candidate.name) · \(Self.sourceLabel(candidate))")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(2)
                Button("Use this catalog") {
                    Task { await refresh.selectSource(model: model, sourceID: candidate.id, profileID: profile.id) }
                }.accessibilityIdentifier("repair-model-catalog")
            } else {
                PiMenuButton(title: "Choose a saved catalog", icon: "list.bullet.rectangle", identifier: "repair-model-catalog") { [refresh, model] in
                    for candidate in choices {
                        PiMenuEntry.button("\(candidate.name) · \(Self.sourceLabel(candidate))") {
                            Task { await refresh.selectSource(model: model, sourceID: candidate.id, profileID: profile.id) }
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.piAccentSoft, in: RoundedRectangle(cornerRadius: 8))
        .disabled(loading)
        .help("Changes only the catalog for this connection's chats. Requests keep their existing connection, key, model and effort.")
        .accessibilityIdentifier("model-catalog-mismatch")
    }

    private func sourceSelector(profile: ProfileRecord, source: ProfileRecord, loading: Bool) -> some View {
        let choices = [PiChoice(id: profile.id, title: "Saved with this connection", subtitle: Self.sourceLabel(profile))] +
            model.profiles.filter { $0.id != profile.id && $0.api == LiteLLMConfiguration.supportedAPI && model.catalogProfile(for: $0).id == $0.id }
                .map { PiChoice(id: $0.id, title: $0.name, subtitle: Self.sourceLabel($0)) }
        return PiChoicePicker(title: "Catalog source", selection: source.id, choices: choices, choose: { id in
            Task { await refresh.selectSource(model: model, sourceID: id, profileID: profile.id) }
        }) {
            Label("Catalog source…", systemImage: "list.bullet.rectangle")
                .font(PiFont.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(loading)
        .help("Choose the model list for chats using this connection. The request connection, credentials and selected model stay the same.")
        .accessibilityIdentifier("select-model-catalog-source")
    }

    static func filtered(_ models: [ModelDescriptor], query: String) -> [ModelDescriptor] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(query) || $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    /// Deliberately omit query values: catalog URLs may contain access tokens.
    static func sourceLabel(_ profile: ProfileRecord) -> String {
        guard ModelCatalog.catalogConfigured(profile) else { return "Included with Bello Agent" }
        let value = profile.catalogUrl ?? ""
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host else { return "Saved connection source" }
        return host + (parts.port.map { ":\($0)" } ?? "") + parts.path
    }
}


// MARK: - WorkspaceManagerView.swift before batch 9

/// One folder line: path, primary marker and an optional remove action.
struct RefWorkspaceFolderRow: View {
    let path: String
    var primary = false
    var remove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: PiSpacing.sm) {
            Image(systemName: primary ? "house" : "folder").font(.system(size: 11, weight: .medium)).foregroundStyle(primary ? Color.piAccent : Color.piInkSecondary).frame(width: 14)
            Text(path).font(PiFont.mono).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
            Spacer(minLength: 4)
            if primary { PiBadge(text: "Primary", tone: .accent) }
            if let remove { PiIconButton(symbol: "xmark", label: "Remove folder", size: 22, action: remove) }
        }
        .padding(.horizontal, PiSpacing.md).padding(.vertical, 6)
    }
}

/// Primary and extra folders of a saved workspace with add/remove actions.
/// Shared by the manager sheet and onboarding.
struct RefWorkspaceFolderList: View {
    @ObservedObject var model: WorkspaceModel
    let workspace: WorkspaceRecord
    var onError: (String) -> Void = { _ in }
    @State private var busy = false
    private var active: Bool { model.workspaceHasActiveWork(workspace.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            VStack(spacing: 0) {
                RefWorkspaceFolderRow(path: workspace.path, primary: true)
                ForEach(workspace.paths, id: \.self) { folder in
                    Rectangle().fill(Color.piHairline).frame(height: 1).padding(.leading, PiSpacing.md)
                    RefWorkspaceFolderRow(path: folder) { perform { try await model.removeFolder(folder, from: workspace.id) } }
                        .transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                }
            }
            .piInset()
            .animation(.easeInOut(duration: 0.2), value: workspace.paths)
            HStack(spacing: PiSpacing.sm) {
                Button { perform { try await model.addFoldersInteractively(to: workspace.id) } } label: { Label("Add Folders…", systemImage: "folder.badge.plus") }
                    .buttonStyle(.piSecondaryCompact).disabled(busy || active || workspace.roots.count >= WorkspaceModel.maximumRoots)
                if busy { PiSpinner(controlSize: .mini) }
                Text(active ? "Stop this project's work before changing folders." : "\(WorkspaceLabel.folders(workspace.roots.count)) · Changes reopen the host on the next message")
                    .font(PiFont.caption).foregroundStyle(active ? Color.piWarning : Color.piInkTertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.18), value: active)
        }
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { defer { busy = false }; do { try await work() } catch { onError(error.localizedDescription) } }
    }
}

/// "Projects" sheet: every workspace with its folders and chat count, plus creation and removal.
struct RefWorkspaceManagerView: View {
    @ObservedObject var model: WorkspaceModel
    @PiDismiss private var dismiss
    @State private var selection: String?
    @State private var draft: NewWorkspaceDraft?
    @State private var message = ""
    @State private var tone: PiTone = .neutral
    @State private var busy = false
    /// Remove Project asked once; the section shows the question until Remove or Keep.
    @State private var confirmingRemove: String?
    private var selected: WorkspaceRecord? { model.workspaces.first { $0.id == selection } }

    struct NewWorkspaceDraft: Equatable {
        var primary: String?
        var extras: [String] = []

        static func editing(_ source: Binding<Self?>) -> Binding<Self>? {
            guard let initial = source.wrappedValue else { return nil }
            return Binding(
                // Read live state on every edit, rather than the value captured by body.
                get: { source.wrappedValue ?? initial },
                // An outgoing animated pane must not reopen a cancelled draft.
                set: { if source.wrappedValue != nil { source.wrappedValue = $0 } }
            )
        }

        mutating func selectPrimary(_ folder: String) {
            primary = folder
            extras.removeAll { $0 == folder }
        }
    }

    var body: some View {
        PiSheet("Projects", subtitle: "Every chat belongs to one project. The primary folder is the working directory; extra folders are read, searched and edited by the same tools.", symbol: "folder.badge.gearshape", width: 780, height: 540) {
            HStack(spacing: 0) {
                list.frame(width: 250)
                Rectangle().fill(Color.piHairline).frame(width: 1)
                // One pane over the other while they cross, never side by side.
                ZStack {
                    if let draft = NewWorkspaceDraft.editing($draft) { RefNewWorkspacePane(model: model, draft: draft, busy: $busy, cancel: { withAnimation { self.draft = nil } }, created: { id in withAnimation { self.draft = nil; selection = id }; report("Project created.", .success) }, failed: { report($0, .danger) })
                            .transition(AnyTransition.move(edge: .trailing).combined(with: .opacity))
                    } else if let selected { detail(selected).id(selected.id).transition(.opacity) }
                    else { placeholder.transition(.opacity) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: selection)
                .animation(.easeInOut(duration: 0.2), value: draft == nil)
            }
        } actions: {
            Button { withAnimation(.easeInOut(duration: 0.2)) { draft = NewWorkspaceDraft() }; message = "" } label: { Label("New Project…", systemImage: "plus") }
                .buttonStyle(.piPrimaryCompact).disabled(draft != nil || busy)
        } footer: {
            HStack(spacing: PiSpacing.md) {
                PiStatusLine(text: message, tone: tone).animation(.easeInOut(duration: 0.18), value: message)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { selection = model.selectedWorkspaceID ?? model.workspaces.first?.id; if model.workspaces.isEmpty { draft = NewWorkspaceDraft() } }
        .onChange(of: model.workspaces.map(\.id)) { _, ids in if let selection, !ids.contains(selection) { self.selection = ids.first } }
        .onChange(of: selection) { _, _ in confirmingRemove = nil }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.workspaces.isEmpty ? "Projects" : "Projects · \(model.workspaces.count)").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.5)
                .padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.md).padding(.bottom, 4)
            ScrollView {
                // A plain stack: a handful of rows, and a lazy one in a sheet
                // makes SwiftUI report a layout cycle whenever it is presented.
                VStack(spacing: 1) {
                    ForEach(model.workspaces) { workspace in
                        let chats = model.chatCount(workspaceID: workspace.id)
                        PiSelectableRow(selected: selection == workspace.id && draft == nil, action: { withAnimation(.easeInOut(duration: 0.2)) { draft = nil; selection = workspace.id } }) {
                            HStack(spacing: 8) {
                                Image(systemName: workspace.trusted ? "folder.fill" : "folder.badge.questionmark").font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(selection == workspace.id ? Color.piAccent : Color.piInkSecondary).frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(WorkspaceLabel.name(workspace)).font(.system(size: 13, weight: selection == workspace.id ? .semibold : .regular)).foregroundStyle(Color.piInk).lineLimit(1)
                                        if !workspace.paths.isEmpty { Text("+\(workspace.paths.count)").font(PiFont.micro).foregroundStyle(Color.piAccent) }
                                    }
                                    Text(WorkspaceLabel.chats(chats) + " · " + WorkspaceLabel.folders(workspace.roots.count)).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if model.hosts[workspace.id]?.isReady == true { Circle().fill(model.workspaceHasActiveWork(workspace.id) ? Color.piWarning : Color.piSuccess).frame(width: 6, height: 6).help("Host running") }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity).padding(.horizontal, PiSpacing.sm)
            }
            .overlay {
                if model.workspaces.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 22)).foregroundStyle(Color.piInkTertiary)
                        Text("No projects yet.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    }.padding(PiSpacing.lg)
                }
            }
        }
        .background(Color.piWindow)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 26)).foregroundStyle(Color.piInkTertiary)
            Text("Select a project or create one.").font(PiFont.body).foregroundStyle(Color.piInkSecondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ workspace: WorkspaceRecord) -> some View {
        let chats = model.chatCount(workspaceID: workspace.id)
        let hasTopics = !model.topics(in: workspace.id).isEmpty
        let removalHint = chats > 0 ? "Delete its \(WorkspaceLabel.chats(chats)) first; a project with chats cannot be removed."
            : hasTopics ? "Remove this project's topics first. Removing a topic keeps its chats."
            : "Forget this project. Its folders on disk stay untouched."
        return ScrollView {
            VStack(alignment: .leading, spacing: PiSpacing.lg) {
                HStack(alignment: .firstTextBaseline, spacing: PiSpacing.sm) {
                    Text(WorkspaceLabel.name(workspace)).font(PiFont.title(17)).foregroundStyle(Color.piInk).lineLimit(1)
                    PiBadge(text: WorkspaceLabel.chats(chats), icon: "bubble.left")
                    if model.workspaceHasActiveWork(workspace.id) { PiBadge(text: "Working", tone: .warning, dot: true) }
                    Spacer()
                    if model.selectedWorkspaceID != workspace.id { Button("Switch to It") { model.selectedWorkspaceID = workspace.id }.buttonStyle(.piGhost) }
                    else { PiBadge(text: "Current", tone: .accent) }
                }
                .animation(.easeInOut(duration: 0.18), value: model.selectedWorkspaceID)
                VStack(alignment: .leading, spacing: PiSpacing.sm) {
                    PiSectionHeader("Folders", subtitle: "Tools resolve relative paths against the primary folder; skills and instructions are discovered in every folder.")
                    RefWorkspaceFolderList(model: model, workspace: workspace) { report($0, .danger) }
                }
                VStack(alignment: .leading, spacing: PiSpacing.sm) {
                    PiSectionHeader("Remove", subtitle: removalHint)
                    if confirmingRemove == workspace.id {
                        HStack(spacing: PiSpacing.sm) {
                            Text("Remove “\(WorkspaceLabel.name(workspace))”? Bello Agent forgets this project and its folder trust. Nothing on disk is deleted.")
                                .font(PiFont.caption).foregroundStyle(Color.piDanger).fixedSize(horizontal: false, vertical: true)
                            Button("Keep") { withAnimation(PiMotion.quick) { confirmingRemove = nil } }.buttonStyle(.piSecondaryCompact).fixedSize()
                            Button { remove(workspace) } label: { Label("Remove Project", systemImage: "trash") }.buttonStyle(.piDanger).fixedSize().disabled(busy)
                                .accessibilityIdentifier("workspace-confirm-remove")
                        }
                    } else {
                        Button { withAnimation(PiMotion.base) { confirmingRemove = workspace.id } } label: { Label("Remove Project…", systemImage: "trash") }.buttonStyle(.piDanger).disabled(chats > 0 || hasTopics || busy)
                            .accessibilityIdentifier("workspace-remove")
                    }
                }
                .piAnimation(PiMotion.base, value: confirmingRemove)
            }
            .padding(PiSpacing.xl)
        }
    }

    private func remove(_ workspace: WorkspaceRecord) {
        confirmingRemove = nil
        busy = true
        Task { defer { busy = false }
            do { try await model.removeWorkspace(workspace.id); report("Project removed.", .success) }
            catch { report(error.localizedDescription, .danger) } }
    }

    private func report(_ text: String, _ tone: PiTone) { message = text; self.tone = tone }
}

/// Create flow: choose a primary folder, optional extras, then trust and save.
private struct RefNewWorkspacePane: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var draft: RefWorkspaceManagerView.NewWorkspaceDraft
    @Binding var busy: Bool
    let cancel: () -> Void
    let created: (String) -> Void
    let failed: (String) -> Void
    private var roots: [String] { (draft.primary.map { [$0] } ?? []) + draft.extras }
    private var existing: WorkspaceRecord? { draft.primary.flatMap { path in model.workspaces.first { $0.path == path } } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PiSpacing.lg) {
                PiSectionHeader("New project", subtitle: "Pick the primary folder first. Add more folders when a task spans several repositories.")
                VStack(spacing: 0) {
                    if let primary = draft.primary {
                        RefWorkspaceFolderRow(path: primary, primary: true).transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                    } else {
                        HStack(spacing: PiSpacing.sm) {
                            Image(systemName: "house").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary).frame(width: 14)
                            Text("No primary folder chosen").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                            Spacer()
                        }.padding(.horizontal, PiSpacing.md).padding(.vertical, 8)
                    }
                    ForEach(draft.extras, id: \.self) { folder in
                        Rectangle().fill(Color.piHairline).frame(height: 1).padding(.leading, PiSpacing.md)
                        RefWorkspaceFolderRow(path: folder) { draft.extras.removeAll { $0 == folder } }
                            .transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                    }
                }
                .piInset()
                .animation(.easeInOut(duration: 0.2), value: draft)
                HStack(spacing: PiSpacing.sm) {
                    Button { choosePrimary() } label: { Label(draft.primary == nil ? "Choose Primary Folder…" : "Change Primary…", systemImage: "house") }.buttonStyle(.piSecondaryCompact)
                    Button { addExtras() } label: { Label("Add Folders…", systemImage: "folder.badge.plus") }.buttonStyle(.piSecondaryCompact)
                        .disabled(draft.primary == nil || roots.count >= WorkspaceModel.maximumRoots)
                    Spacer()
                    Text(WorkspaceLabel.folders(roots.count)).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                }
                if existing != nil {
                    PiNote("This folder is already a project. Creating it again replaces its extra folders.", tone: .warning)
                }
                PiNote("Editing chats can read files, run shell commands and change files in these folders with your account's permissions. Read-only chats expose only local read and search tools.")
                HStack {
                    Button("Cancel", action: cancel).buttonStyle(.piGhost)
                    Spacer()
                    Button { create() } label: { Label(busy ? "Creating…" : "Create Project", systemImage: "checkmark") }.buttonStyle(.piPrimary).disabled(draft.primary == nil || busy)
                }
            }
            .padding(PiSpacing.xl)
        }
        .disabled(busy)
    }
    private func choosePrimary() {
        Task {
            guard let folder = await WorkspaceModel.chooseFolders(message: "Choose the primary working directory for this project.", multiple: false).first else { return }
            withAnimation { draft.selectPrimary(folder) }
        }
    }
    private func addExtras() {
        Task {
            let picked = await WorkspaceModel.chooseFolders(message: "Choose additional folders for this project.", multiple: true).filter { !roots.contains($0) }
            guard !picked.isEmpty else { return }
            withAnimation { draft.extras += picked }
        }
    }
    private func create() {
        guard let primary = draft.primary else { return }
        do { try WorkspaceModel.validateRoots(roots) } catch { failed(error.localizedDescription); return }
        let extras = draft.extras
        busy = true
        Task { defer { busy = false }
            do { let workspace = try await model.createWorkspace(primary: primary, extras: extras); created(workspace.id) }
            catch { failed(error.localizedDescription) } }
    }
}
