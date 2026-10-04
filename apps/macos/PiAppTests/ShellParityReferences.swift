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
