import Foundation
import Observation
import TDLibKit
import AgentCore

/// A conversation: a chat, or one forum topic of it. `topicId == 0` is the whole chat.
struct ConvID: Hashable {
    var chatId: Int64
    var topicId: Int = 0
}

struct Topic: Identifiable, Equatable {
    let id: Int
    var name: String
    var unread: Int
}

struct Agent: Identifiable, Equatable {
    let id: Int64 // chat id
    var title: String
    var unread = 0
    var avatarPath: String?
    var botUserId: Int64?
    var supergroupId: Int64?
    var isForum = false
    var topics: [Topic] = []
    var commands: [SlashCommand] = []
    /// Set for Hermes agents: the profile name. Groups carry `group` instead.
    var hermes: String?
    var group: GroupInfo?
    var subtitle = ""   // model, or the member list of a group
    var offline = false // Hermes: the profile's gateway is not running

    var isHermes: Bool { hermes != nil || group != nil }
    /// Profiles behind this agent: itself, or the group's members.
    var members: [String] { group?.members ?? hermes.map { [$0] } ?? [] }
}

enum Activity: Equatable { case typing, streaming }

struct Attachment: Equatable {
    enum Kind: Equatable { case photo, file, voice, audio, video }
    var kind: Kind
    var fileId: Int
    var name: String
    var size: Int64
    var duration = 0
}

struct Btn: Equatable {
    enum Action: Equatable {
        case callback(Data)
        case url(String)
        case copy(String)
        case approval(profile: String, run: String, requestId: String, generation: Int, choice: String)
        case unsupported
    }
    var text: String
    var action: Action
}

struct Msg: Identifiable, Equatable {
    enum State: Equatable { case sent, pending, failed(String) }
    var id: Int64
    var chatId: Int64
    var topicId = 0
    var outgoing = false
    var sender = ""
    var date = 0
    var edited = false
    var text = "" // Markdown source
    var blocks: [MDBlock] = []
    var attachments: [Attachment] = []
    var buttons: [[Btn]] = []
    var replyTo: Int64 = 0
    var state = State.sent

    /// One-line plain preview for replies and notifications.
    var preview: String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? (attachments.first?.name ?? "") : line
    }

    mutating func setContent(_ content: MessageContent) {
        attachments = []
        var formatted: FormattedText?
        switch content {
        case .messageText(let m):
            formatted = m.text
        case .messagePhoto(let m):
            formatted = m.caption
            if let size = m.photo.sizes.max(by: { $0.width < $1.width }) {
                attachments = [Attachment(kind: .photo, fileId: size.photo.id, name: "Photo", size: size.photo.expectedSize)]
            }
        case .messageDocument(let m):
            formatted = m.caption
            attachments = [Attachment(kind: .file, fileId: m.document.document.id, name: m.document.fileName, size: m.document.document.expectedSize)]
        case .messageVoiceNote(let m):
            formatted = m.caption
            attachments = [Attachment(kind: .voice, fileId: m.voiceNote.voice.id, name: "Voice message", size: m.voiceNote.voice.expectedSize, duration: m.voiceNote.duration)]
        case .messageAudio(let m):
            formatted = m.caption
            attachments = [Attachment(kind: .audio, fileId: m.audio.audio.id, name: m.audio.fileName.isEmpty ? m.audio.title : m.audio.fileName, size: m.audio.audio.expectedSize, duration: m.audio.duration)]
        case .messageVideo(let m):
            formatted = m.caption
            attachments = [Attachment(kind: .video, fileId: m.video.video.id, name: m.video.fileName.isEmpty ? "Video" : m.video.fileName, size: m.video.video.expectedSize, duration: m.video.duration)]
        case .messageAnimation(let m):
            formatted = m.caption
            attachments = [Attachment(kind: .video, fileId: m.animation.animation.id, name: m.animation.fileName.isEmpty ? "GIF" : m.animation.fileName, size: m.animation.animation.expectedSize, duration: m.animation.duration)]
        default:
            text = "_Unsupported message type_"
        }
        if let formatted {
            text = markdown(from: formatted.text, entities: formatted.entities.compactMap(MDEntity.init))
        }
        blocks = parseBlocks(text)
    }

    mutating func setText(_ markdown: String) {
        text = markdown
        blocks = parseBlocks(markdown)
    }

    mutating func setMarkup(_ markup: ReplyMarkup?) {
        guard case .replyMarkupInlineKeyboard(let keyboard)? = markup else { buttons = []; return }
        buttons = keyboard.rows.map { row in
            row.map { button in
                let action: Btn.Action
                switch button.type {
                case .inlineKeyboardButtonTypeCallback(let c): action = .callback(c.data)
                case .inlineKeyboardButtonTypeUrl(let u): action = .url(u.url)
                case .inlineKeyboardButtonTypeLoginUrl(let u): action = .url(u.url)
                case .inlineKeyboardButtonTypeWebApp(let u): action = .url(u.url)
                case .inlineKeyboardButtonTypeCopyText(let c): action = .copy(c.text)
                default: action = .unsupported
                }
                return Btn(text: button.text, action: action)
            }
        }
    }
}

extension MDEntity {
    init?(_ e: TextEntity) {
        let kind: Kind
        switch e.type {
        case .textEntityTypeBold: kind = .bold
        case .textEntityTypeItalic: kind = .italic
        case .textEntityTypeStrikethrough: kind = .strike
        case .textEntityTypeCode: kind = .code
        case .textEntityTypePre: kind = .pre(language: "")
        case .textEntityTypePreCode(let p): kind = .pre(language: p.language)
        case .textEntityTypeTextUrl(let u): kind = .link(u.url)
        case .textEntityTypeBlockQuote: kind = .quote(collapsible: false)
        case .textEntityTypeExpandableBlockQuote: kind = .quote(collapsible: true)
        default: return nil
        }
        self.init(offset: e.offset, length: e.length, kind: kind)
    }
}

/// Everything the UI needs for one open conversation. Views observe only their own instance.
@MainActor @Observable
final class Conversation {
    let id: ConvID
    var msgs: [Msg] = []
    var drafts: [Msg] = [] // bot drafts being streamed (updatePendingMessage)
    var hasMore = true
    var loading = false
    var draft = "" // composer text
    var attachments: [URL] = []
    var replyTo: Msg?
    @ObservationIgnored var history = InputHistory()
    // Hermes only: the turn in progress (for stop/steer) and the session it belongs to.
    var run: (profile: String, id: String)?
    var busy = false

    init(id: ConvID) { self.id = id }
}
