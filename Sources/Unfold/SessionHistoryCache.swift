import Foundation

/// Full transcripts remain on disk. Keep a few recent idle chats warm for fast
/// tab switching; displayed and active sessions are outside this cache budget.
@MainActor
enum SessionHistoryCache {
    static func trim(_ sessions: [Session], maximumIdleChats: Int = 8,
                     maximumIdleBytes: Int = 64 * 1024 * 1024, now: Date = Date()) {
        let recentWorkCutoff = now.addingTimeInterval(-3 * 24 * 60 * 60)
        func isRecent(_ session: Session) -> Bool {
            (session.lastConversationActivity ?? session.lastActivity ?? .distantPast) >= recentWorkCutoff
        }
        var count = 0
        var bytes = 0
        for session in sessions.sorted(by: {
            if isRecent($0) != isRecent($1) { return isRecent($0) }
            return $0.lastHistoryAccess > $1.lastHistoryAccess
        }) {
            session.suspendIdleRuntime(now: now)
            guard session.isHistoryLoaded, session.canReleaseHistory else { continue }
            // Recent work stays warm. An older chat opened deliberately gets
            // five minutes for quick back-and-forth before returning to disk.
            guard isRecent(session) || now.timeIntervalSince(session.lastHistoryAccess) < 300 else {
                session.releaseHistory()
                continue
            }
            let cost = session.residentHistoryBytes
            if count < maximumIdleChats && cost <= maximumIdleBytes - bytes {
                count += 1; bytes += cost
            } else {
                session.releaseHistory()
            }
        }
    }
}
