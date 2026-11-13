import Foundation
import Observation
import TDLibKit
import AgentCore

struct ChatHit: Identifiable, Equatable {
    let id: Int64
    var title: String
}

/// Single source of truth for the UI. Only this type talks to TDLib.
@MainActor @Observable
final class AppStore {
    enum Auth: Equatable {
        case loading, needCredentials, phone, code
        case password(hint: String)
        case ready
        case unsupported(String)
    }

    enum Section: Equatable { case chat, board, library, schedules }

    var auth = Auth.loading
    var authError: String?
    var busy = false
    var connected = false
    var agents: [Agent] = []
    var activity: [ConvID: Activity] = [:]
    var files: [Int: String] = [:] // TDLib file id -> local path
    var selection: ConvID? {
        didSet {
            if selection != nil { section = .chat } // also when re-selecting the current agent from the board
            if selection != oldValue { selectionChanged(from: oldValue) }
        }
    }
    var showSwitcher = false
    var showAddAgent = false
    var searching = false
    var toast: String? {
        didSet {
            guard let shown = toast else { return }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if toast == shown { toast = nil }
            }
        }
    }

    @ObservationIgnored let tg = TG()
    @ObservationIgnored private let credentials: () -> (id: Int, hash: String)?
    @ObservationIgnored private let dataDir: URL
    /// (title, body) for a message that deserves a notification.
    @ObservationIgnored var notify: (String, String) -> Void = { _, _ in }
    @ObservationIgnored var isAppActive: () -> Bool = { true }
    @ObservationIgnored var convs: [ConvID: Conversation] = [:]
    let hermes = HermesState()
    var section = Section.chat
    /// Telegram bots and bot groups are the optional secondary source; Hermes is the primary.
    /// Defaults to on for people who already pinned Telegram agents in v0.1.
    var telegramSource = UserDefaults.standard.object(forKey: "telegramSource") as? Bool
        ?? !((UserDefaults.standard.array(forKey: "pinnedChatIds") ?? []).isEmpty) {
        didSet {
            guard telegramSource != oldValue else { return }
            UserDefaults.standard.set(telegramSource, forKey: "telegramSource")
            if telegramSource {
                Task { for id in pinned { await loadAgent(id) } }
            } else {
                agents.removeAll { !$0.isHermes }
                if let selection, agent(selection.chatId) == nil { self.selection = nil }
            }
        }
    }
    var showSidebar = true
    var showWorkspace = false
    var showSettings = false
    var botForm: BotForm?
    var groupForm: GroupForm?
    /// Loads / stores the bridge key (Keychain; injected so the store stays AppKit-free).
    @ObservationIgnored var bridgeKey: (load: () -> String?, save: (String?) -> Void) = ({ nil }, { _ in })
    @ObservationIgnored private var names: [Int64: String] = [:] // user and chat titles, for senders
    @ObservationIgnored private var streams = StreamTracker<ConvID>()
    @ObservationIgnored private var topicRefreshing: Set<Int64> = []
    @ObservationIgnored private var topicDirty: Set<Int64> = []
    @ObservationIgnored var pinned: [Int64] {
        get { (UserDefaults.standard.array(forKey: "pinnedChatIds") as? [NSNumber])?.map(\.int64Value) ?? [] }
        set { UserDefaults.standard.set(newValue.map { NSNumber(value: $0) }, forKey: "pinnedChatIds") }
    }
    var client: TDLibClient { tg.client }

    init(dataDir: URL, credentials: @escaping () -> (id: Int, hash: String)?) {
        self.dataDir = dataDir
        self.credentials = credentials
        Task { [weak self, updates = tg.updates] in
            for await update in updates { self?.handle(update) }
        }
    }

    var totalUnread: Int { agents.reduce(0) { $0 + $1.unread } }

    func agent(_ chatId: Int64) -> Agent? { agents.first { $0.id == chatId } }

    func status(_ chatId: Int64) -> Activity? {
        let active = activity.filter { $0.key.chatId == chatId }.values
        return active.contains(.streaming) ? .streaming : active.first
    }

    func title(_ id: ConvID) -> String {
        guard let agent = agent(id.chatId) else { return "" }
        guard let topic = agent.topics.first(where: { $0.id == id.topicId }) else { return agent.title }
        return "\(agent.title) › \(topic.name)"
    }

    func conversation(_ id: ConvID) -> Conversation {
        if let conv = convs[id] { return conv }
        let conv = Conversation(id: id)
        convs[id] = conv
        return conv
    }

    /// Esc closes the innermost open panel. False when there was nothing to close.
    @discardableResult
    func escape() -> Bool {
        if showSwitcher { showSwitcher = false; return true }
        if searching { searching = false; return true }
        if showWorkspace { showWorkspace = false; return true }
        return false
    }

    func selectAgent(at index: Int) {
        if agents.indices.contains(index) { selection = ConvID(chatId: agents[index].id) }
    }

    // MARK: - Auth

    func credentialsChanged() {
        guard auth == .needCredentials, let c = credentials() else { return }
        setParameters(c)
    }

    private func setParameters(_ c: (id: Int, hash: String)) {
        auth = .loading
        Task {
            await attempt {
                try FileManager.default.createDirectory(at: self.dataDir, withIntermediateDirectories: true)
                try await self.client.setTdlibParameters(
                    apiHash: c.hash, apiId: c.id, applicationVersion: "0.2.1",
                    databaseDirectory: self.dataDir.path, databaseEncryptionKey: nil, deviceModel: "Mac",
                    filesDirectory: self.dataDir.appendingPathComponent("files").path,
                    systemLanguageCode: "en", systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    useChatInfoDatabase: true, useFileDatabase: true, useMessageDatabase: true,
                    useSecretChats: false, useTestDc: false)
            }
            if authError != nil { auth = .needCredentials }
        }
    }

    private func attempt(_ operation: () async throws -> Void) async {
        authError = nil
        busy = true
        do { try await operation() } catch { authError = describe(error) }
        busy = false
    }

    func submit(phone: String) async {
        await attempt { try await self.client.setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil) }
    }

    func submit(code: String) async {
        await attempt { try await self.client.checkAuthenticationCode(code: code) }
    }

    func submit(password: String) async {
        await attempt { try await self.client.checkAuthenticationPassword(password: password) }
    }

    func logOut() async {
        await attempt { try await self.client.logOut() }
    }

    /// Closes the client so new API credentials can be entered; the session on disk is kept.
    func restartForNewCredentials() async {
        await attempt { try await self.client.close() }
    }

    private func handleAuth(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            if let c = credentials() { setParameters(c) } else { auth = .needCredentials }
        case .authorizationStateWaitPhoneNumber: auth = .phone
        case .authorizationStateWaitCode: auth = .code
        case .authorizationStateWaitPassword(let p): auth = .password(hint: p.passwordHint)
        case .authorizationStateReady:
            auth = .ready
            Task { await restore() }
        case .authorizationStateLoggingOut, .authorizationStateClosing: auth = .loading
        case .authorizationStateClosed:
            auth = .loading
            selection = nil
            agents = []
            convs = [:]
            activity = [:]
            hermesReset()
            tg.start()
        default:
            auth = .unsupported("This sign-in step is not supported here. Finish it in an official Telegram app, then try again.")
        }
    }

    // MARK: - Agents

    private func restore() async {
        _ = try? await client.loadChats(chatList: nil, limit: 200) // makes pinned chats resolvable by id
        if telegramSource { for id in pinned { await loadAgent(id) } }
        await hermesConnect()
        if selection == nil, let first = agents.first { selection = ConvID(chatId: first.id) }
    }

    func findChats(_ query: String) async -> [ChatHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var ids: [Int64] = []
        if !q.contains(" "), let chat = try? await client.searchPublicChat(username: q.replacingOccurrences(of: "@", with: "")) {
            ids.append(chat.id)
        }
        if !q.hasPrefix("@") {
            ids += (try? await client.searchChats(limit: 20, query: q, typeFilter: nil))?.chatIds ?? []
            ids += (try? await client.searchChatsOnServer(limit: 20, query: q, typeFilter: nil))?.chatIds ?? []
        }
        var hits: [ChatHit] = []
        for id in ids where !hits.contains(where: { $0.id == id }) {
            if let chat = try? await client.getChat(chatId: id) { hits.append(ChatHit(id: id, title: chat.title)) }
        }
        return hits
    }

    func pin(_ chatId: Int64) async {
        if !pinned.contains(chatId) { pinned.append(chatId) }
        await loadAgent(chatId)
        selection = ConvID(chatId: chatId)
    }

    func unpin(_ chatId: Int64) {
        pinned.removeAll { $0 == chatId }
        agents.removeAll { $0.id == chatId }
        if selection?.chatId == chatId { selection = nil }
    }

    func mutate(_ chatId: Int64, _ change: (inout Agent) -> Void) {
        if let i = agents.firstIndex(where: { $0.id == chatId }) { change(&agents[i]) }
    }

    private func loadAgent(_ chatId: Int64) async {
        guard let chat = try? await client.getChat(chatId: chatId) else { return }
        var agent = Agent(id: chat.id, title: chat.title, unread: chat.unreadCount)
        switch chat.type {
        case .chatTypePrivate(let p):
            if let user = try? await client.getUser(userId: p.userId), case .userTypeBot(let bot) = user.type {
                agent.botUserId = user.id
                agent.isForum = bot.hasTopics
            }
        case .chatTypeSupergroup(let s):
            agent.supergroupId = s.supergroupId
            agent.isForum = (try? await client.getSupergroup(supergroupId: s.supergroupId))?.isForum ?? false
        default: break
        }
        if let i = agents.firstIndex(where: { $0.id == chatId }) { agents[i] = agent } else { agents.append(agent) }
        refreshTopics(chatId)
        Task { await loadCommands(chatId) }
        if let photo = chat.photo?.small { Task { await loadAvatar(chatId, photo) } }
    }

    private func loadAvatar(_ chatId: Int64, _ file: File) async {
        let path = await download(file.id)
        mutate(chatId) { $0.avatarPath = path }
    }

    private func loadCommands(_ chatId: Int64) async {
        guard let agent = agent(chatId) else { return }
        var commands: [SlashCommand] = []
        if let bot = agent.botUserId {
            commands = (try? await client.getUserFullInfo(userId: bot))?.botInfo?.commands
                .map { SlashCommand(name: $0.command, description: $0.description) } ?? []
        } else if let group = agent.supergroupId,
                  let bots = try? await client.getSupergroupMembers(filter: .supergroupMembersFilterBots, limit: 20, offset: 0, supergroupId: group) {
            // shortcut: basic (non-super) groups get no commands; add getBasicGroupFullInfo if needed.
            for member in bots.members {
                guard case .messageSenderUser(let sender) = member.memberId,
                      let user = try? await client.getUser(userId: sender.userId),
                      let info = try? await client.getUserFullInfo(userId: sender.userId) else { continue }
                // With several bots in a group, a bare /command is ambiguous: address it.
                let suffix = bots.members.count > 1 ? (user.usernames?.activeUsernames.first.map { "@" + $0 } ?? "") : ""
                commands += info.botInfo?.commands.map { SlashCommand(name: $0.command + suffix, description: $0.description) } ?? []
            }
        }
        mutate(chatId) { $0.commands = commands }
    }

    /// Topic unread counts are not pushed in updates, so re-fetch; coalesces concurrent requests.
    private func refreshTopics(_ chatId: Int64) {
        guard agent(chatId)?.isForum == true else { return }
        guard topicRefreshing.insert(chatId).inserted else { topicDirty.insert(chatId); return }
        Task {
            repeat {
                topicDirty.remove(chatId)
                if let result = try? await client.getForumTopics(chatId: chatId, limit: 100, offsetDate: 0, offsetForumTopicId: 0, offsetMessageId: 0, query: "") {
                    let topics = result.topics.filter { !$0.info.isHidden }
                        .map { Topic(id: $0.info.forumTopicId, name: $0.info.name, unread: $0.unreadCount) }
                    mutate(chatId) { $0.topics = topics }
                }
            } while topicDirty.contains(chatId)
            topicRefreshing.remove(chatId)
        }
    }

    // MARK: - Conversations

    private func selectionChanged(from old: ConvID?) {
        searching = false
        if selection != nil { section = .chat }
        if let old, old.chatId != selection?.chatId, !isHermesChatID(old.chatId) {
            Task { _ = try? await client.closeChat(chatId: old.chatId) }
        }
        guard let selection else { return }
        let conv = conversation(selection)
        if isHermesChatID(selection.chatId) {
            mutate(selection.chatId) { $0.unread = 0 }
            Task { if conv.msgs.isEmpty { await loadMore(conv) } }
            return
        }
        Task {
            if old?.chatId != selection.chatId { _ = try? await client.openChat(chatId: selection.chatId) }
            if conv.msgs.isEmpty {
                // The first getChatHistory call may return only the cached last message.
                for _ in 0..<3 where conv.hasMore && conv.msgs.count < 30 { await loadMore(conv) }
            }
            markRead(conv)
        }
    }

    func loadMore(_ conv: Conversation) async {
        guard !conv.loading, conv.hasMore else { return }
        conv.loading = true
        defer { conv.loading = false }
        if let agent = agent(conv.id.chatId), agent.isHermes {
            await hermesLoadHistory(conv, agent)
            return
        }
        let from = conv.msgs.first?.id ?? 0
        do {
            let page = conv.id.topicId == 0
                ? try await client.getChatHistory(chatId: conv.id.chatId, fromMessageId: from, limit: 50, offset: 0, onlyLocal: false)
                : try await client.getForumTopicHistory(chatId: conv.id.chatId, forumTopicId: conv.id.topicId, fromMessageId: from, limit: 50, offset: 0)
            let new = (page.messages ?? []).map(msg)
            if new.isEmpty { conv.hasMore = false }
            conv.msgs = mergeSorted(conv.msgs, new) { $0.id }
        } catch {
            conv.hasMore = false
            toast = describe(error)
        }
    }

    private func markRead(_ conv: Conversation) {
        let ids = conv.msgs.suffix(30).filter { !$0.outgoing }.map(\.id)
        guard !ids.isEmpty, isAppActive() else { return }
        Task { _ = try? await client.viewMessages(chatId: conv.id.chatId, forceRead: true, messageIds: ids, source: nil) }
    }

    func send(_ conv: Conversation) async {
        let text = conv.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = conv.attachments
        guard !text.isEmpty || !files.isEmpty else { return }
        if let agent = agent(conv.id.chatId), agent.isHermes {
            await hermesSend(conv, agent, text: text, files: files)
            return
        }
        let reply = conv.replyTo
        conv.history.push(text)
        conv.draft = ""
        conv.attachments = []
        conv.replyTo = nil

        // shortcut: text goes out as plain text (no entities); bots parse it themselves.
        let formatted = FormattedText(entities: [], text: text)
        var contents: [InputMessageContent] = files.enumerated().map { index, url in
            let caption = index == 0 && !text.isEmpty ? formatted : nil
            let file = InputFile.inputFileLocal(InputFileLocal(path: url.path))
            if ["png", "jpg", "jpeg", "heic", "webp"].contains(url.pathExtension.lowercased()) {
                return .inputMessagePhoto(InputMessagePhoto(
                    caption: caption, hasSpoiler: false,
                    photo: InputPhoto(addedStickerFileIds: [], height: 0, photo: file, thumbnail: nil, video: nil, width: 0),
                    selfDestructType: nil, showCaptionAboveMedia: false))
            }
            return .inputMessageDocument(InputMessageDocument(
                caption: caption, document: InputDocument(disableContentTypeDetection: false, document: file, thumbnail: nil)))
        }
        if files.isEmpty {
            contents = [.inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: formatted))]
        }
        let topic: MessageTopic? = conv.id.topicId == 0 ? nil : .messageTopicForum(MessageTopicForum(forumTopicId: conv.id.topicId))
        let replyTo: InputMessageReplyTo? = reply.map {
            .inputMessageReplyToMessage(InputMessageReplyToMessage(checklistTaskId: 0, messageId: $0.id, pollOptionId: "", quote: nil))
        }
        for content in contents {
            do {
                _ = try await client.sendMessage(chatId: conv.id.chatId, inputMessageContent: content, options: nil, replyMarkup: nil, replyTo: replyTo, topicId: topic)
            } catch {
                toast = describe(error)
            }
        }
    }

    func search(_ query: String, in id: ConvID) async -> [Msg] {
        if isHermesChatID(id.chatId) {
            return conversation(id).msgs.filter { $0.text.localizedCaseInsensitiveContains(query) }
        }
        let topic: MessageTopic? = id.topicId == 0 ? nil : .messageTopicForum(MessageTopicForum(forumTopicId: id.topicId))
        do {
            return try await client.searchChatMessages(chatId: id.chatId, filter: nil, fromMessageId: 0, limit: 50, offset: 0, query: query, senderId: nil, topicId: topic)
                .messages.map(msg)
        } catch {
            toast = describe(error)
            return []
        }
    }

    /// Presses an inline-keyboard callback button; the bot's answer (if any) is shown as a toast.
    func press(_ data: Data, on message: Msg) async {
        do {
            let answer = try await client.getCallbackQueryAnswer(
                chatId: message.chatId, messageId: message.id,
                payload: .callbackQueryPayloadData(CallbackQueryPayloadData(data: data)))
            if !answer.text.isEmpty { toast = answer.text }
        } catch {
            toast = describe(error)
        }
    }

    /// Downloads a file (or returns the cached path).
    @discardableResult
    func download(_ fileId: Int) async -> String? {
        if let path = files[fileId] { return path }
        guard let file = try? await client.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: 16, synchronous: true),
              file.local.isDownloadingCompleted else { return nil }
        files[fileId] = file.local.path
        return file.local.path
    }

    // MARK: - Updates

    private func msg(from m: Message) -> Msg {
        var out = Msg(id: m.id, chatId: m.chatId, outgoing: m.isOutgoing, date: m.date, edited: m.editDate != 0)
        if case .messageTopicForum(let topic)? = m.topicId { out.topicId = topic.forumTopicId }
        switch m.senderId {
        case .messageSenderUser(let u): out.sender = m.isOutgoing ? "You" : names[u.userId] ?? ""
        case .messageSenderChat(let c): out.sender = names[c.chatId] ?? ""
        }
        if case .messageReplyToMessage(let reply)? = m.replyTo { out.replyTo = reply.messageId }
        switch m.sendingState {
        case .messageSendingStatePending?: out.state = .pending
        case .messageSendingStateFailed(let failure)?: out.state = .failed(failure.error.message)
        case nil: break
        }
        out.setContent(m.content)
        out.setMarkup(m.replyMarkup)
        return out
    }

    /// Open conversations a message of this chat/topic belongs to: its topic and the whole chat.
    private func conversations(chatId: Int64, topicId: Int) -> [Conversation] {
        Set([ConvID(chatId: chatId, topicId: topicId), ConvID(chatId: chatId)]).compactMap { convs[$0] }
    }

    private func edit(_ chatId: Int64, _ messageId: Int64, _ change: (inout Msg) -> Void) {
        for (id, conv) in convs where id.chatId == chatId {
            if let i = conv.msgs.firstIndex(where: { $0.id == messageId }) { change(&conv.msgs[i]) }
        }
    }

    private func noteStreaming(_ id: ConvID) {
        streams.noteEdit(id)
        activity[id] = .streaming
        Task {
            try? await Task.sleep(nanoseconds: UInt64(streams.window * 1_000_000_000) + 50_000_000)
            if !streams.isStreaming(id), activity[id] == .streaming { activity[id] = nil }
        }
    }

    private func handle(_ update: Update) {
        if bridgeConsumes(update) { return }
        switch update {
        case .updateAuthorizationState(let u): handleAuth(u.authorizationState)
        case .updateConnectionState(let u):
            if case .connectionStateReady = u.state { connected = true } else { connected = false }
            // A handshake that failed while offline is retried once Telegram is reachable again.
            if connected, auth == .ready, case .failed = hermes.status { Task { await hermesConnect() } }
        case .updateUser(let u):
            names[u.user.id] = [u.user.firstName, u.user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        case .updateNewChat(let u): names[u.chat.id] = u.chat.title
        case .updateChatTitle(let u):
            names[u.chatId] = u.title
            mutate(u.chatId) { $0.title = u.title }
        case .updateChatPhoto(let u):
            if agent(u.chatId) != nil, let photo = u.photo?.small { Task { await loadAvatar(u.chatId, photo) } }
        case .updateChatReadInbox(let u): mutate(u.chatId) { $0.unread = u.unreadCount }
        case .updateForumTopic(let u): refreshTopics(u.chatId)
        case .updateForumTopicInfo(let u): refreshTopics(u.info.chatId)
        case .updateFile(let u):
            if u.file.local.isDownloadingCompleted, files[u.file.id] == nil { files[u.file.id] = u.file.local.path }

        case .updateNewMessage(let u): newMessage(msg(from: u.message))
        case .updateMessageContent(let u):
            edit(u.chatId, u.messageId) { m in
                m.setContent(u.newContent)
                if !m.outgoing { noteStreaming(ConvID(chatId: m.chatId, topicId: m.topicId)) }
            }
        case .updateMessageEdited(let u):
            edit(u.chatId, u.messageId) { m in
                m.edited = true
                m.setMarkup(u.replyMarkup)
            }
        case .updateMessageSendSucceeded(let u): replace(u.oldMessageId, with: msg(from: u.message))
        case .updateMessageSendFailed(let u): replace(u.oldMessageId, with: msg(from: u.message))
        case .updateDeleteMessages(let u):
            guard u.isPermanent else { break }
            for (id, conv) in convs where id.chatId == u.chatId {
                conv.msgs.removeAll { u.messageIds.contains($0.id) }
            }

        case .updateChatAction(let u):
            var id = ConvID(chatId: u.chatId)
            if case .messageTopicForum(let topic)? = u.topicId { id.topicId = topic.forumTopicId }
            if case .chatActionCancel = u.action {
                if activity[id] == .typing { activity[id] = nil }
            } else if activity[id] == nil {
                activity[id] = .typing
            }
        case .updatePendingMessage(let u):
            var draft = Msg(id: u.draftId.rawValue, chatId: u.chatId, topicId: u.forumTopicId,
                            sender: agent(u.chatId)?.title ?? "", date: Int(Date().timeIntervalSince1970))
            draft.setContent(u.content)
            for conv in conversations(chatId: u.chatId, topicId: u.forumTopicId) {
                if let i = conv.drafts.firstIndex(where: { $0.id == draft.id }) { conv.drafts[i] = draft } else { conv.drafts.append(draft) }
            }
            noteStreaming(ConvID(chatId: u.chatId, topicId: u.forumTopicId))
        case .updateStopMessageDraft(let u):
            for conv in conversations(chatId: u.chatId, topicId: u.forumTopicId) {
                conv.drafts.removeAll { $0.id == u.draftId.rawValue }
            }
        default: break
        }
    }

    private func replace(_ oldId: Int64, with message: Msg) {
        for conv in conversations(chatId: message.chatId, topicId: message.topicId) {
            conv.msgs.removeAll { $0.id == oldId }
            conv.msgs = mergeSorted(conv.msgs, [message]) { $0.id }
        }
    }

    private func newMessage(_ message: Msg) {
        let targets = conversations(chatId: message.chatId, topicId: message.topicId)
        for conv in targets {
            conv.msgs = mergeSorted(conv.msgs, [message]) { $0.id }
            if !message.outgoing { conv.drafts = [] } // the streamed draft became this message
        }
        guard !message.outgoing, let agent = agent(message.chatId) else { return }
        refreshTopics(message.chatId)
        let id = ConvID(chatId: message.chatId, topicId: message.topicId)
        if activity[id] == .typing { activity[id] = nil }
        if isAppActive(), let visible = targets.first(where: { $0.id == selection }) {
            markRead(visible)
        } else if Double(message.date) > Date().timeIntervalSince1970 - 60 { // not for backlog synced at launch
            let topic = agent.topics.first { $0.id == message.topicId }?.name
            notify([agent.title, topic].compactMap { $0 }.joined(separator: " › "), message.preview)
        }
    }
}
