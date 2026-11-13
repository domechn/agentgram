import SwiftUI
import AgentCore

/// Right panel: what an agent (or a group's members) is working on, has produced, and is doing.
struct WorkspacePanel: View {
    enum Tab: String, CaseIterable { case board = "Board", files = "Files", activity = "Activity" }

    @Environment(AppStore.self) private var store
    let agent: Agent
    @State private var tab = Tab.board
    @State private var task: KanbanTask?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                IconButton(symbol: "chevron.left", help: "Back") { task = nil }
                    .opacity(task == nil ? 0.25 : 1).disabled(task == nil)
                Spacer()
                Text("\(agent.title)’s workspace").font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                IconButton(symbol: "xmark", help: "Close workspace") { store.showWorkspace = false }
            }
            .padding(.horizontal, 8).padding(.top, 8)
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 8)
            .onChange(of: tab) { task = nil }

            switch tab {
            case .board:
                if let task { TaskDetailView(task: task) } else { board }
            case .files: HostFileList(profiles: agent.members)
            case .activity: ActivityList(profiles: agent.members)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas.ignoresSafeArea())
    }

    /// The board filtered to this agent, or to the group's members.
    private var board: some View {
        let columns = kanbanColumns(store.hermes.tasks, assignees: Set(agent.members)).filter { !$0.tasks.isEmpty }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if columns.isEmpty {
                    Text("No tasks assigned to \(agent.title).").font(.callout).foregroundStyle(.secondary).padding(.top, 20)
                        .frame(maxWidth: .infinity)
                }
                ForEach(columns) { column in
                    HStack(spacing: 6) {
                        Circle().fill(statusColor(column.status)).frame(width: 8, height: 8)
                        Text(column.status.capitalized).font(.caption.weight(.semibold))
                        Text("\(column.tasks.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                    ForEach(column.tasks) { item in
                        Button { task = item } label: { TaskCard(task: item) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .task { await store.boardRefresh() }
    }
}

struct HostFileItem: Identifiable {
    let profile: String
    let file: HostFile
    var id: String { profile + ":" + file.path }
}

/// Files in the bots' workspaces on the Hermes host; a click fetches and opens one.
struct HostFileList: View {
    @Environment(AppStore.self) private var store
    let profiles: [String]
    @State private var items: [HostFileItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var fetching: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    Button { open(item) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc").foregroundStyle(.blue).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.file.name).lineLimit(1)
                                Text("\(item.profile) · \(ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file)) · \(Date(timeIntervalSince1970: TimeInterval(item.file.mtime)).formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if fetching == item.id { ProgressView().controlSize(.small) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Download and open")
                }
                if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 16)
                } else if let error {
                    Text(error).font(.callout).foregroundStyle(.red).padding(12)
                } else if items.isEmpty {
                    Text("No files yet. Files a bot writes to its workspace, and files you send it, show up here.")
                        .font(.callout).foregroundStyle(.secondary).padding(12)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
        .task(id: profiles) {
            items = []
            loading = true
            error = nil
            for profile in profiles {
                do {
                    items += try await store.remoteFiles(profile).map { HostFileItem(profile: profile, file: $0) }
                } catch {
                    self.error = describe(error)
                }
            }
            loading = false
        }
    }

    private func open(_ item: HostFileItem) {
        guard fetching == nil else { return }
        fetching = item.id
        Task {
            if let path = await store.fetchRemoteFile(profile: item.profile, path: item.file.path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            fetching = nil
        }
    }
}

struct ActivityList: View {
    let profiles: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(profiles, id: \.self) { ActivityCard(profile: $0) }
            }
            .padding(12)
        }
    }
}

/// Gateway state, running turns and tasks, and the tail of the profile's agent log.
struct ActivityCard: View {
    @Environment(AppStore.self) private var store
    let profile: String
    @State private var info: ActivityInfo?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Avatar(path: nil, title: profile, size: 20)
                Text(profile).font(.callout.weight(.semibold))
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await load() } }
            }
            if let info {
                HStack(spacing: 6) {
                    Circle().fill(info.gateway == "running" ? Color.green : Color.red).frame(width: 7, height: 7)
                    Text("Gateway \(info.gateway) · \(info.model)").font(.caption).foregroundStyle(.secondary)
                }
                Text(info.runs.isEmpty ? "No turn running from AgentGram." : "\(info.runs.count) turn(s) running.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(info.tasks) { task in
                    Label(task.title, systemImage: "play.circle").font(.caption).lineLimit(2)
                }
                if !info.log.isEmpty {
                    Text(info.log).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Theme.selected, in: RoundedRectangle(cornerRadius: 8))
                }
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .card(radius: 12)
        .task(id: profile) { await load() }
    }

    private func load() async {
        do {
            info = try await store.activityInfo(profile)
            error = nil
        } catch {
            self.error = describe(error)
        }
    }
}

/// Every bot's files in one place.
struct LibraryView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library").font(.title2.weight(.semibold))
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
            if store.hermes.isConnected {
                HostFileList(profiles: store.hermes.profiles.map(\.name)).frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 12)
            } else {
                ContentUnavailableView("Not connected to Hermes", systemImage: "books.vertical",
                                       description: Text("Open Settings (⌘,) to connect to your Hermes bridge."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
