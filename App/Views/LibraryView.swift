import SwiftUI
import AgentCore

/// Every bot's files in one place: what you sent them, what they wrote to their workspaces and
/// what board tasks produced. One bridge request, kept in the store between visits.
struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var profile: String?
    @State private var kind: FileKind?
    @State private var fetching: String?

    var body: some View {
        let hermes = store.hermes
        let files = filterFiles(hermes.library, query: query, profile: profile, kind: kind)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Library") {
                if hermes.libraryLoading { ProgressView().controlSize(.small) }
                Spacer()
                TextField("Search files", text: $query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Picker("Bot", selection: $profile) {
                    Text("All bots").tag(String?.none)
                    ForEach(owners, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden().fixedSize()
                Picker("Type", selection: $kind) {
                    Text("All types").tag(FileKind?.none)
                    ForEach(FileKind.allCases) { Text($0.rawValue).tag(FileKind?.some($0)) }
                }
                .labelsHidden().fixedSize()
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.libraryRefresh() } }
                    .disabled(!hermes.isConnected || hermes.libraryLoading)
            }
            if !hermes.isConnected {
                ContentUnavailableView("Not connected to Hermes", systemImage: "books.vertical",
                                       description: Text("Open Settings (⌘,) to connect to your Hermes bridge."))
            } else {
                if let error = hermes.libraryError {
                    ErrorBanner(text: error) { Task { await store.libraryRefresh() } }
                        .padding(.horizontal, 20).padding(.bottom, 8)
                }
                if hermes.library.isEmpty && !hermes.libraryLoaded {
                    SkeletonRows().padding(.horizontal, 12)
                    Spacer(minLength: 0)
                } else if hermes.library.isEmpty {
                    ContentUnavailableView("No files yet", systemImage: "tray",
                                           description: Text("Files a bot writes to its workspace, files you send it and what board tasks produce show up here."))
                } else if files.isEmpty {
                    ContentUnavailableView("No matching files", systemImage: "magnifyingglass",
                                           description: Text("Nothing matches the search and filters."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(files) { file in row(file) }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                        .frame(maxWidth: 860, alignment: .leading)
                    }
                    Text("\(files.count) of \(hermes.library.count) files · newest first")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.horizontal, 20).padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: hermes.isConnected) { await store.libraryRefresh() }
    }

    /// Bots that own at least one listed file.
    private var owners: [String] {
        Array(Set(store.hermes.library.compactMap(\.profile))).sorted()
    }

    private func row(_ file: HostFile) -> some View {
        HStack(spacing: 2) {
            Button { run(file) { NSWorkspace.shared.open($0) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol(fileKind(file.name))).foregroundStyle(.blue).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).lineLimit(1)
                        Text(detail(file)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Download and open")
            if fetching == file.id {
                ProgressView().controlSize(.small).frame(width: 56)
            } else {
                IconButton(symbol: "square.and.arrow.down", help: "Save As…") { save(file) }
                IconButton(symbol: "folder", help: "Download and reveal in Finder") {
                    run(file) { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .rowHighlight()
        .contextMenu {
            Button("Open") { run(file) { NSWorkspace.shared.open($0) } }
            Button("Save As…") { save(file) }
            Button("Reveal in Finder") { run(file) { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
            Divider()
            Button("Copy Path on Host") { Pasteboard.copy(file.path) }
        }
    }

    private func symbol(_ kind: FileKind) -> String {
        switch kind {
        case .document: "doc.text"
        case .image: "photo"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .data: "tablecells"
        case .other: "doc"
        }
    }

    private func detail(_ file: HostFile) -> String {
        let source = ["sent": "sent by you", "workspace": "workspace", "board": "board task"][file.source ?? ""]
        return [file.profile, source, ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file), stamp(Double(file.mtime))]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Fetches the file from the host (TDLib caches it), then hands over its local URL.
    private func run(_ file: HostFile, then action: @escaping (URL) -> Void) {
        guard fetching == nil else { return }
        fetching = file.id
        Task {
            if let path = await store.fetchRemoteFile(profile: file.profile ?? "default", path: file.path) {
                action(URL(fileURLWithPath: path))
            }
            fetching = nil
        }
    }

    private func save(_ file: HostFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let target = panel.url else { return }
        run(file) { source in
            do {
                // The panel already asked before replacing an existing file.
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: source, to: target)
                store.toast = "Saved \(target.lastPathComponent)"
            } catch {
                store.toast = describe(error)
            }
        }
    }
}
