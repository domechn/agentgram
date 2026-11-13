import SwiftUI
import UniformTypeIdentifiers
import AgentCore

struct ConversationView: View {
    @Environment(AppStore.self) private var store
    let conv: Conversation
    let agent: Agent
    @State private var query = ""
    @State private var results: [Msg]?
    @State private var showSessions = false

    var body: some View {
        VStack(spacing: 0) {
            if store.searching { searchResults } else if conv.msgs.isEmpty && conv.drafts.isEmpty && !conv.loading { emptyState } else { timeline }
            ComposerView(conv: conv, agent: agent)
        }
        .overlay(alignment: .top) { header }
        .onChange(of: store.searching) {
            if !store.searching {
                results = nil
                query = ""
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in conv.attachments.append(url) } }
                }
            }
            return true
        }
    }

    private var activityText: String {
        switch store.activity[conv.id] ?? store.status(conv.id.chatId) {
        case .streaming: "working…"
        case .typing: "thinking…"
        case nil: agent.offline ? "offline" : ""
        }
    }

    /// Floating pill: who you are talking to, and the controls for this conversation.
    private var header: some View {
        HStack(spacing: 8) {
            Avatar(path: agent.avatarPath, title: agent.title, size: 24, symbol: agent.group != nil ? "person.2.fill" : nil)
            VStack(alignment: .leading, spacing: 0) {
                Text(agent.group.map { $0.members.joined(separator: ", ") } ?? store.title(conv.id))
                    .font(.callout.weight(.semibold)).lineLimit(1)
                let detail = [agent.group?.name, activityText.isEmpty ? (agent.group == nil ? agent.subtitle : nil) : activityText]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: 360, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            if store.searching {
                TextField("Search messages", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit {
                        let query = query
                        Task { results = await store.search(query, in: conv.id) }
                    }
            }
            if conv.run != nil {
                Button { Task { await store.hermesStop(conv) } } label: { Image(systemName: "stop.circle.fill").foregroundStyle(.red) }
                    .buttonStyle(.plain).help("Stop this turn").accessibilityLabel("Stop this turn")
            }
            if let profile = agent.hermes {
                IconButton(symbol: "clock.arrow.circlepath", help: "Earlier chats") { showSessions = true }
                    .popover(isPresented: $showSessions, arrowEdge: .bottom) { SessionPicker(profile: profile) }
            }
            IconButton(symbol: store.searching ? "xmark" : "magnifyingglass", help: "Search in this chat (⌘F)") { store.searching.toggle() }
            if agent.isHermes {
                IconButton(symbol: "sidebar.right", help: "Workspace (⌘I)") { store.showWorkspace.toggle() }
            }
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 3)
        .background(Theme.surface, in: Capsule())
        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Avatar(path: agent.avatarPath, title: agent.title, size: 56, symbol: agent.group != nil ? "person.2.fill" : nil)
            Text("Say hello to \(agent.title).").font(.title2).foregroundStyle(.secondary)
            if agent.group != nil {
                Text("Mention a member with @ to address them.").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if conv.hasMore {
                        Button(conv.loading ? "Loading…" : "Load earlier messages") {
                            let first = conv.msgs.first?.id
                            Task {
                                await store.loadMore(conv)
                                if let first { proxy.scrollTo(first, anchor: .top) }
                            }
                        }
                        .buttonStyle(.link).font(.caption).disabled(conv.loading)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(conv.msgs) { message in
                        MessageView(msg: message, reply: replyPreview(message), isLast: message.id == conv.msgs.last?.id) {
                            conv.replyTo = message
                        }
                        .equatable()
                    }
                    ForEach(conv.drafts) { draft in
                        MessageView(msg: draft, isLast: true).equatable()
                    }
                }
                .padding(.horizontal, 18).padding(.top, 58).padding(.bottom, 10)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            // Follows new output only while the user is at the bottom.
            .defaultScrollAnchor(.bottom)
        }
    }

    private func replyPreview(_ message: Msg) -> String? {
        guard message.replyTo != 0 else { return nil }
        return conv.msgs.first { $0.id == message.replyTo }?.preview ?? "Earlier message"
    }

    @ViewBuilder private var searchResults: some View {
        if let results, !results.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(results) { MessageView(msg: $0).equatable() }
                }
                .padding(.horizontal, 18).padding(.top, 58).padding(.bottom, 10)
            }
        } else {
            ContentUnavailableView(
                results == nil ? "Search this chat" : "No results",
                systemImage: "magnifyingglass",
                description: Text(results == nil ? "Type a query above and press Return." : "Nothing matches “\(query)”."))
        }
    }
}

/// Earlier Hermes sessions of one bot.
struct SessionPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let profile: String
    @State private var sessions: [SessionInfo]?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("New chat") {
                store.newChat()
                dismiss()
            }
            .buttonStyle(.link).padding(.bottom, 4)
            if let sessions {
                if sessions.isEmpty { Text("No earlier chats.").foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sessions) { session in
                            Button {
                                Task { await store.hermesOpenSession(profile, session.id) }
                                dismiss()
                            } label: {
                                Text(session.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 300)
        .task { sessions = await store.hermesSessions(profile) }
    }
}

struct MessageView: View, Equatable {
    @Environment(AppStore.self) private var store
    let msg: Msg
    var reply: String?
    var isLast = false
    var onReply: (() -> Void)?
    @State private var expanded: Bool?

    // Closures are not compared: a row re-renders only when what it shows changes.
    static func == (a: MessageView, b: MessageView) -> Bool {
        a.msg == b.msg && a.reply == b.reply && a.isLast == b.isLast
    }

    var body: some View {
        // Long messages collapse, except the newest one (it may still be streaming).
        let long = msg.text.utf8.count > 4000 || msg.blocks.count > 40
        let collapsed = long && !(expanded ?? isLast)
        HStack(alignment: .top, spacing: 10) {
            if msg.outgoing {
                Spacer(minLength: 60)
            } else {
                Avatar(path: nil, title: msg.sender.isEmpty ? "?" : msg.sender, size: 26)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !msg.outgoing { Text(msg.sender).font(.caption.weight(.semibold)) }
                    Text(time).font(.caption2).foregroundStyle(.tertiary)
                    if msg.edited { Text("edited").font(.caption2).foregroundStyle(.tertiary) }
                    switch msg.state {
                    case .sent: EmptyView()
                    case .pending: Text("sending…").font(.caption2).foregroundStyle(.tertiary)
                    case .failed(let reason): Text("failed: \(reason)").font(.caption2).foregroundStyle(.red)
                    }
                }
                if let reply {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1).fill(.tint).frame(width: 2)
                        Text(reply).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(msg.attachments, id: \.fileId) { AttachmentView(attachment: $0) }
                if !msg.blocks.isEmpty {
                    MarkdownView(blocks: msg.blocks)
                        .frame(maxHeight: collapsed ? 320 : nil, alignment: .top)
                        .clipped()
                    if long {
                        Button(collapsed ? "Show more" : "Show less") { expanded = collapsed }
                            .buttonStyle(.link).font(.caption)
                    }
                } else if msg.attachments.isEmpty && !msg.outgoing {
                    ProgressView().controlSize(.small) // the turn has started, nothing to show yet
                }
                ForEach(Array(msg.buttons.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, button in
                            Button(button.text) { press(button) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(.horizontal, msg.outgoing ? 12 : 0).padding(.vertical, msg.outgoing ? 8 : 0)
            .background(msg.outgoing ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !msg.outgoing { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: msg.outgoing ? .trailing : .leading)
        .contextMenu {
            if let onReply, !isHermesChatID(msg.chatId) { Button("Reply", action: onReply) }
            Button("Copy") { Pasteboard.copy(msg.text) }
        }
    }

    private var time: String {
        guard msg.date > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msg.date))
        return date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    private func press(_ button: Btn) {
        switch button.action {
        case .callback(let data): Task { await store.press(data, on: msg) }
        case .url(let string):
            if let url = URL(string: string) { NSWorkspace.shared.open(url) }
        case .copy(let text):
            Pasteboard.copy(text)
            store.toast = "Copied"
        case .approval(let profile, let run, let requestId, let generation, let choice):
            Task { await store.hermesApprove(profile: profile, run: run, requestId: requestId, generation: generation, choice: choice) }
        case .unsupported: store.toast = "This button type is not supported."
        }
    }
}

struct AttachmentView: View {
    @Environment(AppStore.self) private var store
    let attachment: Attachment

    var body: some View {
        if attachment.kind == .photo {
            Group {
                if let path = store.files[attachment.fileId], let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 280, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        .accessibilityLabel("Photo")
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 200, height: 120)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .task { _ = await store.download(attachment.fileId) }
        } else {
            // shortcut: voice/audio/video open in the default app (Ogg/Opus has no system
            // player); add an inline player if agents start sending voice often.
            Button {
                Task {
                    if let path = await store.download(attachment.fileId) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    } else {
                        store.toast = "Download failed."
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.title3).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.name).lineLimit(1)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Download and open")
        }
    }

    private var icon: String {
        switch attachment.kind {
        case .voice: "waveform"
        case .audio: "music.note"
        case .video: "film"
        default: "doc"
        }
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file)
        guard attachment.duration > 0 else { return size }
        return String(format: "%d:%02d · %@", attachment.duration / 60, attachment.duration % 60, size)
    }
}
