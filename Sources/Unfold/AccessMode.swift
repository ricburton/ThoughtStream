import Foundation

enum AccessMode: String {
    case workspace, fullAccess
    static let preferenceKey = "unfold.accessMode"
    static var hasChosen: Bool { UserDefaults.standard.string(forKey: preferenceKey) != nil }
    static var selected: AccessMode {
        AccessMode(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .workspace
    }
    static func select(_ mode: AccessMode) { UserDefaults.standard.set(mode.rawValue, forKey: preferenceKey) }

    var label: String { self == .fullAccess ? "Full access · no approvals" : "Workspace access · approvals" }
    var threadParameters: [String: Any] {
        ["approvalPolicy": self == .fullAccess ? "never" : "on-request",
         "sandbox": self == .fullAccess ? "danger-full-access" : "workspace-write"]
    }
    func turnParameters(project: URL) -> [String: Any] {
        let policy: [String: Any] = self == .fullAccess
            ? ["type": "dangerFullAccess"]
            : ["type": "workspaceWrite", "writableRoots": [project.path], "networkAccess": false]
        return ["approvalPolicy": self == .fullAccess ? "never" : "on-request", "sandboxPolicy": policy]
    }
}
