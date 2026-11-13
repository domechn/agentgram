import SwiftUI
import AgentCore

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Bindable var conv: Conversation
    let agent: Agent
    @State private var paletteIndex = 0
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool

    /// One row of the palette: a slash command, or a group member to @mention.
    private struct Suggestion: Identifiable {
        var id: String
        var detail: String
        var completion: String
    }

    private var matches: [Suggestion] {
        if let query = commandQuery(in: conv.draft) {
            return filterCommands(agent.commands, query: query).prefix(8)
                .map { Suggestion(id: "/" + $0.name, detail: $0.description, completion: "/" + $0.name + " ") }
        }
        if agent.group != nil, let query = mentionQuery(in: conv.draft) {
            return filterMentions(agent.members, query: query).prefix(8)
                .map { Suggestion(id: "@" + $0, detail: "", completion: completeMention(conv.draft, with: $0)) }
        }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            palette
            if let reply = conv.replyTo {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.tint)
                    Text(reply.preview).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button { conv.replyTo = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Cancel reply")
                }
                .font(.callout)
            }
            if !conv.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(conv.attachments, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                Text(url.lastPathComponent).lineLimit(1)
                                Button { conv.attachments.removeAll { $0 == url } } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless).accessibilityLabel("Remove \(url.lastPathComponent)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                editor
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .buttonStyle(.plain).foregroundStyle(.blue)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(conv.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && conv.attachments.isEmpty)
                    .help("Send (⌘↩)")
                    .accessibilityLabel("Send")
            }
        }
        .padding(10)
        .card(radius: 20)
        .frame(maxWidth: 860)
        .padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 4)
        .frame(maxWidth: .infinity)
        .onChange(of: conv.draft) { paletteIndex = 0 }
        .onAppear {
            focused = true
            // Text views ignore pasted images/files; catch ⌘V and attach them instead.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [conv] event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v" else { return event }
                let urls = Pasteboard.attachments()
                if urls.isEmpty { return event }
                conv.attachments += urls
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    @ViewBuilder private var palette: some View {
        let matches = self.matches
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 8) {
                        Text(item.id).font(.callout.monospaced())
                        Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(i == paletteIndex ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { conv.draft = item.completion }
                }
            }
            .padding(4)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var editor: some View {
        // The hidden text sizes the editor: grows with the draft, up to 12 lines.
        Text(conv.draft.isEmpty ? " " : conv.draft + " ")
            .font(.body).lineLimit(12)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(0)
            .accessibilityHidden(true)
            .overlay {
                TextEditor(text: $conv.draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .accessibilityLabel("Message")
                    .onKeyPress(.upArrow) { arrow(-1) }
                    .onKeyPress(.downArrow) { arrow(1) }
                    .onKeyPress(.return) { complete() }
                    .onKeyPress(.tab) { complete() }
                    .onKeyPress(.escape) {
                        guard conv.replyTo != nil else { return .ignored }
                        conv.replyTo = nil
                        return .handled
                    }
            }
            .overlay(alignment: .leading) {
                if conv.draft.isEmpty {
                    Text(conv.run != nil && agent.group == nil ? "Steer the running turn · ⌘↩ send" : "Message \(agent.title) · ⌘↩ send")
                        .foregroundStyle(.tertiary).lineLimit(1)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(4)
    }

    /// Arrow keys drive the palette when it is open, otherwise the input history.
    private func arrow(_ delta: Int) -> KeyPress.Result {
        let matches = self.matches
        if !matches.isEmpty {
            paletteIndex = min(max(paletteIndex + delta, 0), matches.count - 1)
            return .handled
        }
        guard let text = delta < 0 ? conv.history.up(current: conv.draft) : conv.history.down(current: conv.draft) else {
            return .ignored
        }
        conv.draft = text
        return .handled
    }

    private func complete() -> KeyPress.Result {
        let matches = self.matches
        guard matches.indices.contains(paletteIndex) else { return .ignored }
        conv.draft = matches[paletteIndex].completion
        return .handled
    }

    private func send() {
        Task { await store.send(conv) }
    }
}
