import XCTest
import Sparkle
@testable import PiApp

final class ReleaseConfigurationTests: XCTestCase {
    private var valid: [String: Any] {
        ["CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1",
         "SUFeedURL": ReleaseConfiguration.feedURL.absoluteString,
         "SUPublicEDKey": ReleaseConfiguration.publicKey]
    }

    func testPackagedConfigurationIsValid() {
        XCTAssertNil(ReleaseConfiguration.current.error)
    }

    func testRejectsWrongFeedAndSigningKey() {
        for (key, value) in [("SUFeedURL", "http://localhost/appcast.xml"),
                             ("SUPublicEDKey", "untrusted")] {
            var info = valid
            info[key] = value
            XCTAssertNotNil(ReleaseConfiguration(info: info).error)
        }
    }

    func testRejectsNonPositiveOrUnresolvedBuildNumber() {
        for build in ["0", "-1", "$(CURRENT_PROJECT_VERSION)", "1beta"] {
            var info = valid
            info["CFBundleVersion"] = build
            XCTAssertNotNil(ReleaseConfiguration(info: info).error)
        }
    }

    /// Active work no longer refuses the relaunch outright (0.1.125): the
    /// relaunch goes through the postponement, which asks to pause it first
    /// (`UpdatePauseTests`). Without active work it takes the barrier.
    @MainActor func testUpdateRelaunchTakesTheBarrierOrAsksToPauseActiveWork() {
        let controller = UpdateController()
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                  userDriverDelegate: nil).updater
        var barriers = 0
        controller.acquireBarrier = { barriers += 1; return true }
        controller.hasActiveWork = { true }
        XCTAssertTrue(controller.updaterShouldRelaunchApplication(updater))
        XCTAssertEqual(barriers, 0, "no barrier over active work; the postponement asks first")
        controller.hasActiveWork = { false }
        XCTAssertTrue(controller.updaterShouldRelaunchApplication(updater))
        XCTAssertEqual(barriers, 1)
    }
}
