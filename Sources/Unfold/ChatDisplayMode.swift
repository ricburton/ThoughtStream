import Foundation

enum ChatDisplayMode: String {
    case showLogs, justChat

    static let defaultsKey = "thoughtstream.chatDisplayMode"
    var title: String { self == .showLogs ? "Show logs" : "Just chat" }
    var next: Self { self == .showLogs ? .justChat : .showLogs }
}
