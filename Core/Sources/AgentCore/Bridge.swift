import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Wire format shared with hermes-bridge/bridge.py (docs/DESIGN.md, "Wire protocol").
public enum BridgeFrame {
    public static let prefix = "AG1."
    public static let textLimit = 4096

    public static func text(_ raw: Data) -> String {
        prefix + raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func raw(fromText text: String) -> Data? {
        guard text.hasPrefix(prefix) else { return nil }
        var body = text.dropFirst(prefix.count)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        return Data(base64Encoded: body)
    }

    /// The shared key as pasted from `install.sh`: base64 of exactly 32 bytes.
    public static func key(fromBase64 string: String) -> Data? {
        guard let data = Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else { return nil }
        return data
    }

    public static func request(id: String, op: String, args: [String: Any], ts: Double = Date().timeIntervalSince1970) -> Data {
        // The arguments are built by the app from strings, numbers and arrays of them.
        (try? JSONSerialization.data(withJSONObject: ["v": 1, "id": id, "ts": ts, "op": op, "args": args])) ?? Data()
    }

    #if canImport(CryptoKit)
    private static let aad = Data("AG1".utf8)

    /// nonce(12) ‖ ciphertext ‖ tag(16), ChaCha20-Poly1305.
    public static func seal(_ json: Data, key: Data) throws -> Data {
        try ChaChaPoly.seal(json, using: SymmetricKey(data: key), authenticating: aad).combined
    }

    public static func open(_ raw: Data, key: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: raw), using: SymmetricKey(data: key), authenticating: aad)
    }
    #else
    // No CryptoKit off Apple platforms; the app never runs there, this keeps it type-checking.
    public static func seal(_ json: Data, key: Data) throws -> Data { throw CocoaError(.featureUnsupported) }
    public static func open(_ raw: Data, key: Data) throws -> Data { throw CocoaError(.featureUnsupported) }
    #endif
}

// MARK: - Envelopes

public struct ToolLine: Decodable, Equatable {
    public var tool: String
    public var preview: String
    public var state: String // running | done | error

    public init(tool: String, preview: String, state: String) {
        self.tool = tool
        self.preview = preview
        self.state = state
    }
}

/// For replies whose payload the app does not read.
public struct Ignored: Decodable {
    public init(from decoder: Decoder) throws {}
}

public struct Approval: Decodable, Equatable {
    public var request_id: String
    public var generation: Int
    public var command: String
    public var description: String
    public var choices: [String]
}

public struct StreamFrame: Decodable, Equatable {
    public var seq: Int
    public var off: Int
    public var text: String
    public var tools: [ToolLine]
    public var approval: Approval?
    public var run: String
    public var who: String
    public var n: Int? // which turn of the request; a group message produces several
}

/// The part of every reply that does not depend on the operation.
public struct BridgeReply: Decodable {
    public var re: String
    public var ok: Bool?
    public var error: String?
    public var stream: StreamFrame?
}

public struct BridgeData<T: Decodable>: Decodable {
    public var data: T
}

public struct Hello: Decodable {
    public var bridge: String
    public var hermes: String
    public var api: Bool
}

public struct HermesProfile: Decodable, Equatable, Identifiable {
    public var name: String
    public var model: String
    public var gateway: String
    public var description: String?
    public var id: String { name }
}

public struct ProfileList: Decodable { public var profiles: [HermesProfile] }
public struct ModelList: Decodable { public var models: [String] }

public struct Toolset: Decodable, Equatable, Identifiable {
    public var name: String
    public var label: String
    public var enabled: Bool
    public var id: String { name }
}

public struct ToolsetList: Decodable { public var toolsets: [Toolset] }

public struct TurnResult: Decodable {
    public var output: String
    public var status: String
    public var session: String?
    public var run: String?
}

public struct GroupInfo: Decodable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var members: [String]
    public var mode: String
}

public struct GroupList: Decodable { public var groups: [GroupInfo] }

public struct GroupReply: Decodable {
    public var who: String
    public var text: String
}

public struct GroupTurn: Decodable { public var replies: [GroupReply] }

public struct HistoryMessage: Decodable {
    public var role: String? // session history: user | assistant
    public var who: String?  // group transcript: user | <profile>
    public var text: String
    public var ts: Double?
}

public struct History: Decodable { public var messages: [HistoryMessage] }

public struct SessionInfo: Decodable, Identifiable {
    public var id: String
    public var title: String
}

public struct SessionList: Decodable { public var sessions: [SessionInfo] }

public struct HostFile: Decodable, Equatable, Identifiable {
    public var path: String
    public var name: String
    public var size: Int64
    public var mtime: Int
    /// Set by `files.list` without a profile (bridge 0.2.1): whose file it is, and where it
    /// came from: sent | workspace | board.
    public var profile: String?
    public var source: String?
    public var id: String { path }

    public init(path: String, name: String, size: Int64, mtime: Int, profile: String? = nil, source: String? = nil) {
        self.path = path
        self.name = name
        self.size = size
        self.mtime = mtime
        self.profile = profile
        self.source = source
    }
}

public struct FileList: Decodable { public var files: [HostFile] }
public struct FilePut: Decodable { public var path: String }

public struct ActivityInfo: Decodable {
    public struct Task: Decodable, Identifiable {
        public var id: String
        public var title: String
    }
    public var gateway: String
    public var model: String
    public var runs: [String]
    public var tasks: [Task]
    public var log: String
}

// MARK: - Kanban

public struct KanbanBoard: Decodable, Equatable, Identifiable {
    public var slug: String
    public var name: String
    public var total: Int
    public var current: Bool
    public var id: String { slug }
}

public struct BoardList: Decodable { public var boards: [KanbanBoard] }

public struct KanbanTask: Decodable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var assignee: String?
    public var status: String
    public var body: String?

    public init(id: String, title: String, assignee: String? = nil, status: String, body: String? = nil) {
        self.id = id
        self.title = title
        self.assignee = assignee
        self.status = status
        self.body = body
    }
}

public struct TaskList: Decodable { public var tasks: [KanbanTask] }

/// `hermes kanban show --json`, passed through by the bridge unchanged.
public struct KanbanDetail: Decodable {
    public struct Comment: Decodable {
        public var author: String?
        public var body: String
        public var created_at: Double?
    }
    public struct Event: Decodable {
        public var kind: String
        public var created_at: Double?
    }
    public struct Run: Decodable {
        public var profile: String?
        public var status: String?
        public var outcome: String?
        public var summary: String?
    }
    public var task: KanbanTask
    public var latest_summary: String?
    public var parents: [String]
    public var children: [String]
    public var comments: [Comment]
    public var events: [Event]
    public var runs: [Run]

    private enum Keys: String, CodingKey { case task, latest_summary, parents, children, comments, events, runs }
    private struct Ref: Decodable { var id: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        task = try c.decode(KanbanTask.self, forKey: .task)
        latest_summary = try? c.decode(String.self, forKey: .latest_summary)
        // Links come as ids or as task objects depending on the Hermes version.
        func links(_ key: Keys) -> [String] {
            (try? c.decode([String].self, forKey: key)) ?? (try? c.decode([Ref].self, forKey: key))?.map(\.id) ?? []
        }
        parents = links(.parents)
        children = links(.children)
        comments = (try? c.decode([Comment].self, forKey: .comments)) ?? []
        events = (try? c.decode([Event].self, forKey: .events)) ?? []
        runs = (try? c.decode([Run].self, forKey: .runs)) ?? []
    }
}

public struct KanbanColumn: Equatable, Identifiable {
    public var status: String
    public var tasks: [KanbanTask]
    public var id: String { status }
}

/// Columns in workflow order. The core ones are always present; the others only when used.
/// `assignees` (a group's members) filters the board; nil shows everything.
public func kanbanColumns(_ tasks: [KanbanTask], assignees: Set<String>? = nil) -> [KanbanColumn] {
    let order = ["triage", "todo", "ready", "running", "review", "blocked", "scheduled", "done"]
    let core: Set<String> = ["todo", "ready", "running", "blocked", "done"]
    let shown = tasks.filter { task in assignees.map { $0.contains(task.assignee ?? "") } ?? true }
    let extra = Set(shown.map(\.status)).subtracting(order).sorted()
    return (order + extra).compactMap { status in
        let column = shown.filter { $0.status == status }
        return column.isEmpty && !core.contains(status) ? nil : KanbanColumn(status: status, tasks: column)
    }
}

// MARK: - Streams, mentions, identity

/// Rebuilds streamed output from its segments (`off` → text from that character offset).
/// Each segment is self-contained, so the newest edit of each is all that is needed.
public func assembleStream(_ segments: [Int: String]) -> String {
    var text = ""
    for off in segments.keys.sorted() {
        text = String(text.prefix(off)) + (segments[off] ?? "")
    }
    return text
}

/// Markdown for a turn in progress: tool activity as a quote above the text so far.
public func renderStream(text: String, tools: [ToolLine]) -> String {
    let lines = tools.map { tool -> String in
        let mark = tool.state == "running" ? "…" : tool.state == "error" ? "✗" : "✓"
        return "> `\(tool.tool)` \(tool.preview.replacingOccurrences(of: "\n", with: " ")) \(mark)"
    }
    return (lines + [text.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: "\n\n")
}

/// The partial `@name` at the end of the draft, or nil when no mention is being typed.
public func mentionQuery(in draft: String) -> String? {
    guard let at = draft.lastIndex(of: "@") else { return nil }
    let before = at == draft.startIndex ? " " : draft[draft.index(before: at)]
    let tail = draft[draft.index(after: at)...]
    guard before.isWhitespace, !tail.contains(where: { $0.isWhitespace }) else { return nil }
    return tail.lowercased()
}

public func completeMention(_ draft: String, with name: String) -> String {
    guard let at = draft.lastIndex(of: "@") else { return draft }
    return String(draft[..<at]) + "@" + name + " "
}

public func filterMentions(_ members: [String], query: String) -> [String] {
    members.filter { query.isEmpty || $0.lowercased().hasPrefix(query) } + members.filter { !query.isEmpty && !$0.lowercased().hasPrefix(query) && $0.lowercased().contains(query) }
}

/// Same rule as the bridge: lowercase letters, digits and dashes.
public func isValidProfileName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, name.count <= 41, name != "default" else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    return allowed.contains(first) && name.unicodeScalars.allSatisfy { allowed.contains($0) || $0 == "-" }
}

/// A stable chat id for a Hermes agent or group. Bit 62 is set, far outside any Telegram chat
/// id, so these never collide with real chats (FNV-1a over the name).
public func hermesChatID(_ name: String) -> Int64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in name.utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x100000001b3
    }
    return Int64(1) << 62 | Int64(hash & 0xFFFF_FFFF_FFFF)
}

public func isHermesChatID(_ id: Int64) -> Bool { id >= Int64(1) << 62 }

/// Avatar colour and glyph generated from a name; stable across launches.
public func avatarHue(_ name: String) -> Double {
    Double(hermesChatID(name) & 0xFFFF % 360) / 360
}

public func avatarInitials(_ name: String) -> String {
    let parts = name.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "_" }).filter { !$0.isEmpty }
    // "team-ceo" and "team-cro" share a prefix: prefer the last part, which tells them apart.
    return String((parts.last ?? Substring(name)).prefix(2)).uppercased()
}
