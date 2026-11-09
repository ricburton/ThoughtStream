import XCTest
@testable import ThoughtStream

final class FeedBufferTests: XCTestCase {
    private func record(_ text: String, kind: StreamKind = .prose, item: String? = "a") -> StreamRecord {
        StreamRecord(kind: kind.rawValue, text: text, language: nil, itemID: item)
    }

    func testFragmentedUnicodeSurvivesPersistenceAndContinuedStreaming() throws {
        var feed = FeedBuffer()
        for text in ["Hello ", "🌍", " — café"] { feed.append(record(text), merging: true) }
        let data = try JSONEncoder().encode(feed.records)
        var restored = FeedBuffer(try JSONDecoder().decode([StreamRecord].self, from: data))
        restored.append(record("!"), merging: true)
        XCTAssertEqual(restored.records.count, 1)
        XCTAssertEqual(restored.records.first?.text, "Hello 🌍 — café!")
    }

    func testInterleavedToolsKeepChronologicalOrder() {
        var feed = FeedBuffer()
        feed.append(record("first"), merging: true)
        feed.append(record("result", kind: .output, item: "tool"), merging: true)
        feed.append(record("second"), merging: true)
        XCTAssertEqual(feed.records.map(\.text), ["first", "result", "second"])
    }

    func testDifferentKindsOrItemsCannotMerge() {
        var feed = FeedBuffer()
        feed.append(record("summary", kind: .reasoning), merging: true)
        feed.append(record("answer"), merging: true)
        feed.append(record("another answer", item: "b"), merging: true)
        XCTAssertEqual(feed.records.count, 3)
    }

    func testLegacyHistoryWithoutItemIDStillDecodes() throws {
        let data = Data("[{\"kind\":\"Agent\",\"text\":\"old\",\"time\":0}]".utf8)
        let records = try JSONDecoder().decode([StreamRecord].self, from: data)
        XCTAssertEqual(records.first?.text, "old")
        XCTAssertNil(records.first?.itemID)
    }
}
