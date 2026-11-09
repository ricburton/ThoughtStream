import XCTest
@testable import ThoughtStream

final class AccessModeTests: XCTestCase {
    func testFullAccessDisablesRuntimeApprovalsAtThreadAndTurnLevel() {
        XCTAssertEqual(AccessMode.fullAccess.threadParameters["approvalPolicy"] as? String, "never")
        XCTAssertEqual(AccessMode.fullAccess.threadParameters["sandbox"] as? String, "danger-full-access")
        let turn = AccessMode.fullAccess.turnParameters(project: URL(fileURLWithPath: "/tmp/project"))
        XCTAssertEqual(turn["approvalPolicy"] as? String, "never")
        XCTAssertEqual((turn["sandboxPolicy"] as? [String: Any])?["type"] as? String, "dangerFullAccess")
    }
    func testWorkspaceModeRestoresBoundariesForAResumedThreadAndNewTurn() {
        XCTAssertEqual(AccessMode.workspace.threadParameters["sandbox"] as? String, "workspace-write")
        let turn = AccessMode.workspace.turnParameters(project: URL(fileURLWithPath: "/tmp/project"))
        XCTAssertEqual(turn["approvalPolicy"] as? String, "on-request")
        let policy = turn["sandboxPolicy"] as? [String: Any]
        XCTAssertEqual(policy?["type"] as? String, "workspaceWrite")
        XCTAssertEqual(policy?["writableRoots"] as? [String], ["/tmp/project"])
        XCTAssertEqual(policy?["networkAccess"] as? Bool, false)
    }
}
