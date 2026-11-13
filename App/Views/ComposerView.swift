import SwiftUI
import AgentCore

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Bindable var conv: Conversation
    let agent: Agent
    @State private var paletteIndex = 0
    @AppStorage("enterSends") private var enterSends = true

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
                    .disabled(!canSend)
                    .help(enterSends ? "Send (↩)" : "Send (⌘↩)")
                    .accessibilityLabel("Send")
            }
        }
        .padding(10)
        .card(radius: 20)
        .frame(maxWidth: 860)
        .padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 4)
        .frame(maxWidth: .infinity)
        .onChange(of: conv.draft) { paletteIndex = 0 }
    }

    private var placeholder: String {
        let what: String = conv.run != nil && agent.group == nil ? "Steer the running turn" : "Message " + agent.title
        let keys: String = enterSends ? " · ↩ send, ⇧↩ new line" : " · ⌘↩ send"
        return what + keys
    }

    private var canSend: Bool {
        !conv.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !conv.attachments.isEmpty
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
                    .onHover { if $0 { paletteIndex = i } }
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
                ComposerTextView(
                    text: $conv.draft,
                    onReturn: handleReturn,
                    onArrow: arrow,
                    onTab: complete,
                    onEscape: {
                        if conv.replyTo != nil { conv.replyTo = nil; return true }
                        return store.escape()
                    },
                    onPasteFiles: { conv.attachments += $0 })
            }
            .overlay(alignment: .leading) {
                if conv.draft.isEmpty {
                    Text(verbatim: placeholder)
                        .foregroundStyle(.tertiary).lineLimit(1)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(4)
    }

    /// Return: the input method first, then ⇧/⌥ newline, then the palette, then send.
    private func handleReturn(shift: Bool, option: Bool, composing: Bool) -> Bool {
        switch returnAction(shift: shift, option: option, enterSends: enterSends, composing: composing, paletteOpen: !matches.isEmpty) {
        case .send:
            if canSend { send() }
            return true
        case .complete: return complete()
        case .newline, .passthrough: return false
        }
    }

    /// Arrow keys drive the palette when it is open, otherwise the input history.
    private func arrow(_ delta: Int) -> Bool {
        let matches = self.matches
        if !matches.isEmpty {
            paletteIndex = min(max(paletteIndex + delta, 0), matches.count - 1)
            return true
        }
        guard let text = delta < 0 ? conv.history.up(current: conv.draft) : conv.history.down(current: conv.draft) else {
            return false
        }
        conv.draft = text
        return true
    }

    private func complete() -> Bool {
        let matches = self.matches
        guard matches.indices.contains(paletteIndex) else { return false }
        conv.draft = matches[paletteIndex].completion
        return true
    }

    private func send() {
        Task { await store.send(conv) }
    }
}

/// The composer's text view. AppKit rather than `TextEditor` because Return has to ask the
/// input method first: while pinyin (or any marked text) is being composed, Return confirms
/// the composition and must never send.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// False lets the text view do its default (insert a newline, move the caret…).
    var onReturn: (_ shift: Bool, _ option: Bool, _ composing: Bool) -> Bool
    var onArrow: (Int) -> Bool
    var onTab: () -> Bool
    var onEscape: () -> Bool
    var onPasteFiles: ([URL]) -> Void

    final class TextView: NSTextView {
        var onPasteFiles: (([URL]) -> Void)?

        // Dropped files belong to the conversation (they become attachments), not to the text.
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

        // Text views ignore pasted images and files: attach them instead.
        override func paste(_ sender: Any?) {
            let urls = Pasteboard.attachments()
            if urls.isEmpty { super.paste(sender) } else { onPasteFiles?(urls) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let composing = textView.hasMarkedText()
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                // ⌘↩ is the Send button's shortcut and never gets here.
                return parent.onReturn(flags.contains(.shift), flags.contains(.option), composing)
            case #selector(NSResponder.moveUp(_:)): return !composing && parent.onArrow(-1)
            case #selector(NSResponder.moveDown(_:)): return !composing && parent.onArrow(1)
            case #selector(NSResponder.insertTab(_:)): return !composing && parent.onTab()
            case #selector(NSResponder.cancelOperation(_:)): return !composing && parent.onEscape()
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = TextView(frame: .zero)
        view.delegate = context.coordinator
        view.onPasteFiles = onPasteFiles
        view.font = NSFont.preferredFont(forTextStyle: .body, options: [:])
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("Message")
        view.string = text
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? TextView else { return }
        view.onPasteFiles = onPasteFiles
        // Never replace the text under an input method that is composing.
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }
}
