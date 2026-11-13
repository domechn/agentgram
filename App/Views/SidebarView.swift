import SwiftUI
import AgentCore

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("botsExpanded") private var expanded = false
    @State private var deleting: Agent?
    private let collapsedCount = 8

    var body: some View {
        let shown = expanded ? store.agents : Array(store.agents.prefix(collapsedCount))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Spacer()
                IconButton(symbol: "sidebar.left", help: "Hide sidebar") { store.showSidebar = false }
                IconButton(symbol: "magnifyingglass", help: "Search (⌘K)") { store.showSwitcher = true }
            }
            Button { store.newChat() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Color.blue, in: Circle())
                    Text("New chat").fontWeight(.medium)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .card(radius: 18)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            NavRow(title: "Board", symbol: "rectangle.split.3x1", selected: store.section == .board,
                   badge: store.hermes.tasks.filter { $0.status == "running" }.count) { store.section = .board }
            NavRow(title: "Library", symbol: "books.vertical", selected: store.section == .library, badge: 0) { store.section = .library }

            HStack {
                Text("Bots").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("New Bot…") { store.botForm = BotForm() }.disabled(!store.hermes.isConnected)
                    Button("New Group…") { store.groupForm = GroupForm() }.disabled(!store.hermes.isConnected)
                    if store.telegramSource { Button("Pin Telegram Agent…") { store.showAddAgent = true } }
                } label: {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Add bot or group")
            }
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 2)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { agent in rows(agent) }
                    if store.agents.count > collapsedCount {
                        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                            .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    if store.agents.isEmpty {
                        Text(store.hermes.isConnected ? "No bots yet." : "Connect to Hermes in Settings.")
                            .font(.callout).foregroundStyle(.secondary).padding(8)
                    }
                }
            }
            footer
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
        .frame(width: 236)
        .background(Theme.sidebar.ignoresSafeArea())
        .confirmationDialog(
            "Delete \(deleting?.title ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { agent in
            Button("Delete", role: .destructive) {
                Task {
                    if let group = agent.group { await store.deleteGroup(group.id) } else if let profile = agent.hermes { await store.deleteBot(profile) }
                }
            }
        } message: { agent in
            Text(agent.group != nil
                 ? "The group and its transcript are removed. Its bots stay."
                 : "This deletes the Hermes profile, its sessions and its memory on the host. It cannot be undone.")
        }
    }

    @ViewBuilder private func rows(_ agent: Agent) -> some View {
        let id = ConvID(chatId: agent.id)
        Button {
            store.selection = id
            store.section = .chat
        } label: {
            BotRow(agent: agent, status: store.status(agent.id), selected: store.section == .chat && store.selection == id)
        }
        .buttonStyle(.plain)
        .contextMenu { menu(agent) }
        ForEach(agent.topics) { topic in
            let topicId = ConvID(chatId: agent.id, topicId: topic.id)
            Button {
                store.selection = topicId
                store.section = .chat
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "number").font(.caption).foregroundStyle(.secondary)
                    Text(topic.name).lineLimit(1)
                    Spacer()
                    if topic.unread > 0 || store.activity[topicId] != nil { UnreadDot() }
                }
                .padding(.leading, 34).padding(.trailing, 8).padding(.vertical, 5)
                .background(store.section == .chat && store.selection == topicId ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func menu(_ agent: Agent) -> some View {
        if let group = agent.group {
            Button("Edit Group…") { store.groupForm = GroupForm(group: group) }
            Button("Delete Group…", role: .destructive) { deleting = agent }
        } else if let profile = agent.hermes {
            Button("New Chat") {
                store.selection = ConvID(chatId: agent.id)
                store.newChat()
            }
            Button("Open Workspace") {
                store.selection = ConvID(chatId: agent.id)
                store.showWorkspace = true
            }
            Button("Clone…") { store.botForm = BotForm(cloneFrom: profile) }
            Button("Stop Running Turns") { Task { await store.hermesDo("profile.stop", ["name": profile]) } }
            if profile != "default" {
                Divider()
                Button("Delete…", role: .destructive) { deleting = agent }
            }
        } else {
            Button("Unpin") { store.unpin(agent.id) }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            IconButton(symbol: "gearshape", help: "Settings (⌘,)") { store.showSettings = true }
        }
        .padding(.horizontal, 6)
    }

    private var statusText: String {
        switch store.hermes.status {
        case .off: "Hermes not connected"
        case .connecting: "Connecting to Hermes…"
        case .connected: store.connected ? "Hermes connected" : "Telegram offline"
        case .failed: "Hermes connection failed"
        }
    }

    private var statusColor: Color {
        switch store.hermes.status {
        case .connected: store.connected ? .green : .orange
        case .connecting: .orange
        case .failed: .red
        case .off: .gray
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

struct NavRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let badge: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 22)
                Text(title)
                Spacer()
                Badge(count: badge)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BotRow: View {
    let agent: Agent
    let status: Activity?
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Avatar(path: agent.avatarPath, title: agent.title, size: 24, symbol: agent.group != nil ? "person.2.fill" : nil)
                .opacity(agent.offline ? 0.45 : 1)
            Text(agent.title).lineLimit(1)
            if status != nil { ProgressView().controlSize(.mini) }
            Spacer(minLength: 4)
            if agent.unread > 0 { UnreadDot() }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.title + (agent.unread > 0 ? ", unread" : "") + (agent.offline ? ", offline" : ""))
        .help(agent.subtitle)
    }
}

struct UnreadDot: View {
    var body: some View {
        Circle().fill(Color.blue).frame(width: 8, height: 8).accessibilityLabel("Unread")
    }
}

struct Badge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.bold)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .foregroundStyle(.white)
                .background(Color.blue, in: Capsule())
                .accessibilityLabel("\(count)")
        }
    }
}

/// A photo when there is one, otherwise a coloured tile generated from the name.
struct Avatar: View {
    let path: String?
    let title: String
    var size: CGFloat = 28
    var symbol: String?

    var body: some View {
        if let path, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        } else {
            let hue = avatarHue(title)
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95), Color(hue: hue, saturation: 0.75, brightness: 0.75)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: size * 0.42)).foregroundStyle(.white)
                    } else {
                        Text(avatarInitials(title)).font(.system(size: size * 0.4, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    }
                }
                .accessibilityHidden(true)
        }
    }
}

struct AddAgentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [ChatHit]?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pin an agent").font(.headline)
            TextField("@username, or the title of a group you are in", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(search)
            if busy {
                ProgressView().controlSize(.small)
            } else if let hits {
                if hits.isEmpty { Text("Nothing found.").foregroundStyle(.secondary) }
                ForEach(hits) { hit in
                    Button {
                        Task { await store.pin(hit.id) }
                        dismiss()
                    } label: {
                        HStack {
                            Avatar(path: nil, title: hit.title, size: 22)
                            Text(hit.title)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Search", action: search).disabled(query.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func search() {
        guard !query.isEmpty, !busy else { return }
        busy = true
        Task {
            hits = await store.findChats(query)
            busy = false
        }
    }
}

struct QuickSwitcher: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var items: [ConvID] {
        let all = store.agents.flatMap { agent in
            [ConvID(chatId: agent.id)] + agent.topics.map { ConvID(chatId: agent.id, topicId: $0.id) }
        }
        return Array((query.isEmpty ? all : all.filter { store.title($0).localizedCaseInsensitiveContains(query) }).prefix(12))
    }

    var body: some View {
        let items = self.items
        ZStack(alignment: .top) {
            Color.black.opacity(0.15).ignoresSafeArea().onTapGesture { store.showSwitcher = false }
            VStack(spacing: 0) {
                TextField("Switch to agent or topic…", text: $query)
                    .textFieldStyle(.plain).font(.title3).padding(12)
                    .focused($focused)
                    .onSubmit { pick(items, index) }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onKeyPress(.downArrow) { index = max(min(index + 1, items.count - 1), 0); return .handled }
                    .onKeyPress(.escape) { store.showSwitcher = false; return .handled }
                Divider()
                ForEach(Array(items.enumerated()), id: \.element) { i, id in
                    HStack {
                        Text(store.title(id)).lineLimit(1)
                        Spacer()
                        if id.topicId == 0 { Badge(count: store.agent(id.chatId)?.unread ?? 0) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(i == index ? Color.accentColor.opacity(0.25) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { pick(items, i) }
                }
            }
            .frame(width: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
    }

    private func pick(_ items: [ConvID], _ i: Int) {
        if items.indices.contains(i) { store.selection = items[i] }
        store.showSwitcher = false
    }
}
