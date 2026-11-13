import SwiftUI

@main
struct AgentGramApp: App {
    @State private var store: AppStore

    init() {
        let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentGram/tdlib")
        let store = AppStore(dataDir: dataDir, credentials: Credentials.load)
        store.notify = { Notifier.post(title: $0, body: $1) }
        store.isAppActive = { NSApp?.isActive ?? false }
        store.bridgeKey = ({ Keychain.get("bridge_key") }, { Keychain.set("bridge_key", $0) })
        _store = State(initialValue: store)
        _ = Updater.controller // starts Sparkle's scheduled update checks
    }

    var body: some Scene {
        // WindowGroup rather than Window: closing the window must not quit the app, the
        // menu-bar item and notifications keep working.
        WindowGroup(id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bot…") { store.botForm = BotForm() }
                    .keyboardShortcut("n")
                    .disabled(!store.hermes.isConnected)
                Button("New Group…") { store.groupForm = GroupForm() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!store.hermes.isConnected)
                Button("Pin Telegram Agent…") { store.showAddAgent = true }
                    .disabled(store.auth != .ready || !store.telegramSource)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.sparkle.checkForUpdates() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.showSettings = true }
                    .keyboardShortcut(",")
                    .disabled(store.auth != .ready)
            }
            CommandMenu("Agents") {
                Button("New Chat") { store.newChat() }.keyboardShortcut("t")
                Button("Quick Switcher") { store.showSwitcher.toggle() }.keyboardShortcut("k")
                Button("Search in Chat") { store.searching.toggle() }.keyboardShortcut("f")
                Divider()
                Button("Board") { store.section = .board }.keyboardShortcut("b")
                Button("Library") { store.section = .library }.keyboardShortcut("l")
                Button("Schedules") { store.section = .schedules }.keyboardShortcut("j")
                Button("Toggle Workspace") { store.showWorkspace.toggle() }.keyboardShortcut("i")
                Button("Toggle Sidebar") { store.showSidebar.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                ForEach(0..<9, id: \.self) { i in
                    Button(store.agents.indices.contains(i) ? store.agents[i].title : "Agent \(i + 1)") {
                        store.selectAgent(at: i)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }

        MenuBarExtra {
            MenuBarMenu().environment(store)
        } label: {
            Image(systemName: store.totalUnread > 0 ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
            if store.totalUnread > 0 { Text("\(store.totalUnread)") }
        }
    }
}

struct MenuBarMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(store.agents) { agent in
            Button(agent.unread > 0 ? "\(agent.title) (\(agent.unread))" : agent.title) {
                store.selection = ConvID(chatId: agent.id)
                showWindow()
            }
        }
        Divider()
        Button("Open AgentGram") { showWindow() }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func showWindow() {
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { openWindow(id: "main") }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            switch store.auth {
            case .ready: MainView()
            case .loading: ProgressView()
            default: LoginView()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .task { Notifier.requestPermission() }
    }
}

struct MainView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            if store.showSidebar {
                SidebarView().transition(.move(edge: .leading))
                Divider()
            }
            VStack(spacing: 0) {
                banner
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topLeading) {
                if !store.showSidebar {
                    IconButton(symbol: "sidebar.left", help: "Show sidebar") { store.showSidebar = true }.padding(8)
                }
            }
            if store.showWorkspace, store.section == .chat, let id = store.selection, let agent = store.agent(id.chatId), agent.isHermes {
                Divider()
                WorkspacePanel(agent: agent).id(agent.id).frame(width: 340)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.showWorkspace)
        .animation(.easeInOut(duration: 0.2), value: store.showSidebar)
        .onExitCommand { store.escape() }
        .background(Theme.canvas.ignoresSafeArea())
        .sheet(isPresented: $store.showAddAgent) { AddAgentSheet() }
        .sheet(isPresented: $store.showSettings) { SettingsSheet() }
        .sheet(item: $store.botForm) { BotFormSheet(form: $0) }
        .sheet(item: $store.groupForm) { GroupFormSheet(form: $0) }
        .overlay { if store.showSwitcher { QuickSwitcher() } }
    }

    /// Something is wrong with the connection, and what to do about it.
    @ViewBuilder private var banner: some View {
        Group {
            if case .failed(let reason) = store.hermes.status {
                ErrorBanner(text: "The Hermes bridge is not answering. \(reason)", symbol: "wifi.exclamationmark") {
                    Task { await store.hermesConnect() }
                }
            } else if store.hermes.isConnected && !store.connected {
                ErrorBanner(text: "Telegram is offline, so the bridge cannot be reached. Reconnecting…", symbol: "wifi.slash") {
                    Task { await store.hermesRefresh() }
                }
            } else if store.hermes.bridgeOutdated {
                ErrorBanner(text: "The host runs hermes-bridge \(store.hermes.bridgeVersion); Schedules need \(HermesState.requiredBridge). On the host run: \(store.hermes.bridgeUpgradeHint)",
                            symbol: "arrow.down.circle", action: "Check Again") {
                    Task { await store.hermesConnect() }
                }
            }
        }
        // Clear of the floating chat header and the show-sidebar button.
        .padding(.horizontal, 12).padding(.top, 8).padding(.leading, store.showSidebar ? 0 : 32)
    }

    @ViewBuilder private var content: some View {
        switch store.section {
        case .board: BoardView()
        case .library: LibraryView()
        case .schedules: SchedulesView()
        case .chat:
            if let id = store.selection, let agent = store.agent(id.chatId) {
                ConversationView(conv: store.conversation(id), agent: agent).id(id)
            } else if store.hermes.isConnected || !store.agents.isEmpty {
                ContentUnavailableView("No bot selected", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Pick a bot on the left, or create one with ⌘N."))
            } else {
                ContentUnavailableView {
                    Label("Connect to Hermes", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("AgentGram talks to your Hermes agents through one bridge bot.")
                } actions: {
                    Button("Open Settings") { store.showSettings = true }
                }
            }
        }
    }
}
