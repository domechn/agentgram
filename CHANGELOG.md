# Changelog

The section of a version is the body of its GitHub release and the release notes the in-app
updater shows.

## 0.3.0

- AgentGram updates itself: Settings → Updates, or "Check for Updates…" in the app menu. Checks
  run daily; downloads are verified against a signing key built into the app. This is the first
  build with the updater, so it has to be installed by hand once more.
- Settings → Connect to Hermes shows the bridge version on the host and, when the bridge was
  installed from a git checkout, updates it with one click. Otherwise it shows the command to run.
- The "host too old" banner now gives the exact update command.
