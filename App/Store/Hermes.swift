import Foundation
import Observation
import TDLibKit
import AgentCore

struct BotForm: Identifiable {
    let id = UUID()
    var cloneFrom: String?
}

struct GroupForm: Identifiable {
    let id = UUID()
    var group: GroupInfo?
}

struct BridgeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What the app knows about the Hermes host. Lives in `AppStore.hermes`.
@MainActor @Observable
final class HermesState {
    enum Status: Equatable {
        case off, connecting
        case connected(String) // Hermes version line
        case failed(String)
    }

    /// The bridge version this app's Schedules and Library were written against.
    static let requiredBridge = "0.2.1"

    var status = Status.off
    var apiEnabled = true
    var bridgeVersion = ""
    // Library: every bot's files, kept so the view opens instantly the second time.
    var library: [HostFile] = []
    var libraryLoaded = false
    var libraryLoading = false
    var libraryError: String?
    // Schedules: Hermes cron jobs of every profile.
    var jobs: [CronJob] = []
    var jobOffsets: [String: Int] = [:] // profile -> seconds east of UTC its cron runs in
    var jobsLoaded = false
    var jobsLoading = false
    var jobsError: String?
    var profiles: [HermesProfile] = []
    var groups: [GroupInfo] = []
    var models: [String] = []
    var toolsets: [Toolset] = []
    var boards: [KanbanBoard] = []
    var board: String? // nil = the board Hermes considers current
    var tasks: [KanbanTask] = []
    var boardError: String?

    struct Pending {
        var finish: (Result<(json: Data, file: String?), Swift.Error>) -> Void
        var onStream: ((StreamFrame) -> Void)?
        var messages: [Int64] = [] // bridge messages to delete once the reply is in
    }

    @ObservationIgnored var chatId: Int64 = 0
    @ObservationIgnored var key: Data?
    @ObservationIgnored var pending: [String: Pending] = [:]
    @ObservationIgnored var sending: [Int64: String] = [:] // unsent message id -> request id
    @ObservationIgnored var nextMsgId: Int64 = 0
    @ObservationIgnored var poll: Task<Void, Never>?
    @ObservationIgnored var versionLine = ""

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// The host still runs a bridge without `jobs.*` and the one-request `files.list`.
    var bridgeOutdated: Bool { isConnected && versionIsOlder(bridgeVersion, than: Self.requiredBridge) }
}

/// Stream state of one request: a chat turn has one message, a group message one per speaker.
private final class LiveTurn {
    var ids: [Int: Int64] = [:]
    var segments: [Int: [Int: String]] = [:]
}

extension AppStore {
    var bridgeBot: String {
        get { UserDefaults.standard.string(forKey: "bridgeBot") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "bridgeBot") }
    }

    // MARK: - Connection

    func hermesReset() {
        hermes.poll?.cancel()
        for id in Array(hermes.pending.keys) { bridgeFinish(id, .failure(BridgeFailure("Disconnected."))) }
        hermes.status = .off
        hermes.chatId = 0
        hermes.library = []
        hermes.libraryLoaded = false
        hermes.jobs = []
        hermes.jobsLoaded = false
        agents.removeAll { $0.isHermes }
    }

    /// Settings → Connect to Hermes. An empty key keeps the one in the Keychain.
    func hermesConfigure(bot: String, key: String) async {
        if !key.isEmpty {
            guard BridgeFrame.key(fromBase64: key) != nil else {
                hermes.status = .failed("That is not a bridge key. Paste the value install.sh printed.")
                return
            }
            bridgeKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        bridgeBot = bot.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
        await hermesConnect()
    }

    func hermesDisconnect() {
        bridgeBot = ""
        bridgeKey.save(nil)
        hermesReset()
    }

    func hermesConnect() async {
        hermes.poll?.cancel()
        let bot = bridgeBot
        guard !bot.isEmpty, let key = bridgeKey.load().flatMap(BridgeFrame.key(fromBase64:)) else {
            hermes.status = .off
            return
        }
        hermes.key = key
        hermes.status = .connecting
        do {
            let chat = try await client.searchPublicChat(username: bot)
            guard case .chatTypePrivate = chat.type else { throw BridgeFailure("@\(bot) is not a bot.") }
            hermes.chatId = chat.id
            let hello: Hello = try await bridge("hello", timeout: 25)
            hermes.apiEnabled = hello.api
            hermes.bridgeVersion = hello.bridge
            hermes.versionLine = hello.hermes
            hermes.status = .connected(hello.hermes)
        } catch {
            hermes.status = .failed(describe(error))
            return
        }
        await hermesRefresh()
        if selection == nil, let first = agents.first { selection = ConvID(chatId: first.id) }
        hermes.poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await self?.hermesRefresh()
            }
        }
        // Only the forms need these.
        if let list: ModelList = try? await bridge("models.list") { hermes.models = list.models }
        if let list: ToolsetList = try? await bridge("toolsets.list") { hermes.toolsets = list.toolsets }
    }

    /// Profiles and groups become ordinary agents, so the rest of the app treats them like chats.
    func hermesRefresh() async {
        guard hermes.chatId != 0, hermes.status != .off, hermes.status != .connecting else { return }
        let profiles: ProfileList, groups: GroupList
        do {
            profiles = try await bridge("profiles.list")
            groups = try await bridge("groups.list")
        } catch {
            // The bridge stopped answering: say so (the banner offers Retry); the next poll tries again.
            hermes.status = .failed(describe(error))
            return
        }
        if case .failed = hermes.status { hermes.status = .connected(hermes.versionLine) }
        hermes.profiles = profiles.profiles
        hermes.groups = groups.groups
        var fresh: [Agent] = groups.groups.map { group in
            let id = hermesChatID("group:" + group.id)
            var item = agent(id) ?? Agent(id: id, title: group.name)
            item.title = group.name
            item.group = group
            item.subtitle = group.members.joined(separator: ", ")
            return item
        }
        fresh += profiles.profiles.map { profile in
            let id = hermesChatID(profile.name)
            var item = agent(id) ?? Agent(id: id, title: profile.name)
            item.hermes = profile.name
            item.subtitle = profile.model
            item.offline = profile.gateway != "running"
            return item
        }
        let next = fresh + agents.filter { !$0.isHermes }
        if agents != next { agents = next }
        if let selection, agent(selection.chatId) == nil { self.selection = nil }
    }

    // MARK: - Transport

    func bridge<T: Decodable>(_ op: String, _ args: [String: Any] = [:], timeout: Double = 90, upload: URL? = nil,
                              onStream: ((StreamFrame) -> Void)? = nil) async throws -> T {
        let reply = try await bridgeRaw(op, args, timeout: timeout, upload: upload, onStream: onStream)
        return try JSONDecoder().decode(BridgeData<T>.self, from: reply.json).data
    }

    /// Sends one sealed request and waits for the reply with the same id. `file` is the local
    /// path of the document the reply came with (files.get).
    func bridgeRaw(_ op: String, _ args: [String: Any] = [:], timeout: Double = 90, upload: URL? = nil,
                   onStream: ((StreamFrame) -> Void)? = nil) async throws -> (json: Data, file: String?) {
        guard let key = hermes.key, hermes.chatId != 0 else {
            throw BridgeFailure("Not connected to Hermes. Open Settings to connect.")
        }
        let chatId = hermes.chatId
        let id = UUID().uuidString
        let sealed = try BridgeFrame.seal(BridgeFrame.request(id: id, op: op, args: args), key: key)
        let frame = BridgeFrame.text(sealed)
        func document(_ url: URL, caption: String) -> InputMessageContent {
            .inputMessageDocument(InputMessageDocument(
                caption: FormattedText(entities: [], text: caption),
                document: InputDocument(disableContentTypeDetection: true, document: .inputFileLocal(InputFileLocal(path: url.path)), thumbnail: nil)))
        }
        let content: InputMessageContent
        if let upload {
            content = document(upload, caption: frame)
        } else if frame.count <= BridgeFrame.textLimit {
            content = .inputMessageText(InputMessageText(clearDraft: false, linkPreviewOptions: nil, text: FormattedText(entities: [], text: frame)))
        } else {
            // Too long for a message: the bridge reads a document named ag1.bin as a frame.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ag1-\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("ag1.bin")
            try sealed.write(to: url)
            content = document(url, caption: "")
        }
        return try await withCheckedThrowingContinuation { continuation in
            hermes.pending[id] = HermesState.Pending(finish: { continuation.resume(with: $0) }, onStream: onStream)
            Task {
                do {
                    let sent = try await client.sendMessage(chatId: chatId, inputMessageContent: content, options: nil, replyMarkup: nil, replyTo: nil, topicId: nil)
                    if hermes.pending[id] != nil { hermes.sending[sent.id] = id }
                } catch {
                    bridgeFinish(id, .failure(error))
                }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                bridgeFinish(id, .failure(BridgeFailure("No answer from the Hermes bridge. Check that it is running, that the key matches and that this Mac's clock is right.")))
            }
        }
    }

    private func bridgeFinish(_ id: String, _ result: Result<(json: Data, file: String?), Swift.Error>) {
        guard let pending = hermes.pending.removeValue(forKey: id) else { return }
        hermes.sending = hermes.sending.filter { $0.value != id }
        bridgeDelete(pending.messages)
        pending.finish(result)
    }

    private func bridgeDelete(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let chatId = hermes.chatId
        Task { _ = try? await client.deleteMessages(chatId: chatId, messageIds: ids, revoke: true) }
    }

    /// Everything in the bridge chat is transport: it is handled here and never shown.
    func bridgeConsumes(_ update: Update) -> Bool {
        let chat = hermes.chatId
        guard chat != 0 else { return false }
        switch update {
        case .updateNewMessage(let u) where u.message.chatId == chat:
            if !u.message.isOutgoing { bridgeReceive(u.message.id, u.message.content) }
            return true
        case .updateMessageContent(let u) where u.chatId == chat:
            bridgeReceive(u.messageId, u.newContent)
            return true
        case .updateMessageSendFailed(let u) where u.message.chatId == chat:
            if let id = hermes.sending[u.oldMessageId] { bridgeFinish(id, .failure(BridgeFailure(u.error.message))) }
            return true
        case .updateMessageSendSucceeded(let u) where u.message.chatId == chat:
            hermes.sending[u.oldMessageId] = nil
            return true
        case .updateChatAction(let u) where u.chatId == chat: return true
        default: return false
        }
    }

    private func bridgeReceive(_ messageId: Int64, _ content: MessageContent) {
        switch content {
        case .messageText(let m):
            if let raw = BridgeFrame.raw(fromText: m.text.text) { bridgeHandle(raw, messageId, file: nil) }
        case .messageDocument(let m):
            let fileId = m.document.document.id
            if let raw = BridgeFrame.raw(fromText: m.caption.text) {
                // files.get: the caption is the reply, the document is the file itself.
                Task { bridgeHandle(raw, messageId, file: await downloadTwice(fileId) ?? "") }
            } else if m.document.fileName == "ag1.bin" {
                Task {
                    if let path = await downloadTwice(fileId), let raw = FileManager.default.contents(atPath: path) {
                        bridgeHandle(raw, messageId, file: nil)
                    }
                }
            }
        default: break
        }
    }

    /// Replies ride on these downloads; one retry covers a transient network failure.
    private func downloadTwice(_ fileId: Int) async -> String? {
        if let path = await download(fileId) { return path }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return await download(fileId)
    }

    private func bridgeHandle(_ raw: Data, _ messageId: Int64, file: String?) {
        guard let key = hermes.key, let json = try? BridgeFrame.open(raw, key: key),
              let reply = try? JSONDecoder().decode(BridgeReply.self, from: json) else { return }
        guard hermes.pending[reply.re] != nil else {
            bridgeDelete([messageId]) // a reply to a request from an earlier launch
            return
        }
        if hermes.pending[reply.re]?.messages.contains(messageId) == false {
            hermes.pending[reply.re]?.messages.append(messageId)
        }
        if let stream = reply.stream {
            hermes.pending[reply.re]?.onStream?(stream)
        } else if reply.ok == true, file == "" {
            bridgeFinish(reply.re, .failure(BridgeFailure("The file could not be downloaded from Telegram.")))
        } else if reply.ok == true {
            bridgeFinish(reply.re, .success((json, file)))
        } else {
            bridgeFinish(reply.re, .failure(BridgeFailure(reply.error ?? "The bridge reported an error.")))
        }
    }

    // MARK: - Chat

    private func nextHermesMsgId() -> Int64 {
        hermes.nextMsgId += 1
        return hermes.nextMsgId
    }

    /// Per-profile conversation: `key` names it for Hermes, `id` is the session once it exists.
    func hermesSession(_ profile: String) -> (key: String, id: String?) {
        let all = UserDefaults.standard.dictionary(forKey: "hermesSessions") as? [String: [String: String]] ?? [:]
        return (all[profile]?["key"] ?? "agentgram:\(profile)", all[profile]?["id"])
    }

    private func setHermesSession(_ profile: String, key: String, id: String?) {
        var all = UserDefaults.standard.dictionary(forKey: "hermesSessions") as? [String: [String: String]] ?? [:]
        all[profile] = id.map { ["key": key, "id": $0] } ?? ["key": key]
        UserDefaults.standard.set(all, forKey: "hermesSessions")
    }

    /// The "New chat" pill: a fresh session with the selected agent.
    func newChat() {
        section = .chat
        guard let selection, let agent = agent(selection.chatId) else {
            // Nothing was open: open the first bot rather than do nothing.
            if let first = agents.first(where: { $0.hermes != nil }) {
                self.selection = ConvID(chatId: first.id)
            } else {
                toast = hermes.isConnected ? "Create a bot first (⌘N)." : "Connect to Hermes in Settings first."
            }
            return
        }
        guard let profile = agent.hermes else {
            if agent.group != nil { toast = "A group keeps one shared transcript." }
            return
        }
        let conv = conversation(selection)
        guard !conv.busy else { toast = "Wait for the current turn to finish."; return }
        setHermesSession(profile, key: "agentgram:\(profile):\(UUID().uuidString.prefix(8))", id: nil)
        conv.msgs = []
        conv.hasMore = false
    }

    func hermesSessions(_ profile: String) async -> [SessionInfo] {
        do {
            let list: SessionList = try await bridge("sessions.list", ["profile": profile])
            return list.sessions
        } catch {
            toast = describe(error)
            return []
        }
    }

    func hermesOpenSession(_ profile: String, _ session: String) async {
        let conv = conversation(ConvID(chatId: hermesChatID(profile)))
        guard !conv.busy else { toast = "Wait for the current turn to finish."; return }
        setHermesSession(profile, key: hermesSession(profile).key, id: session)
        conv.msgs = []
        conv.hasMore = true
        await loadMore(conv)
    }

    func hermesLoadHistory(_ conv: Conversation, _ agent: Agent) async {
        conv.hasMore = false
        do {
            let history: History
            if let group = agent.group {
                history = try await bridge("group.history", ["id": group.id])
            } else if let profile = agent.hermes, let session = hermesSession(profile).id {
                history = try await bridge("session.messages", ["profile": profile, "session": session])
            } else {
                return
            }
            guard conv.msgs.isEmpty else { return } // a turn started while this was loading
            conv.msgs = history.messages.map { item in
                let who = item.who ?? item.role ?? ""
                var msg = Msg(id: nextHermesMsgId(), chatId: conv.id.chatId, outgoing: who == "user",
                              sender: who == "user" ? "You" : item.who ?? agent.title, date: Int(item.ts ?? 0))
                msg.setText(item.text)
                return msg
            }
        } catch {
            toast = describe(error)
        }
    }

    private func editHermes(_ conv: Conversation, _ id: Int64, _ change: (inout Msg) -> Void) {
        if let i = conv.msgs.firstIndex(where: { $0.id == id }) { change(&conv.msgs[i]) }
    }

    func hermesSend(_ conv: Conversation, _ agent: Agent, text: String, files: [URL]) async {
        let now = Int(Date().timeIntervalSince1970)
        if let run = conv.run, agent.group == nil, files.isEmpty {
            // A turn is running: the message steers it instead of queueing behind it.
            conv.draft = ""
            do {
                let _: Ignored = try await bridge("run.steer", ["profile": run.profile, "run": run.id, "text": text])
                var note = Msg(id: nextHermesMsgId(), chatId: conv.id.chatId, outgoing: true, sender: "You", date: now)
                note.setText(text)
                conv.msgs.append(note)
            } catch {
                conv.draft = text
                toast = describe(error)
            }
            return
        }
        guard !conv.busy else { toast = "Wait for the current turn to finish."; return }
        conv.history.push(text)
        conv.draft = ""
        conv.attachments = []
        conv.replyTo = nil
        conv.busy = true
        activity[conv.id] = .typing
        defer {
            conv.busy = false
            conv.run = nil
            activity[conv.id] = nil
        }

        var mine = Msg(id: nextHermesMsgId(), chatId: conv.id.chatId, outgoing: true, sender: "You", date: now)
        mine.setText(([text] + files.map { "📎 " + $0.lastPathComponent }).filter { !$0.isEmpty }.joined(separator: "\n\n"))
        mine.state = .pending
        conv.msgs.append(mine)
        let live = LiveTurn()
        let onStream: (StreamFrame) -> Void = { [weak self] frame in self?.hermesApply(frame, to: conv, live: live) }
        do {
            var paths: [String] = []
            for url in files {
                let put: FilePut = try await bridge("file.put", ["profile": agent.members.first ?? "default", "name": String(url.lastPathComponent.suffix(100))], timeout: 600, upload: url)
                paths.append(put.path)
            }
            editHermes(conv, mine.id) { $0.state = .sent }
            if let group = agent.group {
                let turn: GroupTurn = try await bridge("group.send", ["id": group.id, "text": text, "files": paths], timeout: 7200, onStream: onStream)
                for (n, reply) in turn.replies.enumerated() {
                    hermesFinish(conv, live, n: n, who: reply.who, text: reply.text, failed: nil)
                }
            } else if let profile = agent.hermes {
                let session = hermesSession(profile)
                var args: [String: Any] = ["profile": profile, "session": session.key, "text": text, "files": paths]
                if let id = session.id { args["session_id"] = id }
                let result: TurnResult = try await bridge("chat.send", args, timeout: 7200, onStream: onStream)
                if let id = result.session, !id.isEmpty { setHermesSession(profile, key: session.key, id: id) }
                hermesFinish(conv, live, n: 0, who: profile, text: result.output, failed: result.status == "completed" ? nil : result.status)
            }
        } catch {
            editHermes(conv, mine.id) { $0.state = .failed(describe(error)) }
            for id in live.ids.values { editHermes(conv, id) { $0.buttons = [] } }
            toast = describe(error)
            return
        }
        // Unread is cleared by selecting the chat, so only a chat that is not open collects it.
        if selection != conv.id { mutate(conv.id.chatId) { $0.unread += 1 } }
        if selection != conv.id || !isAppActive() { notify(agent.title, conv.msgs.last?.preview ?? "") }
    }

    private func hermesMessage(_ conv: Conversation, _ live: LiveTurn, n: Int, who: String) -> Int64 {
        if let id = live.ids[n] { return id }
        let id = nextHermesMsgId()
        live.ids[n] = id
        conv.msgs.append(Msg(id: id, chatId: conv.id.chatId, sender: who, date: Int(Date().timeIntervalSince1970)))
        return id
    }

    private func hermesApply(_ frame: StreamFrame, to conv: Conversation, live: LiveTurn) {
        let n = frame.n ?? 0
        live.segments[n, default: [:]][frame.off] = frame.text
        var text = renderStream(text: assembleStream(live.segments[n] ?? [:]), tools: frame.tools)
        var buttons: [[Btn]] = []
        if let approval = frame.approval {
            text += "\n\n**Needs your approval** — \(approval.description)\n```\n\(approval.command)\n```"
            let labels = ["once": "Allow once", "session": "Allow for session", "always": "Always allow", "deny": "Deny"]
            buttons = [approval.choices.map { choice in
                Btn(text: labels[choice] ?? choice,
                    action: .approval(profile: frame.who, run: frame.run, requestId: approval.request_id, generation: approval.generation, choice: choice))
            }]
        }
        let id = hermesMessage(conv, live, n: n, who: frame.who)
        editHermes(conv, id) {
            $0.setText(text)
            $0.buttons = buttons
        }
        if !frame.run.isEmpty { conv.run = (frame.who, frame.run) }
        activity[conv.id] = .streaming
    }

    private func hermesFinish(_ conv: Conversation, _ live: LiveTurn, n: Int, who: String, text: String, failed: String?) {
        let id = hermesMessage(conv, live, n: n, who: who)
        editHermes(conv, id) {
            $0.setText(text)
            $0.buttons = []
            if let failed { $0.state = .failed(failed) }
        }
    }

    func hermesApprove(profile: String, run: String, requestId: String, generation: Int, choice: String) async {
        do {
            let _: Ignored = try await bridge("approval.respond", ["profile": profile, "run": run, "request_id": requestId, "generation": generation, "choice": choice])
        } catch {
            toast = describe(error)
        }
    }

    func hermesStop(_ conv: Conversation) async {
        guard let run = conv.run else { return }
        await hermesDo("run.stop", ["profile": run.profile, "run": run.id])
    }

    /// Runs a write op; errors surface as a toast. Returns whether it worked.
    @discardableResult
    func hermesDo(_ op: String, _ args: [String: Any], timeout: Double = 180) async -> Bool {
        do {
            let _: Ignored = try await bridge(op, args, timeout: timeout)
            return true
        } catch {
            toast = describe(error)
            return false
        }
    }

    // MARK: - Bots and groups

    func createBot(name: String, soul: String, model: String, description: String, toolsets: [String]?, workdir: String, cloneFrom: String?) async throws {
        var args: [String: Any] = ["name": name]
        if !soul.isEmpty { args["soul"] = soul }
        if !model.isEmpty { args["model"] = model }
        if !description.isEmpty { args["description"] = description }
        if !workdir.isEmpty { args["workdir"] = workdir }
        if let toolsets { args["toolsets"] = toolsets }
        if let cloneFrom { args["clone_from"] = cloneFrom }
        let _: Ignored = try await bridge(cloneFrom == nil ? "profile.create" : "profile.clone", args, timeout: 600)
        await hermesRefresh()
        selection = ConvID(chatId: hermesChatID(name))
    }

    func deleteBot(_ name: String) async {
        if await hermesDo("profile.delete", ["name": name], timeout: 600) { await hermesRefresh() }
    }

    func saveGroup(id: String?, name: String, members: [String], mode: String) async throws {
        var args: [String: Any] = ["name": name, "members": members, "mode": mode]
        if let id { args["id"] = id }
        let group: GroupInfo = try await bridge("groups.save", args)
        await hermesRefresh()
        selection = ConvID(chatId: hermesChatID("group:" + group.id))
    }

    func deleteGroup(_ id: String) async {
        if await hermesDo("groups.delete", ["id": id]) { await hermesRefresh() }
    }

    // MARK: - Board

    private var boardArgs: [String: Any] { hermes.board.map { ["board": $0] } ?? [:] }

    func boardRefresh() async {
        guard hermes.isConnected else { return }
        do {
            let boards: BoardList = try await bridge("kanban.boards")
            let tasks: TaskList = try await bridge("kanban.list", boardArgs)
            hermes.boards = boards.boards
            if hermes.tasks != tasks.tasks { hermes.tasks = tasks.tasks }
            hermes.boardError = nil
        } catch {
            hermes.boardError = describe(error)
        }
    }

    func taskDetail(_ id: String) async throws -> KanbanDetail {
        try await bridge("kanban.show", boardArgs.merging(["id": id]) { $1 })
    }

    /// assign | comment | complete | block | unblock
    @discardableResult
    func taskAction(_ action: String, id: String, _ extra: [String: Any] = [:]) async -> Bool {
        let ok = await hermesDo("kanban." + action, boardArgs.merging(["id": id]) { $1 }.merging(extra) { $1 })
        if ok { await boardRefresh() }
        return ok
    }

    func createTask(title: String, body: String, assignee: String?) async -> Bool {
        var args = boardArgs
        args["title"] = title
        if !body.isEmpty { args["body"] = body }
        if let assignee { args["assignee"] = assignee }
        let ok = await hermesDo("kanban.create", args)
        if ok { await boardRefresh() }
        return ok
    }

    // MARK: - Files and activity

    func remoteFiles(_ profile: String) async throws -> [HostFile] {
        let list: FileList = try await bridge("files.list", ["profile": profile])
        return list.files.map { file in
            var file = file
            file.profile = file.profile ?? profile
            return file
        }
    }

    /// Every bot's files in one request.
    func libraryRefresh() async {
        guard hermes.isConnected, !hermes.libraryLoading else { return }
        hermes.libraryLoading = true
        defer {
            hermes.libraryLoading = false
            hermes.libraryLoaded = true
        }
        do {
            if hermes.bridgeOutdated {
                // Bridge 0.2.0 lists one profile per request; show what has arrived so far.
                var all: [HostFile] = []
                for profile in hermes.profiles.map(\.name) {
                    all += try await remoteFiles(profile)
                    hermes.library = all
                }
            } else {
                let list: FileList = try await bridge("files.list")
                hermes.library = list.files
            }
            hermes.libraryError = nil
        } catch {
            hermes.libraryError = describe(error)
        }
    }

    // MARK: - Schedules (Hermes cron jobs)

    func jobsRefresh() async {
        guard hermes.isConnected, !hermes.jobsLoading else { return }
        hermes.jobsLoading = true
        defer {
            hermes.jobsLoading = false
            hermes.jobsLoaded = true
        }
        do {
            let list: JobList = try await bridge("jobs.list")
            hermes.jobs = list.jobs
            hermes.jobOffsets = list.offsets
            hermes.jobsError = list.errors.isEmpty ? nil : list.errors.joined(separator: "\n")
        } catch {
            hermes.jobsError = describe(error)
        }
    }

    private func jobReplace(_ job: CronJob) {
        if let i = hermes.jobs.firstIndex(where: { $0.id == job.id && $0.profile == job.profile }) {
            hermes.jobs[i] = job
        } else {
            hermes.jobs.append(job)
        }
    }

    /// Creates the job, or updates `job`. Throws so the form can show Hermes' own message.
    func jobSave(_ job: CronJob?, profile: String, name: String, schedule: String, prompt: String, deliver: String) async throws {
        var args: [String: Any] = ["profile": profile, "name": name, "schedule": schedule, "deliver": deliver]
        if job?.no_agent != true { args["prompt"] = prompt } // a script job has no prompt to overwrite
        if let job { args["id"] = job.id }
        let saved: CronJob = try await bridge(job == nil ? "jobs.create" : "jobs.update", args)
        jobReplace(saved)
    }

    /// pause | resume | run | delete. Errors surface as a toast.
    @discardableResult
    func jobAction(_ action: String, _ job: CronJob) async -> Bool {
        let args: [String: Any] = ["profile": job.profile, "id": job.id]
        do {
            if action == "delete" {
                let _: Ignored = try await bridge("jobs.delete", args)
                hermes.jobs.removeAll { $0.id == job.id && $0.profile == job.profile }
            } else {
                let updated: CronJob = try await bridge("jobs." + action, args)
                jobReplace(updated)
            }
            return true
        } catch {
            toast = describe(error)
            return false
        }
    }

    /// The saved output of the job's newest run.
    func jobOutput(_ job: CronJob) async throws -> JobOutput {
        try await bridge("jobs.output", ["profile": job.profile, "id": job.id])
    }

    /// Fetches a file from the host; returns where TDLib stored it.
    func fetchRemoteFile(profile: String, path: String) async -> String? {
        do {
            let reply = try await bridgeRaw("files.get", ["profile": profile, "path": path], timeout: 600)
            return reply.file.flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            toast = describe(error)
            return nil
        }
    }

    func activityInfo(_ profile: String) async throws -> ActivityInfo {
        try await bridge("activity", ["profile": profile])
    }
}
