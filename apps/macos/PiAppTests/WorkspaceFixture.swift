import XCTest
import SwiftUI
@testable import PiApp

// Fixtures several test files share. A model built on a scratch store is the
// most common one in the suite, and the teardown below is the only correct
// way to take one down: the two SQLite owners and the helper processes have
// to close before the directory goes, or the next test inherits a half-open
// database.

extension XCTestCase {
    /// Window dismantling and selection can enqueue their last metadata writes.
    /// Keep fixture files present until that work and both SQLite owners close.
    @MainActor func registerWorkspaceFixtureTeardown(_ model: WorkspaceModel, root: URL) {
        addTeardownBlock { @MainActor in
            model.report.suspend(); model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            let deadline = Date().addingTimeInterval(2)
            while !model.workspaceChangesInFlight.isEmpty, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await model.flushDrafts()
            await model.flushReadStates(); await model.flushProjectSidebarState()
            try? await model.traces.close(); await model.store?.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
