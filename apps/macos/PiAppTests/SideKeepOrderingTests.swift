import AppKit
import Darwin
import XCTest
@testable import PiApp

final class SideKeepOrderingTests: XCTestCase {
    @MainActor private func fixture() throws -> WorkspaceModel {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("side-keep-order-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        return model
    }

    @MainActor private func pending(_ id: String, in model: WorkspaceModel) async throws -> ChatRecord {
        let path = model.root.appendingPathComponent(id + ".jsonl")
        try SideKeepRecoveryTests.journal(id: "wrong-header").write(to: path)
        let chat = ChatRecord(id: id, workspaceID: "w", title: "Side " + id, path: path.path,
                              profileID: "p", toolMode: "read-only", parentSessionID: "parent")
        try await model.store?.put(SideKeepIntent(chat: chat), kind: "side-keep", id: id)
        return chat
    }

    @MainActor private func confirmation(_ issue: SideKeepIssue, in model: WorkspaceModel) throws -> (NSWindow, (Bool) -> Void) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var answer: ((Bool) -> Void)?
        model.questions.presentSheet = { _, _, respond in answer = respond }
        model.dismissSideKeep(issue, over: window)
        return (window, try XCTUnwrap(answer))
    }

    /// A generated pipe pauses the actual header read after registration has
    /// captured its intent. Opening its writer proves the reader reached the
    /// file; no scheduling sleeps or production hooks stand in for that race.
    @MainActor private func pauseHeader(_ chat: ChatRecord, operation: @escaping @MainActor () async -> Void) async throws -> (Task<Void, Never>, FileHandle) {
        let path = try XCTUnwrap(chat.path)
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let task = Task { await operation() }
        var descriptor: Int32 = -1
        try await eventually("registration reached its identity read") {
            descriptor = Darwin.open(path, O_WRONLY | O_NONBLOCK)
            return descriptor >= 0
        }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try FileManager.default.removeItem(atPath: path)
        return (task, writer)
    }

    @MainActor private func publish(_ bytes: Data, for chat: ChatRecord, writer: FileHandle) throws {
        try bytes.write(to: URL(fileURLWithPath: try XCTUnwrap(chat.path)))
        try writer.write(contentsOf: bytes); try writer.close()
    }

    @MainActor func testDismissDuringIdentityReadPreventsRegistrationAndPreservesDraft() async throws {
        let model = try fixture(), chat = try await pending("dismiss-first", in: model)
        let store = try XCTUnwrap(model.store)
        try await store.put(DraftRecord(id: chat.id, text: "Unsent text"), kind: "draft", id: chat.id)
        await model.reconcileSideKeeps()
        let (window, answer) = try confirmation(XCTUnwrap(model.sideKeepIssues.first), in: model)
        defer { window.close() }
        let (check, writer) = try await pauseHeader(chat) { await model.reconcileSideKeeps() }
        defer { try? writer.close() }
        answer(true)
        try await eventually("dismiss committed", until: {
            try await store.get(SideKeepIntent.self, kind: "side-keep", id: chat.id) == nil
        })
        let bytes = try SideKeepRecoveryTests.journal(id: chat.id)
        try publish(bytes, for: chat, writer: writer); await check.value
        let saved = try await store.get(ChatRecord.self, kind: "chat", id: chat.id)
        let draft = try await store.get(DraftRecord.self, kind: "draft", id: chat.id)
        XCTAssertNil(saved); XCTAssertNil(model.record(chat.id)); XCTAssertEqual(draft?.text, "Unsent text")
        XCTAssertTrue(model.sideKeepIssues.isEmpty); XCTAssertNil(model.error)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
        await model.reconcileSideKeeps()
        XCTAssertNil(model.record(chat.id)); XCTAssertTrue(model.sideKeepIssues.isEmpty)
    }

    @MainActor func testReplacementDuringIdentityReadCannotBeConsumedByOlderRegistration() async throws {
        let model = try fixture(), chat = try await pending("replacement", in: model)
        let store = try XCTUnwrap(model.store)
        var refused = false
        let (registration, writer) = try await pauseHeader(chat) {
            do { try await model.registerKeptSide(id: chat.id, path: chat.path) }
            catch { refused = true }
        }
        defer { try? writer.close() }
        var replacement = chat; replacement.path = model.root.appendingPathComponent("replacement-new.jsonl").path
        let bytes = try SideKeepRecoveryTests.journal(id: chat.id)
        try bytes.write(to: URL(fileURLWithPath: replacement.path!))
        try await store.put(SideKeepIntent(chat: replacement), kind: "side-keep", id: chat.id)
        try await store.put(DraftRecord(id: chat.id, text: "Replacement draft"), kind: "draft", id: chat.id)
        try publish(bytes, for: chat, writer: writer); await registration.value
        let intent = try await store.get(SideKeepIntent.self, kind: "side-keep", id: chat.id)
        let saved = try await store.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertTrue(refused); XCTAssertEqual(intent?.chat, replacement); XCTAssertNil(saved); XCTAssertNil(model.record(chat.id))
        await model.reconcileSideKeeps()
        XCTAssertEqual(model.record(chat.id)?.path, replacement.path)
        let draft = try await store.get(DraftRecord.self, kind: "draft", id: chat.id)
        XCTAssertEqual(draft?.text, "Replacement draft")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: replacement.path!)), bytes)
    }

    @MainActor func testRegistrationBeforeDismissalKeepsRegisteredChatAndNewerDraft() async throws {
        let model = try fixture(), chat = try await pending("register-first", in: model)
        let store = try XCTUnwrap(model.store)
        await model.reconcileSideKeeps()
        let (window, answer) = try confirmation(XCTUnwrap(model.sideKeepIssues.first), in: model)
        defer { window.close() }
        let bytes = try SideKeepRecoveryTests.journal(id: chat.id)
        try bytes.write(to: URL(fileURLWithPath: chat.path!))
        await model.reconcileSideKeeps()
        try await store.put(DraftRecord(id: chat.id, text: "Typed after registration"), kind: "draft", id: chat.id)
        let revision = model.sideKeepResolutionRevision
        answer(true)
        try await eventually("confirmation completed") { model.sideKeepResolutionRevision != revision || model.error != nil }
        let saved = try await store.get(ChatRecord.self, kind: "chat", id: chat.id)
        let draft = try await store.get(DraftRecord.self, kind: "draft", id: chat.id)
        XCTAssertNotNil(saved); XCTAssertNotNil(model.record(chat.id)); XCTAssertEqual(draft?.text, "Typed after registration")
        XCTAssertTrue(model.sideKeepIssues.isEmpty); XCTAssertNil(model.error)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
    }

    @MainActor func testRecheckedReasonAndParentTitleDoNotPreventConfirmedDismissal() async throws {
        let model = try fixture(), chat = try await pending("refreshed", in: model)
        model.chats = [ChatRecord(id: "parent", workspaceID: "w", title: "Original parent title", path: nil, profileID: "p")]
        await model.reconcileSideKeeps()
        let reviewed = try XCTUnwrap(model.sideKeepIssues.first)
        let (window, answer) = try confirmation(reviewed, in: model)
        defer { window.close() }
        let bytes = Data("not-json\n".utf8)
        try bytes.write(to: URL(fileURLWithPath: chat.path!)); model.chats[0].title = "Renamed parent"
        await model.reconcileSideKeeps()
        let refreshed = try XCTUnwrap(model.sideKeepIssues.first)
        XCTAssertEqual(refreshed.chat, reviewed.chat)
        XCTAssertNotEqual(refreshed.reason, reviewed.reason); XCTAssertNotEqual(refreshed.parentTitle, reviewed.parentTitle)
        let revision = model.sideKeepResolutionRevision
        answer(true)
        try await eventually("confirmation completed") { model.sideKeepResolutionRevision != revision || model.error != nil }
        let intent = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: chat.id)
        XCTAssertNil(intent); XCTAssertTrue(model.sideKeepIssues.isEmpty); XCTAssertNil(model.error)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
    }

    @MainActor func testStaleConfirmationPreservesReplacementAndItsRefreshedNotice() async throws {
        let model = try fixture(), chat = try await pending("new-copy", in: model)
        let store = try XCTUnwrap(model.store)
        await model.reconcileSideKeeps()
        let (window, answer) = try confirmation(XCTUnwrap(model.sideKeepIssues.first), in: model)
        defer { window.close() }
        var replacement = chat; replacement.path = model.root.appendingPathComponent("new-copy-location.jsonl").path
        try await store.put(SideKeepIntent(chat: replacement), kind: "side-keep", id: chat.id)
        await model.reconcileSideKeeps()
        let refreshed = try XCTUnwrap(model.sideKeepIssues.first)
        XCTAssertEqual(refreshed.chat, replacement)
        answer(true)
        try await eventually("stale confirmation answered") { model.error != nil || model.sideKeepIssues.isEmpty }
        let intent = try await store.get(SideKeepIntent.self, kind: "side-keep", id: chat.id)
        XCTAssertEqual(intent?.chat, replacement); XCTAssertEqual(model.sideKeepIssues, [refreshed]); XCTAssertNotNil(model.error)
    }

    @MainActor func testDismissalWhileAnotherFileIsCheckedCannotRestoreAnEarlierNotice() async throws {
        let model = try fixture(), last = try await pending("z-last", in: model), first = try await pending("a-first", in: model)
        let store = try XCTUnwrap(model.store)
        await model.reconcileSideKeeps()
        let (window, answer) = try confirmation(XCTUnwrap(model.sideKeepIssues.first { $0.id == first.id }), in: model)
        defer { window.close() }
        let (check, writer) = try await pauseHeader(last) { await model.reconcileSideKeeps() }
        defer { try? writer.close() }
        answer(true)
        try await eventually("first reminder dismissed", until: {
            try await store.get(SideKeepIntent.self, kind: "side-keep", id: first.id) == nil
        })
        try publish(SideKeepRecoveryTests.journal(id: last.id), for: last, writer: writer); await check.value
        XCTAssertTrue(model.sideKeepIssues.isEmpty); XCTAssertNil(model.record(first.id)); XCTAssertNotNil(model.record(last.id))
        XCTAssertNil(model.error)
    }

    @MainActor func testDuplicateRegistrationCannotOverwriteANewerDraft() async throws {
        let model = try fixture(), chat = try await pending("duplicate", in: model)
        let store = try XCTUnwrap(model.store), capturedDraft = DraftRecord(id: chat.id, text: "Captured before validation")
        let first = try await store.commitKeptSide(chat, draft: capturedDraft, expected: chat)
        try await store.put(DraftRecord(id: chat.id, text: "Typed after registration"), kind: "draft", id: chat.id)
        do { _ = try await store.commitKeptSide(chat, draft: capturedDraft, expected: chat); XCTFail("A consumed intent cannot commit again") } catch {}
        let saved = try await store.get(ChatRecord.self, kind: "chat", id: chat.id)
        let draft = try await store.get(DraftRecord.self, kind: "draft", id: chat.id)
        XCTAssertEqual(saved, first); XCTAssertEqual(draft?.text, "Typed after registration")
    }

    @MainActor func testLaterLiveReceiptDoesNotRecreateADismissedReminderAsAnError() async throws {
        let model = try fixture(), chat = try await pending("live", in: model)
        model.sides["parent"] = .init(id: chat.id, parentID: "parent", workspaceID: "w", profileID: "p", title: chat.title)
        await model.reconcileSideKeeps()
        let (window, answer) = try confirmation(XCTUnwrap(model.sideKeepIssues.first), in: model)
        defer { window.close() }
        answer(true)
        try await eventually("reminder dismissed") { model.sideKeepIssues.isEmpty }
        let bytes = try SideKeepRecoveryTests.journal(id: chat.id)
        try bytes.write(to: URL(fileURLWithPath: chat.path!))
        for _ in 0..<2 { await model.applySideStatus(id: chat.id, result: ["ephemeral": .bool(false), "path": .string(chat.path!)]) }
        let intent = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: chat.id)
        let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertNil(intent); XCTAssertNil(saved); XCTAssertNil(model.error); XCTAssertTrue(model.sideKeepIssues.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
    }
}
