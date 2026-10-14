import AppKit
import XCTest
@testable import PiApp

@MainActor final class SettingsRefreshRegressionTests: XCTestCase {
    private final class HeightProbe: NSView, PiKit.WidthSizing {
        var measurements = 0
        func height(forWidth width: CGFloat) -> CGFloat { measurements += 1; return 0 }
    }
    private func drain() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    func testUnrelatedWorkspaceNotificationsDoNotMeasureSettingsRows() async throws {
        let root = scratchRoot("settings-refresh")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        model.settingsSection = .usage
        let view = ProfileSettingsView(model: model, controller: controller, windowChrome: false, dismiss: {})
        view.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(InspectorExpandFixture.descendants(SettingsCard.self, in: view).first)
        let probe = HeightProbe()
        card.setRows(card.rows + [probe])
        view.layoutSubtreeIfNeeded(); await drain(); view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(InspectorExpandFixture.descendants(NSScrollView.self, in: view).first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
        let origin = scroll.contentView.bounds.origin
        probe.measurements = 0
        for _ in 0..<3 {
            model.objectWillChange.send()
            await drain(); view.layoutSubtreeIfNeeded()
        }
        print("SCROLL-29 unrelated notifications: \(probe.measurements) settings-row measurements")
        XCTAssertEqual(probe.measurements, 0)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)

        controller.preferences.capture.retentionDays += 1
        await drain(); view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(probe.measurements, 0, "A settings edit still refreshes the controls and geometry")
        model.settingsSection = .app
        await drain(); view.layoutSubtreeIfNeeded()
        XCTAssertNil(card.superview, "A relevant workspace change still rebuilds the selected section")
    }
}
