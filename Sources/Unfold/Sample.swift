import Foundation

enum Sample {
    static var records: [StreamRecord] {
        [
            StreamRecord(kind: StreamKind.system.rawValue, text: "SIMULATED SAMPLE. This demonstrates the native text renderer. No model call, command execution or filesystem edit occurred.", language: nil),
            StreamRecord(kind: StreamKind.user.rawValue, text: "Investigate the failing parser test. Keep the code, commands and results visible as you work.", language: nil),
            StreamRecord(kind: StreamKind.reasoning.rawValue, text: "I’ll inspect the parser, reproduce the reported failure, and then check the smallest change against the targeted tests.", language: nil),
            StreamRecord(kind: StreamKind.command.rawValue, text: "/example/project\n$ python -m pytest tests/test_parser.py -q", language: "bash"),
            StreamRecord(kind: StreamKind.output.rawValue, text: "FAILED tests/test_parser.py::test_trailing_whitespace\nExpected: 42\nReceived: ValueError\n1 failed, 1 passed", language: nil),
            StreamRecord(kind: StreamKind.prose.rawValue, text: "The parser validates the input before converting it. Trailing whitespace fails the strict digit check. I’ll normalise surrounding whitespace before validation; I haven’t checked the other input formats yet.", language: nil),
            StreamRecord(kind: StreamKind.code.rawValue, text: "import re\n\ndef parse_number(value: str) -> int:\n    value = value.strip()\n    if not re.fullmatch(r\"[0-9]+\", value):\n        raise ValueError(\"Expected a positive integer\")\n    return int(value)", language: "python"),
            StreamRecord(kind: StreamKind.change.rawValue, text: "src/parser.py\n@@ -3,2 +3,3 @@\n def parse_number(value: str) -> int:\n+    value = value.strip()\n     if not re.fullmatch(r\"[0-9]+\", value):", language: "diff"),
            StreamRecord(kind: StreamKind.command.rawValue, text: "$ python -m pytest tests/test_parser.py -q", language: "bash"),
            StreamRecord(kind: StreamKind.output.rawValue, text: "..\n2 passed in 0.18s\nExit code: 0", language: nil),
            StreamRecord(kind: StreamKind.compaction.rawValue, text: "Example compaction event. The event supplies a boundary, but it does not reveal which content was retained or omitted. ThoughtStream does not invent a summary of that hidden state.", language: nil),
            StreamRecord(kind: StreamKind.prose.rawValue, text: "Both targeted tests passed after the edit. I haven’t run the full suite. We can inspect the remaining formats, try another fix, or continue from here.", language: nil),
            StreamRecord(kind: StreamKind.code.rawValue, text: "const streams = sessions.filter(session => session.isRunning);\nfor (const stream of streams) {\n  renderAvailableEvents(stream);\n}", language: "javascript"),
            StreamRecord(kind: StreamKind.system.rawValue, text: "Sample complete. Open a real project and connect ChatGPT to test live Codex activity on your Mac.", language: nil)
        ]
    }
    static var richRecords: [StreamRecord] {
        [
            StreamRecord(kind: "Session", text: "SIMULATED SAMPLE · No model call or command execution.", language: nil),
            StreamRecord(kind: "You", text: "Show me the work, with readable Markdown, compact JSON, and a small HTML preview.", language: nil),
            StreamRecord(kind: "Reasoning summary", text: "I’ll keep the explanation readable and the supporting data close by. Expand an object when you want its details.", language: nil),
            StreamRecord(kind: "Session", text: "turn/moderationMetadata\n{\"metadata\":{\"generation\":{},\"prompt\":{},\"tool_call\":{},\"tool_response\":{}}}", language: nil),
            StreamRecord(kind: "Agent", text: """
            ## A clearer view of the work
            **Markdown** now reads like a document, with headings, lists, links, tables and `inline code`.

            | Content | Presentation |
            | --- | --- |
            | Markdown | Formatted and selectable |
            | JSON | Compact, expandable objects |
            | HTML | Small previews with pop-out windows |

            ```json
            {"name":"ThoughtStream","ready":true,"views":["Markdown","JSON","HTML"]}
            ```

            ```html
            <article style="padding:28px;border-radius:18px;background:#ede9fe;color:#29213b">
              <p style="font-size:12px;letter-spacing:2px">A LITTLE HTML WINDOW</p>
              <h1 style="font-size:32px;margin:12px 0">Room to think.</h1>
              <p>Your HTML and CSS, rendered right inside the conversation.</p>
            </article>
            ```
            """, language: nil),
            StreamRecord(kind: "Command", text: "/example/project\n$ python3 - <<'PY'\nfrom pathlib import Path\nimport os\np=Path('example.txt'); print(p)\nPY", language: "bash"),
            StreamRecord(kind: "Session", text: "Use View HTML source to inspect the markup, or Open window for a larger preview.", language: nil)
        ]
    }

}
