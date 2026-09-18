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

    @MainActor func testUpdateCannotRelaunchDuringActiveWork() {
        let controller = UpdateController()
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                  userDriverDelegate: nil).updater
        controller.hasActiveWork = { true }
        XCTAssertFalse(controller.updaterShouldRelaunchApplication(updater))
        controller.hasActiveWork = { false }
        XCTAssertTrue(controller.updaterShouldRelaunchApplication(updater))
    }
}
