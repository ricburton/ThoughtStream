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
    func testURLLikeAndEmptyWordsAreOrdinaryWords() {
        // Foundation traps when a file URL is built from an unparseable http string.
        for word in ["http://{host}/x", "http://localhost:$PORT/health", "https://exa mple.com/a", "http://[bad", "http://%", ""] {
            let quoted = shellQuote(word)
            XCTAssertTrue(PythonSnippetExtractor.extract(from: "curl -s " + quoted).isEmpty)
            XCTAssertTrue(PythonSnippetExtractor.extract(from: quoted + " -c 'print(1)'").isEmpty)
            XCTAssertEqual(PythonSnippetExtractor.extract(from: "curl " + quoted + " && python3 -c 'print(1)'").map(\.source), [])
            XCTAssertEqual(PythonSnippetExtractor.extract(from: "curl " + quoted + " | python3 - <<'PY'\nprint(2)\nPY").map(\.source), ["print(2)\n"])
        }
        XCTAssertEqual(PythonSnippetExtractor.extract(from: "/opt/homebrew/bin/python3.12 -c 'print(3)'").first?.source, "print(3)")
        XCTAssertEqual(PythonSnippetExtractor.extract(from: "/bin/bash/ -c \"python3 -c 'print(4)'\"").first?.source, "print(4)")
    }
    func testMultipleHeredocsTabsAndPartialInput() {
        XCTAssertEqual(PythonSnippetExtractor.extract(from: "python - <<-PY\n\tprint(1)\n\tPY\npython3 <<'END'\nprint(2)\nEND").map(\.source), ["print(1)\n", "print(2)\n"])
        XCTAssertTrue(PythonSnippetExtractor.extract(from: "python3 - <<'PY'\nprint(1)").isEmpty)
    }
}
