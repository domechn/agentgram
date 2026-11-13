import XCTest
@testable import AgentCore

final class BridgeTests: XCTestCase {
    private let key = Data(0..<32)
    /// Real output captured on the Hermes host, also used by the bridge's own tests.
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("hermes-bridge/fixtures/\(name)"))
    }

    func testFrameTextRoundTrip() {
        let raw = Data((0..<200).map { UInt8($0) })
        let text = BridgeFrame.text(raw)
        XCTAssertTrue(text.hasPrefix("AG1."))
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="))
        XCTAssertEqual(BridgeFrame.raw(fromText: text), raw)
        XCTAssertNil(BridgeFrame.raw(fromText: "hello"))
    }

    func testKeyMustBe32Bytes() {
        XCTAssertEqual(BridgeFrame.key(fromBase64: key.base64EncodedString() + "\n"), key)
        XCTAssertNil(BridgeFrame.key(fromBase64: "c2hvcnQ="))
        XCTAssertNil(BridgeFrame.key(fromBase64: "not base64"))
    }

    func testRequestShape() throws {
        let data = BridgeFrame.request(id: "r1", op: "chat.send", args: ["profile": "team-ceo", "files": ["/a"]], ts: 5)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["op"] as? String, "chat.send")
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual((obj["args"] as? [String: Any])?["profile"] as? String, "team-ceo")
    }

    #if canImport(CryptoKit)
    func testOpensFrameSealedByThePythonBridge() throws {
        // Same vector as hermes-bridge/test_bridge.py::test_known_vector_shared_with_swift.
        let frame = "AG1.AAECAwQFBgcICQoL8tl-IhMmiWLF5h3JunxsAOtckIg6VpfNlOJKuGsE0LCwLE9ZOZKkie593fY"
        let json = try BridgeFrame.open(XCTUnwrap(BridgeFrame.raw(fromText: frame)), key: key)
        let reply = try JSONDecoder().decode(BridgeReply.self, from: json)
        XCTAssertEqual(reply.re, "abc")
        XCTAssertEqual(reply.ok, true)
    }

    func testSealRoundTripAndTamperDetection() throws {
        let sealed = try BridgeFrame.seal(Data("{\"a\":1}".utf8), key: key)
        XCTAssertEqual(try BridgeFrame.open(sealed, key: key), Data("{\"a\":1}".utf8))
        var bad = sealed
        bad[bad.count - 1] ^= 1
        XCTAssertThrowsError(try BridgeFrame.open(bad, key: key))
        XCTAssertThrowsError(try BridgeFrame.open(sealed, key: Data(repeating: 0, count: 32)))
    }
    #endif

    func testDecodesStreamAndFinalReplies() throws {
        let stream = Data(#"{"v":1,"re":"r1","stream":{"seq":3,"off":0,"text":"hi","tools":[{"id":"t","tool":"terminal","preview":"echo hi","state":"done"}],"approval":{"request_id":"p","generation":2,"command":"rm -rf /tmp/x","description":"delete","choices":["once","deny"]},"run":"run_1","who":"team-ceo"}}"#.utf8)
        let reply = try JSONDecoder().decode(BridgeReply.self, from: stream)
        XCTAssertNil(reply.ok)
        XCTAssertEqual(reply.stream?.approval?.generation, 2)
        XCTAssertEqual(reply.stream?.tools.first?.tool, "terminal")

        let final = Data(#"{"v":1,"re":"r1","ok":true,"data":{"output":"done","status":"completed","session":"s","run":"run_1"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(BridgeData<TurnResult>.self, from: final).data.output, "done")
        let failed = Data(#"{"v":1,"re":"r1","ok":false,"error":"no such profile: x"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(BridgeReply.self, from: failed).error, "no such profile: x")
    }

    func testDecodesRealKanbanOutput() throws {
        let tasks = try JSONDecoder().decode([KanbanTask].self, from: fixture("kanban_list.json"))
        XCTAssertEqual(tasks.first?.status, "done")
        XCTAssertEqual(tasks.first?.assignee, "default")
        let detail = try JSONDecoder().decode(KanbanDetail.self, from: fixture("kanban_show.json"))
        XCTAssertEqual(detail.task.id, "t_534e27fa")
        XCTAssertEqual(detail.comments.count, 3)
        XCTAssertEqual(detail.runs.last?.outcome, "completed")
        XCTAssertTrue(detail.events.contains { $0.kind == "completed" })
        XCTAssertEqual(detail.parents, [])
    }

    func testKanbanLinksAsIdsOrObjects() throws {
        let json = Data(#"{"task":{"id":"t1","title":"x","status":"todo"},"parents":["t0"],"children":[{"id":"t2","title":"c"}]}"#.utf8)
        let detail = try JSONDecoder().decode(KanbanDetail.self, from: json)
        XCTAssertEqual(detail.parents, ["t0"])
        XCTAssertEqual(detail.children, ["t2"])
    }

    func testKanbanColumns() {
        let tasks = [
            KanbanTask(id: "1", title: "a", assignee: "team-ceo", status: "running"),
            KanbanTask(id: "2", title: "b", assignee: "team-cro", status: "review"),
            KanbanTask(id: "3", title: "c", assignee: nil, status: "todo"),
            KanbanTask(id: "4", title: "d", assignee: "team-ceo", status: "weird"),
        ]
        XCTAssertEqual(kanbanColumns(tasks).map(\.status), ["todo", "ready", "running", "review", "blocked", "done", "weird"])
        let mine = kanbanColumns(tasks, assignees: ["team-ceo"])
        XCTAssertEqual(mine.map(\.status), ["todo", "ready", "running", "blocked", "done", "weird"])
        XCTAssertEqual(mine.first { $0.status == "running" }?.tasks.map(\.id), ["1"])
        XCTAssertEqual(mine.first { $0.status == "todo" }?.tasks, [])
    }

    func testAssembleStreamSegments() {
        XCTAssertEqual(assembleStream([:]), "")
        XCTAssertEqual(assembleStream([0: "hello"]), "hello")
        // A frozen first segment plus the live second one; an older edit of the first is replaced.
        XCTAssertEqual(assembleStream([5: " world", 0: "hello"]), "hello world")
        XCTAssertEqual(assembleStream([0: "数据数据", 4: "end"]), "数据数据end")
    }

    func testRenderStream() {
        let tools = [ToolLine(tool: "terminal", preview: "echo hi", state: "done"), ToolLine(tool: "web", preview: "q", state: "running")]
        XCTAssertEqual(renderStream(text: "\n\nhi", tools: tools), "> `terminal` echo hi ✓\n\n> `web` q …\n\nhi")
        XCTAssertEqual(renderStream(text: "hi", tools: []), "hi")
    }

    func testMentions() {
        XCTAssertNil(mentionQuery(in: "hello"))
        XCTAssertNil(mentionQuery(in: "mail me@x"))
        XCTAssertEqual(mentionQuery(in: "@"), "")
        XCTAssertEqual(mentionQuery(in: "ask @TEAM-c"), "team-c")
        XCTAssertNil(mentionQuery(in: "ask @team-ceo now"))
        XCTAssertEqual(completeMention("ask @team-c", with: "team-cro"), "ask @team-cro ")
        XCTAssertEqual(filterMentions(["team-ceo", "team-cro", "ops-team"], query: "team"), ["team-ceo", "team-cro", "ops-team"])
        XCTAssertEqual(filterMentions(["team-ceo", "team-cro"], query: "team-cr"), ["team-cro"])
    }

    func testProfileNames() {
        XCTAssertTrue(isValidProfileName("team-ceo2"))
        for bad in ["", "default", "Bad", "-x", "a b", "../x", String(repeating: "a", count: 42)] {
            XCTAssertFalse(isValidProfileName(bad), bad)
        }
    }

    func testHermesIdsAreStableAndOutsideTelegramRange() {
        XCTAssertEqual(hermesChatID("team-ceo"), hermesChatID("team-ceo"))
        XCTAssertNotEqual(hermesChatID("team-ceo"), hermesChatID("team-cro"))
        XCTAssertTrue(isHermesChatID(hermesChatID("group:g1")))
        XCTAssertFalse(isHermesChatID(-1001234567890))
        XCTAssertFalse(isHermesChatID(7_000_000_000))
        XCTAssertEqual(avatarInitials("team-chief-researcher"), "RE")
        XCTAssertEqual(avatarInitials("default"), "DE")
        XCTAssertTrue((0..<1).contains(avatarHue("team-ceo")))
    }
}
