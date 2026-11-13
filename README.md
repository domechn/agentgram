# AgentGram

<img src="App/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="AgentGram icon">

A macOS app for talking to your [Hermes](https://hermes-agent.nousresearch.com/docs) agents.
Every Hermes profile is a bot in the sidebar; you can create, clone and delete bots, put them in
groups that talk to each other, work the Hermes kanban board, schedule recurring prompts and
browse the files your bots produce, all from forms and buttons.
The conversation view is built for agent output (Markdown, code, tables, streaming, approval
buttons). No telemetry.

The Mac never connects to the Hermes host directly. A small service on the host,
`hermes-bridge`, runs as **one** Telegram bot and AgentGram talks to it with your own Telegram
account (via [TDLib](https://github.com/tdlib/td) / [TDLibKit](https://github.com/Swiftgram/TDLibKit)).
Everything between them is encrypted with a key only you hold, so the host needs no open port,
no tunnel and no extra bots. Ordinary Telegram bots and bot groups (the v0.1 model) are still
supported as an optional second source.

Design notes, wire protocol and threat model: [docs/DESIGN.md](docs/DESIGN.md).

## Install

Download `AgentGram.dmg` from the [latest release](https://github.com/domechn/agentgram/releases/latest),
drag the app to Applications. The build is ad-hoc signed, not notarized, so macOS blocks the
first launch: run `xattr -dr com.apple.quarantine /Applications/AgentGram.app`, or try to open
it once and then allow it under System Settings → Privacy & Security → Open Anyway.
The app targets macOS 14+, but the prebuilt TDLib binary it links is built against the
macOS 15 SDK and CI can only launch-test on GitHub's current macOS image, so macOS 14 is
untested.

## Updates

From 0.3.0 on, AgentGram updates itself with [Sparkle](https://sparkle-project.org). 0.3.0 is
the first build that can, so coming from an older version you install it by hand once (as above).

- **Settings → Updates** shows the installed version and the time of the last check, has
  "Check for Updates…" (also in the app menu) and two switches: check automatically (on, once a
  day) and download and install automatically (off: you are asked first). There is one channel,
  stable.
- The app reads `appcast.xml` from the
  [latest release](https://github.com/domechn/agentgram/releases/latest), downloads
  `AgentGram-<version>.zip` from it, and installs it only if the archive carries a valid
  ed25519 signature for the public key built into the app (`SUPublicEDKey` in `App/Info.plist`).
  A release without that signature is ignored, whoever published it.
- No Apple Developer ID is involved: the build stays ad-hoc signed and not notarized. The
  updater's download is not quarantined, so the `xattr` step is needed for the first install
  only. macOS may ask once to let AgentGram "update or delete other apps" (Privacy & Security →
  App Management) and may ask for Keychain access again after an update.
- The app must run from `/Applications` (or another folder you can write to). Started from the
  disk image or from Downloads while still quarantined, macOS runs it from a read-only copy and
  it cannot replace itself.
- Updates are offered on macOS 15 and later, the system the builds are tested on.

Key custody: the private signing key exists in two places, the GitHub Actions secret
`SPARKLE_ED_PRIVATE_KEY` of this repository and a file on the maintainer's machine. It is not
in the repository, the workflow logs or the app. CI signs the archive, then verifies the
signature against the committed public key before it publishes anything.

Rotating the key: generate a new pair, replace `SUPublicEDKey`, update the secret, release.
Installed copies trust only the old key and will refuse that release, so **every user has to
install it by hand once**. (Sparkle's smooth rotation relies on a Developer ID signature, which
these builds do not have.) If the key leaks, do exactly this.

Check a published release from any machine: `python3 scripts/appcast.py verify --version 0.3.1`
downloads the feed and the archive and verifies version, length and signature.

## Telegram API credentials

AgentGram ships without an `api_id`/`api_hash`. Get your own at
<https://my.telegram.org> → *API development tools*, then either:

- paste them into the first-run screen (stored in your Keychain, service `AgentGram`), or
- set `TG_API_ID` and `TG_API_HASH` in the environment (these win over the Keychain):

  ```sh
  TG_API_ID=12345 TG_API_HASH=abcdef… /Applications/AgentGram.app/Contents/MacOS/AgentGram
  ```

Then sign in with phone number, login code and (if enabled) your two-step password. The session
lives in `~/Library/Application Support/AgentGram/tdlib`; delete that folder to start clean.

Because each build is ad-hoc signed, macOS may ask for Keychain access again after an update.

## Connect to Hermes

Once per Hermes host:

1. In Telegram, create one bot with [@BotFather](https://t.me/BotFather) (`/newbot`). Note its
   token and `@username`. This is the only bot you need, whatever the number of agents.
2. Find your numeric Telegram user id (for example from [@userinfobot](https://t.me/userinfobot)).
3. On the Hermes host, as the user that runs Hermes:

   ```sh
   git clone https://github.com/domechn/agentgram && cd agentgram/hermes-bridge
   sudo ./install.sh               # asks for the bot token and your user id, prints the shared key
   sudo ./install.sh --enable-api  # turns on the Hermes API server on 127.0.0.1 (restarts the gateway once)
   ```

   `install.sh` installs a system-level systemd unit, `agentgram-bridge` (`Restart=always`), that
   only makes outbound connections to Telegram. `--enable-api` writes `API_SERVER_ENABLED`,
   `API_SERVER_HOST=127.0.0.1` and a random `API_SERVER_KEY` to `~/.hermes/.env`; chat needs it,
   the board and bot management work without it.
4. In AgentGram: **Settings (⌘,) → Connect to Hermes**, paste the bot's `@username` and the
   shared key, press Connect. The key is stored in your Keychain.

Updating the bridge: Settings → Connect to Hermes shows `bridge X.Y.Z (latest A.B.C)`, the
host's version against the one released with your app. If the bridge was installed from a git
clone of this repository, **Update Bridge** does it from the app: the bridge runs
`git pull --ff-only` in that clone, checks that the new `bridge.py` starts, replaces its own
file and restarts under systemd (running turns are interrupted; the request is audit-logged).
In any other case, and for bridges older than 0.3.0, the app shows the command to run on the
host instead:

```sh
cd ~/agentgram && git pull --ff-only && sudo hermes-bridge/install.sh   # the key is kept
```

Run `install.sh` from 0.3.0 once this way to enable the button: it records the clone's path
and hands the installed `bridge.py` to the Hermes user, who already runs it.

Other commands: `sudo ./install.sh --show-key`, `--rotate-key`, `--uninstall`. Logs:
`journalctl -u agentgram-bridge -f`. Every write the bridge performs is appended to
`~/.hermes/agentgram-bridge/audit.log` (no message text).

Good to know:

- The bridge obeys exactly one Telegram user id and only frames sealed with the shared key.
  Anyone with both your Telegram session and the key can run agents with terminal access on
  the host: treat the key like an SSH key.
- Mute or archive the bridge bot's chat in your other Telegram apps. Its messages are silent
  and short-lived, but the chat does light up.
- The first time a profile is used, the bridge adds an `API_SERVER_KEY` line to that
  profile's `.env` (Hermes requires one per profile). Keys never leave the host.
- One Hermes gateway serves every profile, so there is no per-bot restart: "Restart Hermes
  Gateway" in Settings restarts all of them, and "Stop Running Turns" stops one bot's turns.
- Groups are relayed by the bridge, not by Hermes' RoomLink (which needs hosted room grants):
  a message goes to the members you `@mention`, or to everyone / the lead; a reply that
  `@mentions` another member is passed on, at most 4 hops per message. Members answer one
  after another and see what the others said when their turn comes.
- Clocks: requests more than 5 minutes off the host's clock are dropped.

## Use

| | |
|---|---|
| `⌘N` / `⌘⇧N` | New bot (a Hermes profile) / new group |
| `⌘T` | New chat with the selected bot (earlier chats: clock icon in the header) |
| `⌘B` / `⌘L` / `⌘J` | Kanban board / Library (every bot's files) / Schedules (Hermes cron jobs) |
| `⌘I` | Workspace panel of the selected bot or group: Board, Files, Activity |
| `⌘K` | Quick switcher |
| `⌘1`…`⌘9` | Jump to bot |
| `⌘F` | Search messages in the current chat |
| `↩` | Send; `⇧↩` or `⌥↩` is a newline. While an input method is composing (pinyin, kana…), `↩` confirms the composition and does not send. Prefer `⌘↩` to send? Settings → Composer. While a turn is running, sending steers it |
| `esc` | Close the switcher, search or workspace panel; cancel a reply |
| `@` | In a group: mention a member; `↑`/`↓`, `↩` or `⇥` to complete |
| `/` | Telegram bots: command palette |
| `↑` / `↓` | Input history, when the composer is empty |

Right-click a bot for clone, stop, delete and its workspace. Approval requests from an agent
show up as buttons under its message. Drop or paste files to send them: they are stored on
the host and their paths are given to the agent. On the board, click a card for its comments,
runs and events, and to assign, comment, block or complete it.

**Library** lists what you sent your bots, what they wrote to their workspaces and what board
tasks produced, newest first. Search by name, filter by bot and type; click a file to download
and open it, or use the row buttons (or right-click) to save it somewhere or reveal it in Finder.

**Schedules** are Hermes cron jobs. Pick a bot, a prompt and when it runs: every N minutes or
hours, daily at a time, weekly on chosen days, or a raw cron expression. Clock times are entered
in the timezone you choose (Asia/Shanghai by default) and converted to the host's; the row shows
both the plain description and the cron expression Hermes stores. From the list you can pause,
resume, run now, edit, delete and read the output of the last run. "Deliver to" is Hermes'
delivery target: `local` keeps the output on the host, `telegram` sends it to the bot's Telegram
home chat. Schedules and the one-request Library need hermes-bridge 0.2.1 on the host; see
"Updating the bridge" above.

Telegram bots: turn on **Settings → Show Telegram bots and groups**, then pin one by
`@username` or group title. Forum topics appear under their group.

## Build

Needs Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
swift test --package-path Core     # pure-logic unit tests
(cd hermes-bridge && python3 -m unittest)   # bridge tests (fake Telegram, fake Hermes)
(cd scripts && python3 -m unittest)         # appcast, signature and version-number tests
xcodegen generate                  # creates AgentGram.xcodeproj from project.yml
open AgentGram.xcodeproj           # run the AgentGram scheme
```

Command-line build, as CI does it:

```sh
xcodebuild -project AgentGram.xcodeproj -scheme AgentGram -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- build
open build/Build/Products/Release/AgentGram.app
```

The first build downloads the prebuilt TDLib binary (~300 MB).

The bridge tests can also drive a real Hermes home while Telegram stays faked:
`AG_LIVE_HERMES_HOME=… AG_LIVE_API=http://127.0.0.1:8642 python3 -m unittest test_bridge.LiveTests`.
They create and delete a throwaway profile and a kanban task, so point them at a scratch home.

CI (`.github/workflows/build.yml`): every push to `main` runs the bridge and release-script
tests on Linux. The macOS job (tests, build, ad-hoc sign, launch smoke test, DMG, update
archive, appcast) runs only for a `v*` tag or a manual dispatch, and publishes three assets on
the release for the `MARKETING_VERSION` in `project.yml`: `AgentGram.dmg` (first install),
`AgentGram-<version>.zip` (what the updater downloads) and `appcast.xml` (the feed).

To release: set `MARKETING_VERSION` in `project.yml` and `VERSION` in `hermes-bridge/bridge.py`
to the new version (a test keeps them equal), add a `## <version>` section to `CHANGELOG.md`
(it becomes the release body and the notes the updater shows), push, then push the tag
`v<version>`. The build number is derived from the version (0.3.1 → 301), so it always grows.

The app icon is drawn in `App/Icon/AppIcon.svg`. After editing it, run `App/Icon/render.sh`
(needs `rsvg-convert`) and commit the regenerated PNGs in `App/Assets.xcassets`; CI only
consumes the committed PNGs.
