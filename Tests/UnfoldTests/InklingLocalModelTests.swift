import XCTest
@testable import ThoughtStream

final class InklingLocalModelTests: XCTestCase {
    func testIncompleteInstallationIsNotOfferedAndCompleteInstallationCanStartOffline() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = InklingLocalModel.directory(home: home)
        let executable = InklingLocalModel.executable(in: root)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        XCTAssertNil(InklingLocalModel.model(home: home))
        XCTAssertNil(InklingLocalModel.command(home: home))

        // Sparse fixtures exercise exact completeness checks without writing GBs.
        func weights(_ name: String, bytes: Int64) throws {
            let url = root.appendingPathComponent(name)
            try Data("GGUF".utf8).write(to: url)
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.truncate(atOffset: UInt64(bytes))
        }
        try weights(InklingLocalModel.modelFile, bytes: InklingLocalModel.modelBytes)
        XCTAssertNil(InklingLocalModel.model(home: home), "The vision encoder must also be complete")
        try weights(InklingLocalModel.projectionFile, bytes: InklingLocalModel.projectionBytes - 1)
        XCTAssertNil(InklingLocalModel.model(home: home))
        try weights(InklingLocalModel.projectionFile, bytes: InklingLocalModel.projectionBytes)

        let model = try XCTUnwrap(InklingLocalModel.model(home: home))
        XCTAssertEqual(model.identifier, "llamacpp|inkling-2-mini")
        XCTAssertEqual(model.displayName, "Inkling 2 Mini · llama.cpp")
        XCTAssertEqual(LocalModelDiskScanner.models(for: .llamaCpp, home: home), [model])
        let command = try XCTUnwrap(InklingLocalModel.command(home: home))
        XCTAssertEqual(command.0, executable)
        XCTAssertEqual(command.1[command.1.firstIndex(of: "--host")! + 1], "127.0.0.1")
        XCTAssertEqual(command.1[command.1.firstIndex(of: "--alias")! + 1], model.inferenceName)
        XCTAssertTrue(command.1.contains("--mmproj"))
        XCTAssertFalse(command.1.contains("-hf"), "Starting an installed model must not download anything")

        try FileManager.default.removeItem(at: executable)
        XCTAssertNil(InklingLocalModel.model(home: home), "Do not offer an installation with no compatible runtime")
    }
}
