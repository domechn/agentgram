import SwiftUI
import AgentCore

/// The Hermes kanban board: columns by status, live-refreshed while visible.
struct BoardView: View {
    @Environment(AppStore.self) private var store
    @State private var detail: KanbanTask?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Board").font(.title2.weight(.semibold))
                Menu(boardName) {
                    ForEach(store.hermes.boards) { board in
                        Button("\(board.name) (\(board.total))") {
                            store.hermes.board = board.slug
                            Task { await store.boardRefresh() }
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Switch board")
                Spacer()
                if let error = store.hermes.boardError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.boardRefresh() } }
                Button("New Task") { creating = true }.disabled(!store.hermes.isConnected)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)

            if !store.hermes.isConnected {
                ContentUnavailableView("Not connected to Hermes", systemImage: "rectangle.split.3x1",
                                       description: Text("Open Settings (⌘,) to connect to your Hermes bridge."))
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(kanbanColumns(store.hermes.tasks)) { column in
                            BoardColumn(column: column) { detail = $0 }
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            // Live refresh is a poll: the bridge has no push channel.
            while !Task.isCancelled {
                await store.boardRefresh()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .sheet(item: $detail) { task in
            VStack(spacing: 0) {
                TaskDetailView(task: task)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { detail = nil }.keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
            .frame(width: 560, height: 620)
        }
        .sheet(isPresented: $creating) { NewTaskSheet() }
    }

    private var boardName: String {
        let boards = store.hermes.boards
        let current = boards.first { $0.slug == store.hermes.board } ?? boards.first { $0.current }
        return current?.name ?? "Default"
    }
}

struct BoardColumn: View {
    let column: KanbanColumn
    let open: (KanbanTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(statusColor(column.status)).frame(width: 8, height: 8)
                Text(column.status.capitalized).font(.callout.weight(.semibold))
                Text("\(column.tasks.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(column.tasks) { task in
                        Button { open(task) } label: { TaskCard(task: task) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 8).padding(.top, 2)
            }
        }
        .frame(width: 250)
    }
}

func statusColor(_ status: String) -> Color {
    switch status {
    case "running": .blue
    case "done": .green
    case "blocked": .red
    case "review": .purple
    case "ready": .orange
    default: .gray
    }
}

struct TaskCard: View {
    let task: KanbanTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title).font(.callout).lineLimit(3).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                if let assignee = task.assignee, !assignee.isEmpty {
                    Avatar(path: nil, title: assignee, size: 16)
                    Text(assignee).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Unassigned").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Text(task.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .card(radius: 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Body, dependencies, comments, runs and events of one task, with the actions on it.
struct TaskDetailView: View {
    @Environment(AppStore.self) private var store
    let task: KanbanTask
    @State private var detail: KanbanDetail?
    @State private var error: String?
    @State private var comment = ""
    @State private var busy = false

    var body: some View {
        let current = detail?.task ?? task
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(current.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 8) {
                    Label(current.status.capitalized, systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(statusColor(current.status))
                    Text(current.assignee.flatMap { $0.isEmpty ? nil : $0 } ?? "Unassigned").font(.caption).foregroundStyle(.secondary)
                    Text(current.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    if busy { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: 8) {
                    Menu("Assign") {
                        ForEach(store.hermes.profiles) { profile in
                            Button(profile.name) { act("assign", ["assignee": profile.name]) }
                        }
                        Divider()
                        Button("Unassign") { act("assign") }
                    }
                    .fixedSize()
                    if current.status == "blocked" || current.status == "scheduled" {
                        Button("Unblock") { act("unblock") }
                    } else if current.status != "done" {
                        Button("Block") { act("block", comment.isEmpty ? [:] : ["text": comment]) }
                    }
                    if current.status != "done" { Button("Complete") { act("complete") } }
                }
                .disabled(busy)

                if let detail {
                    if let body = detail.task.body, !body.isEmpty { MarkdownView(blocks: parseBlocks(body)) }
                    if !detail.parents.isEmpty { labelled("Depends on", detail.parents.joined(separator: ", ")) }
                    if !detail.children.isEmpty { labelled("Blocks", detail.children.joined(separator: ", ")) }
                    if let summary = detail.latest_summary, !summary.isEmpty { labelled("Latest summary", summary) }

                    section("Comments")
                    ForEach(Array(detail.comments.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.author ?? "user") · \(stamp(item.created_at))").font(.caption).foregroundStyle(.secondary)
                            Text(item.body).textSelection(.enabled)
                        }
                    }
                    HStack {
                        TextField("Add a comment (also used as the block reason)", text: $comment).textFieldStyle(.roundedBorder)
                            .onSubmit(sendComment)
                        Button("Comment", action: sendComment).disabled(comment.isEmpty || busy)
                    }

                    if !detail.runs.isEmpty {
                        section("Runs")
                        ForEach(Array(detail.runs.enumerated()), id: \.offset) { _, run in
                            VStack(alignment: .leading, spacing: 2) {
                                Text([run.profile, run.outcome ?? run.status].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption.weight(.semibold))
                                if let summary = run.summary, !summary.isEmpty {
                                    Text(summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !detail.events.isEmpty {
                        section("Events")
                        ForEach(Array(detail.events.suffix(30).enumerated()), id: \.offset) { _, event in
                            HStack {
                                Text(event.kind).font(.caption.monospaced())
                                Spacer()
                                Text(stamp(event.created_at)).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: task.id) { await load() }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func stamp(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }

    private func load() async {
        do {
            detail = try await store.taskDetail(task.id)
            error = nil
        } catch {
            self.error = describe(error)
        }
    }

    private func act(_ action: String, _ extra: [String: Any] = [:]) {
        busy = true
        Task {
            if await store.taskAction(action, id: task.id, extra) { await load() }
            busy = false
        }
    }

    private func sendComment() {
        guard !comment.isEmpty, !busy else { return }
        let text = comment
        comment = ""
        act("comment", ["text": text])
    }
}

struct NewTaskSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var assignee = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New task").font(.headline)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            Text("Details").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $details).font(.body).frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("Details")
            Picker("Assignee", selection: $assignee) {
                Text("Unassigned").tag("")
                ForEach(store.hermes.profiles) { Text($0.name).tag($0.name) }
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    busy = true
                    Task {
                        if await store.createTask(title: title, body: details, assignee: assignee.isEmpty ? nil : assignee) { dismiss() }
                        busy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
