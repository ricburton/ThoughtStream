import Foundation
import Darwin

/// A local socket host outlives its UI connection. Closing/reopening a window
/// only replaces the proxy; the agent's running turn stays in the same process.
@MainActor
enum CodexRuntimeHost {
    private static var hosts: [String: Process] = [:]

    static func socket(for id: UUID) throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/UnfoldNative/Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent(id.uuidString + ".sock")
    }

    static func ensure(executable: URL, project: URL, id: UUID) async throws -> URL {
        let socket = try socket(for: id)
        if isListening(socket) { return socket }
        let lock = open(socket.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw CodexConnection.error("Could not open the chat runtime lock.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if isListening(socket) { return socket }
        // Under the lock, an unresponsive socket belongs to a stopped host.
        try? FileManager.default.removeItem(at: socket)
        let log = socket.appendingPathExtension("log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        defer { try? output.close() }
        let host = Process()
        host.executableURL = executable
        host.currentDirectoryURL = project
        host.arguments = ["app-server", "--listen", "unix://" + socket.path]
        host.standardInput = FileHandle.nullDevice
        host.standardOutput = output; host.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        host.environment = environment
        try host.run()
        try String(host.processIdentifier).write(to: socket.appendingPathExtension("pid"), atomically: true, encoding: .utf8)
        hosts[socket.path] = host
        for _ in 0..<100 {
            try Task.checkCancellation()
            if isListening(socket) { return socket }
            guard host.isRunning else { throw CodexConnection.error("The chat runtime could not start.") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        host.terminate()
        throw CodexConnection.error("The chat runtime did not become ready.")
    }

    static func isListening(_ url: URL) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            path.withUnsafeBytes { bytes.copyBytes(from: $0) }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    static func stop(id: UUID) {
        guard let socket = try? socket(for: id) else { return }
        if let host = hosts.removeValue(forKey: socket.path), host.isRunning { host.terminate(); return }
        guard let text = try? String(contentsOf: socket.appendingPathExtension("pid")),
              let pid = Int32(text), pid > 1 else { return }
        // A stale PID file must never terminate an unrelated process.
        let check = Process(), pipe = Pipe()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-p", String(pid), "-o", "command="]
        check.standardOutput = pipe
        guard (try? check.run()) != nil else { return }
        let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check.waitUntilExit()
        guard command.hasSuffix("app-server --listen unix://" + socket.path) else { return }
        kill(pid, SIGTERM)
    }
}
