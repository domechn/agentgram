# AgentGram — design

A macOS 14+ SwiftUI client for one person talking to many agents. Since v0.2 an agent is a
**Hermes profile**, reached through one Telegram "bridge bot"; plain Telegram bots and bot groups
(the v0.1 model) remain as an optional secondary source. It is not a general chat client: there
is no chat list, contacts, calls or stickers.

Sections "Hermes (v0.2)" below describe the Hermes side; the rest describes the Telegram client
underneath, which v0.2 keeps and reuses as the transport.

## Layout

```
Core/                    SwiftPM package: AgentCore (pure logic) + its tests
Core/Sources/AgentCore/     Markdown, slash commands, input history, timeline/stream merge
Core/Tests/AgentCoreTests/  unit tests (run on Linux and macOS)
App/Store/               TDLib layer + app state. Foundation/Observation/TDLibKit only
App/Views/               SwiftUI views
App/Platform.swift       Keychain, notifications, pasteboard (AppKit-only bits)
App/AgentGramApp.swift   scenes, menu commands, menu-bar extra
project.yml              XcodeGen spec (no hand-written pbxproj)
```

`AgentCore` has no dependencies, so its tests run anywhere (`swift test --package-path Core`). `App/Store` avoids
AppKit/SwiftUI on purpose: it can be type-checked on Linux against the TDLibKit sources with a
stubbed `TDLibFramework` module, which is how the TDLib calls were checked before going to CI.

## TDLib binding

[TDLibKit](https://github.com/Swiftgram/TDLibKit) pinned to `1.5.2-tdlib-1.8.70-23383aef`
(prebuilt `tdjson` via TDLibFramework, generated Swift types, async/await API).

## TDLib wrapper and threading

```
td_receive loop (TDLibKit queue)
   └─ per-client serial queue: JSON → Update (decoded off the main thread)
        └─ AsyncStream<Update>  (unbounded, ordered)
             └─ AppStore (@MainActor) `for await update in tg.updates { handle(update) }`
```

- `TG` (`App/Store/TG.swift`) owns the single `TDLibClientManager` and the current `TDLibClient`.
  Its only jobs are decoding updates into the stream and recreating the client after TDLib reports
  `authorizationStateClosed` (log out, or API credentials reset).
- Requests are TDLibKit's `async` methods, called from the store. TDLibKit's client is already
  thread-safe (its own send/receive queues), so no extra actor is wrapped around it; the isolation
  boundary is the `@MainActor` store, which is the only writer of app state.
- Update order is preserved end to end (serial queue → stream → main actor), which the streaming
  edit path depends on.

## State

`AppStore` (`@MainActor @Observable`) is the single source of truth:

- `auth`: `loading | needCredentials | phone | code | password | ready | unsupported`, driven only
  by `updateAuthorizationState`.
- `agents: [Agent]`: the pinned chats, in pin order. An agent is a bot chat or a group; it carries
  title, avatar path, unread count, forum topics and slash commands. Pinned chat ids are stored in
  `UserDefaults`.
- `selection: ConvID?` where `ConvID = (chatId, topicId)`; `topicId == 0` means the whole chat.
- `activity: [ConvID: typing | streaming]` for the sidebar/header status.
- `files: [fileId: localPath]` for downloaded attachments and avatars.
- `Conversation` (`@Observable` class, one per opened `ConvID`): messages, streaming drafts,
  composer draft text, pending attachments, reply target, input history. Views observe only their
  own conversation, so an edit in one agent does not invalidate another.

TDLib models are immutable and large, so messages are mapped once into a small value type `Msg`
(markdown source, parsed blocks, attachments, buttons, send state).

## Message pipeline

1. `FormattedText` (text + entities, UTF-16 offsets) → Markdown source
   (`AgentCore.markdown(from:entities:)`). Text the bot sent as raw Markdown passes through
   untouched, so both formatted and unformatted agent output end up as one Markdown string.
2. Markdown → `[MDBlock]` (`parseBlocks`): paragraph, heading, fenced code, quote
   (optionally collapsible), table, rule. An unclosed fence is a code block to the end of the
   text, which is what a half-streamed message looks like.
3. `MarkdownView` renders blocks. Inline styling uses `AttributedString(markdown:)`.

### Streaming without flicker

Bots stream by editing a message (`updateMessageContent`) or by draft updates
(`updatePendingMessage`). Each edit replaces the `Msg` value in place; nothing is animated.
`MessageView` is `Equatable`, so untouched rows are skipped, and blocks are identified by
position, so during a stream only the last block's text changes and the views (and their expanded
/collapsed state) above it are reused. The scroll view is bottom-anchored, so it follows the
stream only while the user is at the bottom. `StreamTracker` marks a conversation as "streaming"
until 3 s after its last edit.

## Features → TDLib calls

| Feature | Calls / updates |
|---|---|
| Login | `setTdlibParameters`, `setAuthenticationPhoneNumber`, `checkAuthenticationCode`, `checkAuthenticationPassword`, `logOut` |
| Pin agent | `searchPublicChat` (@username), `searchChats`/`searchChatsOnServer` (title, for private groups) |
| Topics | `getForumTopics`, `getForumTopicHistory`; refreshed on `updateForumTopic*` and new messages |
| History | `getChatHistory` |
| Send | `sendMessage` with text / photo / document, `replyTo`, `topicId` |
| Approvals | `getCallbackQueryAnswer` for inline-keyboard callbacks; URL and copy-text buttons handled locally |
| Slash commands | `getUserFullInfo().botInfo.commands`; for supergroups, the commands of every bot member |
| Search | `searchChatMessages` |
| Files | `downloadFile` (photos auto, documents/voice on click) |
| Read state | `openChat`/`closeChat`, `viewMessages`, `updateChatReadInbox` |

## Hermes (v0.2)

### Why this shape

- BotFather limits how many bots one account can own, so "one Telegram bot per agent" does not
  scale. An agent is a Hermes profile; profiles are unlimited.
- The Mac is remote from the Hermes host and nothing on the host may listen on a reachable port.
  So the transport is Telegram itself: the host runs `hermes-bridge`, **one** bot that long-polls
  Telegram (outbound only) and multiplexes every profile. AgentGram talks to that bot with the
  user's own account through TDLib, which it already has.

```
AgentGram (TDLib, your account) ⇄ Telegram ⇄ hermes-bridge (one bot, long polling)
                                                 ├─ Hermes API server, 127.0.0.1:8642, /p/<profile>/v1/runs …
                                                 ├─ `hermes profile …`, `hermes kanban … --json`
                                                 └─ bridge state: groups, transcripts, audit log
```

### Hermes facts this relies on (read from the installed source, v0.22.4, and verified live)

- One gateway process per host serves every profile (`gateway.multiplex_profiles`, no opt-out).
  A profile created with `hermes profile create` is served immediately, no restart.
- The API server platform (`gateway/platforms/api_server*.py`) is off by default. It needs
  `API_SERVER_ENABLED=true` and an `API_SERVER_KEY` (≥16 chars) in `~/.hermes/.env` and one gateway
  restart; it binds `127.0.0.1:8642`. Named profiles are served under `/p/<profile>/…` and each
  needs **its own** `API_SERVER_KEY` in `profiles/<name>/.env` (fail closed; read live).
- Chat: `POST /v1/runs {input}` with header `X-Hermes-Session-Key` (names the conversation) →
  `202 {run_id}`; `GET /v1/runs/{id}/events` is SSE with `message.delta {delta}`,
  `tool.started {tool, preview}`, `tool.completed {tool, duration, error}`,
  `approval.request {prompt_id, execution_generation, command, description, choices}`,
  `run.completed|run.failed {output, usage}`. `GET /v1/runs/{id}` gives `session_id`.
  `POST …/approval {request_id, execution_generation, choice}`, `…/stop`, `…/steer {text}`.
  History: `GET /api/sessions`, `GET /api/sessions/{id}/messages`.
- Kanban: `hermes kanban [--board b] list|show|boards list|assignees --json`, and
  `create|assign|comment|complete|block|unblock`.
- Rooms: the RoomLink code (`api_server_room_grants.py`, `api_server_room_dispatch.py`,
  `/v1/room-members/*`) authenticates with signed `HermesRoom` grants minted by a hosted room peer
  (Desktop / relay). A local bridge cannot mint them, so **groups are implemented in the bridge**
  (below), not with RoomLink.

### Wire protocol (v1)

Every Telegram message between the app and the bridge bot is one sealed frame:

```
text message : "AG1." + base64url(nonce[12] ‖ ChaCha20-Poly1305(key, nonce, json, aad="AG1"))
document     : file "ag1.bin" with the same bytes raw, when the text form would exceed 4096 chars
```

- `key` is 32 random bytes, generated by `install.sh` on the host and pasted once into the app
  (Keychain). It is **mandatory**, not optional: one code path, and a stolen Telegram session
  alone can neither read the traffic nor run commands. AEAD covers both the "HMAC" and the
  "encryption" asks of the brief.
- Request `{v:1, id, ts, op, args}`. The bridge drops frames from any sender other than the one
  allow-listed user id, frames that do not decrypt, `ts` more than 5 minutes off or older than
  the bridge process (the seen-id set is in memory), and ids it has already seen (replay).
- Reply `{v:1, re:id, ok, data | error}`. Streaming ops first send **one** message that is
  edited in place at most once a second: `{re, stream:{seq, off, text, tools, approval, run,
  who, n}}`, where `text` is the output from character offset `off` and `n` numbers the turns of
  one request (a group message produces one per speaker). When a segment would outgrow a
  Telegram message it is frozen and a new one starts at the new offset, so every segment is
  self-contained and a missed edit loses nothing. The final reply carries the full output.
- Files travel as Telegram documents: upload is a document whose caption is a `file.put` frame;
  `files.get` answers with the document.
- Housekeeping: the bridge deletes each request once handled and sweeps its own messages after
  10 minutes; the app deletes replies once read. The bridge chat is never shown in the UI.

Ops: `hello`, `profiles.list`, `profile.create|delete|clone`, `profile.stop` (stops that
profile's live runs), `gateway.restart`, `models.list`, `toolsets.list`, `chat.send` (stream),
`run.stop`, `run.steer`, `approval.respond`, `sessions.list`, `session.messages`,
`kanban.boards|list|show|create|assign|comment|complete|block|unblock`, `groups.list|save|delete`,
`group.send` (stream), `group.history`, `file.put`, `files.list`, `files.get`, `activity`.
Live refresh is polling (profiles every 60 s, the board every 15 s while visible); there is no
push channel, so there is no `status.watch`. Bot messages are sent with `disable_notification`.

### Bridge (`hermes-bridge/bridge.py`)

Single file, Python 3 stdlib plus `cryptography`. One thread long-polls `getUpdates`; each
request runs on a worker thread. Reads go to the CLI/API as above. Writes (`profile.*`,
`kanban.*` mutations, `gateway.restart`, `groups.*`, approvals) are appended to
`~/.hermes/agentgram-bridge/audit.log` with op, arguments (no secrets, no message text) and
result. Profile names are validated (`[a-z0-9][a-z0-9-]*`), `default` cannot be deleted, file
paths must resolve inside the profile's directory. When a profile is first used the bridge
generates its `API_SERVER_KEY` into the profile's `.env` (0600); keys never leave the host.

Bots: "create" is `hermes profile create <name> --clone-from <src> --no-alias`, then SOUL.md,
`config set model.default`, description, optional `terminal.cwd` and toolsets. Because one
gateway serves every profile there is no per-bot process: "restart" restarts the whole gateway
(the UI says so and confirms), and "stop" stops the bot's running turns.

Groups: a group is `{id, name, members[], mode}` stored by the bridge with its transcript.
`group.send` routes a user message to the members it `@mentions`; with no mention it goes to all
members (`mode: all`) or to the first one (`mode: lead`). Each member has its own Hermes session
(`agentgram:group:<id>:<profile>`) and receives, before the new message, the transcript lines it
has not seen yet, so members see each other. If a reply `@mentions` another member the bridge
relays it, up to 4 hops per user message and never back to the speaker. Limits: turns run one
after another, not in parallel; members only "hear" the others when next addressed.

### App

- `AgentCore/Bridge.swift` (pure, unit-tested): frame sealing, envelope types, stream-segment
  assembly, kanban column grouping, `@mention` completion, avatar colours.
- `App/Store/Hermes.swift`: extension of `AppStore`. Resolves the bridge bot, sends frames with
  `sendMessage`, matches replies by request id from `updateNewMessage` /
  `updateMessageContent`, deletes them. Hermes profiles and groups are ordinary `Agent` values
  (ids in a range Telegram never uses), so selection, the conversation view, the composer, the
  quick switcher and ⌘1…9 work unchanged; `send`, `loadMore` and button presses branch on
  `agent.hermes`.
- UI (after the reference screenshot): narrow sidebar (New chat pill, Board, Library, flat Bots
  list of agents and groups with generated avatars, unread dot, Show more/less), floating pill
  header, "Say hello to <name>." empty state, composer at the bottom, toggleable right
  "<name>'s workspace" panel with Board / Files / Activity. Bots and groups are managed in
  sheets (forms), never by chatting. Telegram bots appear in the same list when the "Telegram
  source" toggle in Settings is on.

### Not done / limits

- Per-bot start/stop/restart does not exist in Hermes' one-gateway model (see above).
- Board cards show title, assignee and id; dependencies are in the task detail (the list
  output of `hermes kanban` does not carry links).
- "Library" and the Files tab list the bot's `workspace/` directory and the files you sent it;
  files an agent writes elsewhere on the host are not listed.
- Large payloads are sent as one document instead of being chunked across messages.
- The direct URL / SSH connectors and Telegram supergroup creation from the earlier revisions
  of the brief were dropped in favour of the single bridge transport.

### Threat model

- Telegram (and anyone holding the bot token or your Telegram session) sees frame sizes and
  timing but not content, and cannot forge or replay requests without the shared key.
- Whoever has the key **and** can send as your Telegram user can run agents with terminal
  access on the host. Guard the key like an SSH key; rotate with `install.sh --rotate-key`.
- The bridge runs as the Hermes user; it adds no network listener. The Hermes API server it
  talks to stays on loopback behind its own keys.
- Not protected: metadata, a compromised host or Mac, and files the agents themselves send to
  third parties.

## Credentials and data

- `api_id`/`api_hash`: env `TG_API_ID`/`TG_API_HASH` win; otherwise Keychain (service
  `AgentGram`), filled in by the first-run screen. Never in the repo or the binary.
- TDLib database and files: `~/Library/Application Support/AgentGram/tdlib`.
- Bridge bot `@username` in `UserDefaults`, the shared key in the Keychain (`bridge_key`).
- No telemetry, no network calls other than TDLib's.

## Keyboard

`⌘K` quick switcher, `⌘1…9` agents, `⌘B` board, `⌘N` new bot, `⌘⇧N` new group, `⌘F` search in agent, `⌘↩` send,
`↑/↓` input history (when the composer is empty or showing a history entry), `/` command palette
(`↑/↓` to move, `↩`/`⇥` to complete), `esc` closes the switcher / search / reply.

## CI

GitHub Actions on `macos-latest`: `swift test` → `xcodegen` → `xcodebuild` (Release, ad-hoc
signed) → `hdiutil` DMG → artifact + the release for the current `MARKETING_VERSION`.
A second job runs the bridge's Python tests on Linux.

## Known shortcuts

- Voice notes (Ogg/Opus) open in the default player instead of playing inline.
- Outgoing text is sent as plain text (bots parse it themselves).
- Slash commands are not collected for basic (non-super) groups.
- Search shows matching messages; it does not jump into the surrounding history.
