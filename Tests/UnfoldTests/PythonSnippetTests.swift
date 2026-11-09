import XCTest
@testable import ThoughtStream

final class PythonSnippetTests: XCTestCase {
    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func testHeredocExtractsOnlyPythonAndKeepsOriginalSpacing() {
        let command = "/workspace\n$ python3 - <<'PY'\nfrom pathlib import Path\np=Path('file.py'); print(p)\nPY\nplutil -lint Info.plist"
        XCTAssertEqual(PythonSnippetExtractor.extract(from: command).map(\.source), ["from pathlib import Path\np=Path('file.py'); print(p)\n"])
    }
    func testQuotedShellWrapperAndInlinePython() {
        let script = "python3 - <<'PY'\nprint('hello')\nPY"
        XCTAssertEqual(PythonSnippetExtractor.extract(from: "/bin/zsh -lc " + shellQuote(script)).first?.source, "print('hello')\n")
        XCTAssertEqual(PythonSnippetExtractor.extract(from: "python3 -c " + shellQuote("x=1; print(x)")).first?.source, "x=1; print(x)")
        XCTAssertEqual(PythonSnippetExtractor.extract(from: "env FLAG=1 /usr/bin/python3.11 -c 'print(1)'").first?.source, "print(1)")
    }
    func testDoesNotInventPythonForShellCommandsOrLiteralExamples() {
        XCTAssertTrue(PythonSnippetExtractor.extract(from: "pgrep -fl Unfold && plutil -lint Info.plist").isEmpty)
        XCTAssertTrue(PythonSnippetExtractor.extract(from: "echo python3 -c 'print(1)'").isEmpty)
        XCTAssertTrue(PythonSnippetExtractor.extract(from: "cat <<'EXAMPLE'\npython3 - <<'PY'\nprint(1)\nPY\nEXAMPLE").isEmpty)
        XCTAssertTrue(PythonSnippetExtractor.extract(from: "python3 script.py").isEmpty)
    }
    func testMultipleHeredocsTabsAndPartialInput() {
        XCTAssertEqual(PythonSnippetExtractor.extract(from: "python - <<-PY\n\tprint(1)\n\tPY\npython3 <<'END'\nprint(2)\nEND").map(\.source), ["print(1)\n", "print(2)\n"])
        XCTAssertTrue(PythonSnippetExtractor.extract(from: "python3 - <<'PY'\nprint(1)").isEmpty)
    }
}
