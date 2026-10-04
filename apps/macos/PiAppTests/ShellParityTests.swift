import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The workspace shell's AppKit views drawn next to the SwiftUI views they
/// replaced (`ShellParityReferences.swift`), light and dark, compared pixel
/// for pixel as `PiKitParityTests` compares the Pi components.
///
/// Serial: the windows are on screen.
@MainActor final class ShellParityTests: XCTestCase, SerialTestLane {
    private var results: [PiKitParity.Result] = []
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws {
        PiKit.Motion.reducedOverride = nil
        for result in results { print("PARITY " + result.description) }
    }

    private func check<V: View>(_ name: String, canvas: NSColor = .piContent, width: CGFloat? = nil,
                                share: Double = PiKitParityTests.symbolShare,
                                _ swiftUI: @autoclosure () -> V, _ appKit: () -> NSView,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let result = try await PiKitParity.compare("\(name)-\(suffix)", appearance: appearance,
                                                       swiftUI: swiftUI().frame(width: width), appKit: appKit(), canvas: canvas, width: width)
            results.append(result)
            XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height.rounded(.up), accuracy: 1.01, "\(result.name) height", file: file, line: line)
            XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * share, result.description, file: file, line: line)
        }
    }

    static func detail(context: SkillDetail.Context = .composer, arguments: String = "focus on notarization", revision: SkillRevision = .current) -> SkillDetail {
        SkillDetail(context: context, id: "release-checklist", name: "release-checklist", description: "Walk through the release preflight before tagging",
                    arguments: arguments, path: "/tmp/project/.agents/skills/release-checklist/SKILL.md",
                    place: SkillPlace(kind: .project, root: "/tmp/project/.agents/skills"), policy: "explicitOnly",
                    contentHash: "0123456789abcdef", revision: revision)
    }

    func testSkillPillFace() async throws {
        for (name, args, hovered, open) in [("plain", "", false, false), ("arguments", "focus on notarization and stapling", false, false),
                                            ("hovered", "", true, false), ("open", "x", false, true)] {
            try await check("skillpill-\(name)", SkillPillFace(name: "release-checklist", arguments: args, hovered: hovered, open: open)) {
                let face = SkillPillFaceView(name: "release-checklist", arguments: args)
                face.hovered = hovered; face.open = open
                return face
            }
        }
    }

    func testSkillHoverCard() async throws {
        try await check("skillcard", canvas: .piSurface, width: SkillPopovers.cardWidth, RefSkillHoverCard(detail: Self.detail())) {
            SkillHoverCardView(detail: Self.detail())
        }
        let changed = Self.detail(arguments: "", revision: .changed(now: "fedcba98"))
        try await check("skillcard-changed", canvas: .piSurface, width: SkillPopovers.cardWidth, RefSkillHoverCard(detail: changed)) {
            SkillHoverCardView(detail: changed)
        }
    }

    func testSkillPopover() async throws {
        let actions = SkillPopoverActions(open: {}, reveal: {}, editArguments: {}, remove: {})
        try await check("skillpopover", canvas: .piSurface, width: SkillPopovers.popoverWidth, RefSkillPopoverView(detail: Self.detail(), actions: actions)) {
            SkillPopoverContentView(session: nil) { (Self.detail(), actions) }
        }
        let sent = Self.detail(context: .sent, arguments: "", revision: .changed(now: "fedcba98"))
        let plain = SkillPopoverActions(open: nil, reveal: nil)
        try await check("skillpopover-sent", canvas: .piSurface, width: SkillPopovers.popoverWidth, RefSkillPopoverView(detail: sent, actions: plain)) {
            SkillPopoverContentView(session: nil) { (sent, plain) }
        }
    }

    func testComposerPills() async throws {
        for (name, text, active, compact, width) in [("named", "Team router · Responses", false, false, CGFloat(150)), ("active", "ui-fixture", true, false, 170),
                                                     ("compact", "Effort", false, true, 176), ("compact-active", "Effort", true, true, 176),
                                                     ("cut", "a-very-long-model-alias-that-is-cut-in-the-middle", false, false, 110)] {
            // Symbols sit a fraction of a pixel apart (DesignKit's allowance),
            // which in a pill this small is a larger share; a label cut in the
            // middle is cut by Core Text, not SwiftUI.
            try await check("pill-\(name)", share: name == "cut" ? 0.05 : 0.04, RefPillLabel(icon: "cpu", text: text, active: active, loading: false, maxWidth: width, compact: compact).fixedSize()) {
                ComposerPillButton(icon: "cpu", text: text, active: active, maxTextWidth: width, compact: compact)
            }
        }
    }

    func testComposerEditBanners() async throws {
        let session = SessionDisplay(id: "banner")
        session.editNotice = "Editing message 3 of this chat. Send replaces it and everything after it."
        try await check("editbanner", width: 600, RefEditingBanner(session: session, cancel: {})) {
            let banner = ComposerEditBanner(title: "Editing an earlier message", accessibilityName: "Editing an earlier message", cancel: {})
            banner.update(detail: session.editNotice, cancelEnabled: true)
            return banner
        }
        try await check("queuebanner", width: 600, RefQueueEditBanner(steering: false, cancel: {})) {
            let banner = ComposerEditBanner(title: "Editing a queued message", accessibilityName: "Editing a queued message", cancel: {})
            banner.update(detail: "This message and the others waiting are paused while you edit. Return saves it in its place in the queue.", maximumLines: 3, cancelEnabled: true)
            return banner
        }
    }
}
