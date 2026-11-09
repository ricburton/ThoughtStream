import XCTest
@testable import ThoughtStream

final class PythonAnalysisTests: XCTestCase {
    func testFormatsWithoutExecutingAndLintsTheDisplayedLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = "from pathlib import Path\np=Path(\"\(root.path)\"); p.write_text('must never execute'); print(missing_name)\n"
        let result = PythonAnalysisService.analyze(source, executable: PythonAnalysisService.executable)
        XCTAssertEqual(result.state, "issues")
        XCTAssertTrue(result.formatted.contains("p = Path("))
        XCTAssertFalse(result.formatted.contains(";"))
        let issue = try XCTUnwrap(result.diagnostics.first { $0.code == "F821" })
        XCTAssertTrue(result.formatted.components(separatedBy: "\n")[issue.line - 1].contains("missing_name"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(result.source, source)
    }
    func testCleanSyntaxErrorAndUnavailableAreDistinct() {
        let executable = PythonAnalysisService.executable
        XCTAssertEqual(PythonAnalysisService.analyze("print('hello')\n", executable: executable).state, "clean")
        let invalid = PythonAnalysisService.analyze("def broken(:\n", executable: executable)
        XCTAssertEqual(invalid.state, "issues")
        XCTAssertFalse(invalid.diagnostics.isEmpty)
        XCTAssertEqual(invalid.formatted, "def broken(:\n")
        XCTAssertEqual(PythonAnalysisService.analyze("print(1)", executable: nil).state, "unavailable")
    }
}
