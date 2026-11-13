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
scripts/appcast.py       release tooling: build number, update signature, appcast.xml
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
`group.send` (stream), `group.history`, `file.put`, `files.list`, `files.get`, `activity`,
`jobs.list|create|update|delete|pause|resume|run|output`, `bridge.update`.
Live refresh is polling (profiles every 60 s, the board every 15 s and schedules every 30 s
while visible); there is no push channel, so there is no `status.watch`. Bot messages are sent
with `disable_notification`. `hello` reports the bridge version and, from 0.3.0, the git
checkout it was installed from (`source`) and whether it can update itself (`updatable`); an
app that needs a newer bridge says so in a banner, with the command to run, instead of failing
on unknown ops.

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

Schedules (bridge 0.2.1): each profile has its own cron store, served by the Hermes API at
`/p/<profile>/api/jobs` (GET, POST, PATCH, DELETE, and POST `…/pause|resume|run`). `jobs.list`
asks every profile that has a `cron/jobs.json` and returns the jobs trimmed to what the app
shows (no origin chat ids), plus per profile the UTC offset of the zone Hermes evaluates cron
expressions in (`timezone:` in its config, else the server's). `jobs.output` returns the
response part of the newest file in `cron/output/<job>/`. Job writes are audited like the others.

Library (bridge 0.2.1): `files.list` without a profile returns every profile's inbox and
workspace files plus the kanban workspaces in one reply (newest 500), each tagged with its
owner and source. v0.2.0 asked once per profile, in sequence, and drew nothing but a spinner
until the last answer: with a dozen profiles the Library looked like it never opened.

Self-update (bridge 0.3.0, `bridge.update`): Settings shows `bridge X.Y.Z (latest A.B.C)`,
where "latest" is the app's own version (app and bridge are released together; a test keeps
the two version strings equal). The op runs only when all of this holds, otherwise the app
shows the manual command: `install.sh` ran from a git checkout (it writes `AG_SOURCE` to the
env file), the checkout's `origin` is this repository over HTTPS, and the bridge's user owns
the installed file. Then: `git pull --ff-only` in the checkout, copy its `bridge.py` next to
the installed one, run the copy with `--version` (a file that does not start is discarded and
the running bridge stays), rename it over the installed file, answer, exit; systemd
(`Restart=always`) starts the new code. The request left in Telegram is older than the new
process and is dropped by the replay check. There is one principal, the allow-listed user, so
"admin only" is the same sealed-frame check as every op; the op is in the audit log.
It trusts what the manual path trusts (GitHub over TLS, the `main` branch) and runs as the
Hermes user rather than root. The installed file becomes writable by that user, which gives
nothing away: agents and the bridge already share that user, and with it the bridge's key.

### App

- `AgentCore/Schedule.swift` (pure, unit-tested): job envelopes, the schedule builder (form
  value ⇄ the string Hermes takes, with the clock moved between the user's zone and the
  host's), Library filtering, and `returnAction`, the rule for what Return does in the composer.
- Composer: an `NSTextView` behind `NSViewRepresentable`, because Return must ask the input
  method first. `textView(_:doCommandBy:)` reads `hasMarkedText()`; while a composition is open
  Return, arrows, Tab and Esc all stay with the input method. Otherwise ⇧/⌥ Return is a
  newline, an open palette takes Return as "complete", and plain Return sends (or is a newline
  with "⌘↩ sends" chosen in Settings). ⌘↩ always sends.
- Timeline: a one-point sentinel at the end of the list tells whether the user is at the
  bottom; the scroll view follows new output only then, and a "Jump to latest" pill appears
  otherwise.
- Connection trouble is a banner above the content with the way out (Retry for a bridge that
  stopped answering, the update command for an old bridge). Lists load behind skeleton rows and
  keep their last contents in the store, so Library and Schedules reopen instantly.
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
- Library and the Files tab list the bots' `workspace/` directories, the files you sent them
  and the kanban workspaces; files an agent writes elsewhere on the host are not listed.
- Schedules: the builder's timezone conversion uses today's UTC offsets, so a zone with
  daylight saving drifts by an hour at the switch until the job is saved again (Asia/Shanghai
  and UTC have none). One-shot jobs are shown and can be paused or deleted, but new ones are
  recurring only.
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
- Updates: whoever can publish a release in this repository can change the feed, but not make
  an installed app accept an archive: that takes the private update key. Whoever holds that
  key and can publish (or tamper with the download) can run code as the user on every Mac
  that updates. The bridge's self-update pulls unsigned code from this repository's `main`,
  exactly as the manual update does.

## Updates (v0.3)

The app updates itself with [Sparkle 2](https://sparkle-project.org) (SwiftPM, pinned to
2.10.1), from the GitHub releases of this repository. There is no Developer ID: builds are
ad-hoc signed and not notarized, and the design rests on Sparkle's EdDSA signatures instead.

What was read in Sparkle's source (2.10.1) to decide this works without a certificate:

- `SUUpdateValidator`: an update is accepted when the archive's ed25519 signature verifies
  against the **installed** app's `SUPublicEDKey` and, if the new app is code signed, that
  signature is valid. A matching Developer ID is only the alternative to a valid EdDSA
  signature (it is what key rotation falls back on). "If no Apple Code Signing certificate is
  available, adhoc signing can be used at minimum."
- `SUCodeSigningVerifier.validateConnection`: the app and the `Autoupdate` helper only pin each
  other's team ID when they have one. Sparkle's binaries ship with Sparkle's own signature, so
  an ad-hoc app must re-sign them ad hoc or the installer connection is refused. CI therefore
  signs inside out (`Installer.xpc`, `Downloader.xpc`, `Autoupdate`, `Updater.app`, each
  framework, the app; `--deep` only for verifying) and asserts every piece is ad-hoc signed.
- `SUPlainInstaller`: the installer removes the quarantine attribute from the new app before
  it is moved into place, so Gatekeeper does not block the relaunch.
- The app is not sandboxed, so Sparkle's XPC services are not used and need no entitlements.

Pieces:

- `App/Info.plist`: `SUFeedURL` (`…/releases/latest/download/appcast.xml`, no separate feed
  host), `SUPublicEDKey`, `SUEnableAutomaticChecks`, daily `SUScheduledCheckInterval`. Xcode
  merges it with the generated Info.plist.
- `App/Platform.swift` `Updater`: one `SPUStandardUpdaterController`, started at launch.
  Settings → Updates and the "Check for Updates…" menu item drive it; the update prompt,
  release notes and progress are Sparkle's standard windows.
- `scripts/appcast.py` (stdlib + `cryptography`, unit-tested): the build number
  (`0.3.1 → 301`; Sparkle compares `CFBundleVersion`, so it must grow), the release notes
  (the version's section of `CHANGELOG.md`), the signature (plain ed25519 over the archive
  bytes, base64: what Sparkle's `sign_update` produces), `appcast.xml` (one item: version,
  short version, `minimumSystemVersion` 15.0, length, `edSignature`, notes as Markdown), and
  `verify`, which checks a feed and its archive against the committed public key.
- The key pair was generated with Python `cryptography` in Sparkle's format (base64 of the
  32-byte seed; base64 of the raw public key). The private half is the Actions secret
  `SPARKLE_ED_PRIVATE_KEY` plus one file on the maintainer's machine, nowhere else.

Limits: the in-app update itself (prompt, download, install, relaunch) cannot be exercised in
CI or on Linux; what is tested is every input to it. macOS 13+ may ask the user to allow
AgentGram under App Management the first time it replaces itself. A translocated app (run
from the disk image, or still quarantined) cannot update. Rotating the key needs a manual
reinstall by every user: without a Developer ID there is no second trust anchor.

## Credentials and data

- `api_id`/`api_hash`: env `TG_API_ID`/`TG_API_HASH` win; otherwise Keychain (service
  `AgentGram`), filled in by the first-run screen. Never in the repo or the binary.
- TDLib database and files: `~/Library/Application Support/AgentGram/tdlib`.
- Bridge bot `@username` in `UserDefaults`, the shared key in the Keychain (`bridge_key`).
- No telemetry. Network calls: TDLib's, and Sparkle fetching the appcast and update archive
  from GitHub (no system profile is sent).

## Keyboard

`⌘K` quick switcher, `⌘1…9` agents, `⌘B` board, `⌘L` library, `⌘J` schedules, `⌘N` new bot,
`⌘⇧N` new group, `⌘F` search in agent, `↩` send (`⇧↩`/`⌥↩` newline; never while an input method
is composing; `⌘↩` always sends), `↑/↓` input history (when the composer is empty or showing a
history entry), `/` command palette (`↑/↓` to move, `↩`/`⇥` to complete), `esc` closes the
switcher / search / workspace panel / reply.

## CI

Every push runs the bridge's Python tests on Linux. The macOS job runs only for a `v*` tag or
a manual dispatch (macOS minutes bill 10x on private repos): `swift test` → `xcodegen` →
`xcodebuild` (Release, ad-hoc signed, SwiftPM checkout cached) → inside-out ad-hoc signing →
launch smoke test → `hdiutil` DMG and `ditto` zip (unpacked again and verified) → signed
`appcast.xml`, cross-checked with Sparkle's own `sign_update --verify` → the release for the
`MARKETING_VERSION` in `project.yml`, which a pushed tag must match. The signing key and the
release notes are checked in the first minute, before the long build.

## Known shortcuts

- Voice notes (Ogg/Opus) open in the default player instead of playing inline.
- Outgoing text is sent as plain text (bots parse it themselves).
- Slash commands are not collected for basic (non-super) groups.
- Search shows matching messages; it does not jump into the surrounding history.
