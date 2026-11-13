import XCTest
@testable import AgentCore

final class MarkdownTests: XCTestCase {
    func testEntitiesToMarkdown() {
        // "Hi bold and code" with bold on "bold " (trailing space must be trimmed) and code on "code".
        let md = markdown(from: "Hi bold and code", entities: [
            MDEntity(offset: 3, length: 5, kind: .bold),
            MDEntity(offset: 12, length: 4, kind: .code),
        ])
        XCTAssertEqual(md, "Hi **bold** and `code`")
    }

    func testNestedAndLinkEntities() {
        let md = markdown(from: "see docs now", entities: [
            MDEntity(offset: 4, length: 4, kind: .bold),
            MDEntity(offset: 4, length: 4, kind: .link("https://x.y")),
        ])
        XCTAssertEqual(md, "see **[docs](https://x.y)** now")
    }

    func testUTF16Offsets() {
        // The emoji is two UTF-16 units, so "ok" starts at offset 3.
        let md = markdown(from: "😀 ok", entities: [MDEntity(offset: 3, length: 2, kind: .italic)])
        XCTAssertEqual(md, "😀 _ok_")
    }

    func testPreAndQuoteEntities() {
        let text = "run:\nls -la\ndone\nquoted\nlines"
        let md = markdown(from: text, entities: [
            MDEntity(offset: 5, length: 6, kind: .pre(language: "sh")),
            MDEntity(offset: 17, length: 12, kind: .quote(collapsible: true)),
        ])
        XCTAssertEqual(md, "run:\n```sh\nls -la\n```\ndone\n>! quoted\n>! lines")
        XCTAssertEqual(parseBlocks(md), [
            .paragraph("run:"),
            .code(language: "sh", text: "ls -la"),
            .paragraph("done"),
            .quote(text: "quoted\nlines", collapsible: true),
        ])
    }

    func testBoldAcrossLinesIsSplit() {
        let md = markdown(from: "a\nb", entities: [MDEntity(offset: 0, length: 3, kind: .bold)])
        XCTAssertEqual(md, "**a**\n**b**")
    }

    func testOutOfRangeEntityIsIgnored() {
        XCTAssertEqual(markdown(from: "abc", entities: [MDEntity(offset: 10, length: 5, kind: .bold)]), "abc")
    }

    func testBlocks() {
        let src = """
        # Title
        intro line
        - item

        | a | b |
        |---|:-:|
        | 1 | 2 |
        ---
        > quote
        """
        XCTAssertEqual(parseBlocks(src), [
            .heading(level: 1, text: "Title"),
            .paragraph("intro line\n• item"),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
            .rule,
            .quote(text: "quote", collapsible: false),
        ])
    }

    func testStreamingUnclosedFenceGrowsInPlace() {
        // Mid-stream the fence is still open; earlier blocks must not change as text arrives.
        let a = parseBlocks("text\n```py\nprint(1)")
        let b = parseBlocks("text\n```py\nprint(1)\nprint(2)\n```\nafter")
        XCTAssertEqual(a, [.paragraph("text"), .code(language: "py", text: "print(1)")])
        XCTAssertEqual(b, [.paragraph("text"), .code(language: "py", text: "print(1)\nprint(2)"), .paragraph("after")])
        XCTAssertEqual(a.first, b.first)
    }

    func testPipeWithoutSeparatorIsNotATable() {
        XCTAssertEqual(parseBlocks("a | b"), [.paragraph("a | b")])
    }
}

final class ComposerTests: XCTestCase {
    let commands = [
        SlashCommand(name: "start", description: ""),
        SlashCommand(name: "status", description: ""),
        SlashCommand(name: "restart", description: ""),
    ]

    func testCommandQuery() {
        XCTAssertEqual(commandQuery(in: "/"), "")
        XCTAssertEqual(commandQuery(in: "/STa"), "sta")
        XCTAssertNil(commandQuery(in: "/start now"))
        XCTAssertNil(commandQuery(in: "hello /start"))
        XCTAssertNil(commandQuery(in: ""))
    }

    func testFilterCommands() {
        XCTAssertEqual(filterCommands(commands, query: "").count, 3)
        XCTAssertEqual(filterCommands(commands, query: "sta").map(\.name), ["start", "status", "restart"])
        XCTAssertEqual(filterCommands(commands, query: "res").map(\.name), ["restart"])
        XCTAssertTrue(filterCommands(commands, query: "zzz").isEmpty)
    }

    func testInputHistory() {
        var h = InputHistory()
        XCTAssertNil(h.up(current: ""))
        h.push("one"); h.push("two"); h.push("two")
        XCTAssertEqual(h.items, ["one", "two"])
        XCTAssertEqual(h.up(current: ""), "two")
        XCTAssertEqual(h.up(current: "two"), "one")
        XCTAssertEqual(h.up(current: "one"), "one")
        XCTAssertEqual(h.down(current: "one"), "two")
        XCTAssertEqual(h.down(current: "two"), "")
        XCTAssertNil(h.down(current: ""))
        // Editing text: arrows must not hijack the caret.
        XCTAssertNil(h.up(current: "draft in progress"))
    }
}

final class StreamTests: XCTestCase {
    struct M: Equatable { var id: Int64; var text: String }

    func testMergeSorted() {
        let old = [M(id: 1, text: "a"), M(id: 3, text: "c")]
        let merged = mergeSorted(old, [M(id: 3, text: "c2"), M(id: 2, text: "b")]) { $0.id }
        XCTAssertEqual(merged, [M(id: 1, text: "a"), M(id: 2, text: "b"), M(id: 3, text: "c2")])
    }

    func testStreamTracker() {
        var t = StreamTracker<Int>(window: 3)
        let t0 = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(t.isStreaming(1, now: t0))
        t.noteEdit(1, at: t0)
        XCTAssertTrue(t.isStreaming(1, now: t0.addingTimeInterval(2)))
        XCTAssertFalse(t.isStreaming(1, now: t0.addingTimeInterval(3)))
        XCTAssertFalse(t.isStreaming(2, now: t0))
    }
}
