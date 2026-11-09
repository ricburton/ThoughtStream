import Foundation

extension Session {
    /// Draft composers and connection diagnostics are not conversations yet.
    /// Remote history and forks can exist before their local transcript loads.
    var hasStartedConversation: Bool {
        // Sidebar refreshes ask this for every chat; avoid re-decorating history.
        thread != nil || forkSource != nil || needsHistory || turn != nil || lastConversationActivity != nil
    }
}
