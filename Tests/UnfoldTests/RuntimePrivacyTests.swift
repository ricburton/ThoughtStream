import XCTest
@testable import ThoughtStream

final class RuntimePrivacyTests: XCTestCase {
    @MainActor
    func testRuntimeStartsInProjectOrPrivateDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-runtime")
        let script = """
        #!/bin/sh
        read -r initialize
        printf '{"id":1,"result":{}}\\n'
        read -r initialized
        read -r request
        printf '{"id":2,"result":{"cwd":"%s"}}\\n' "$PWD"
        cat > /dev/null
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let privateDirectory = try AgentInstructions.runtimeDirectory()
        XCTAssertNotEqual(privateDirectory, FileManager.default.homeDirectoryForCurrentUser)
        for project in [nil, root] as [URL?] {
            let runtime = CodexConnection()
            do {
                try await runtime.start(executable: executable, project: project)
                let result = try await runtime.request("test/cwd")
                let actual = try XCTUnwrap(result["cwd"] as? String)
                XCTAssertEqual(URL(fileURLWithPath: actual).resolvingSymlinksInPath().path, (project ?? privateDirectory).resolvingSymlinksInPath().path)
                runtime.stop()
            } catch {
                runtime.stop()
                throw error
            }
        }
    }
}
