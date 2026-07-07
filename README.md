# PR Watch

A native macOS desktop app **and** menu-bar item that watches your GitHub pull requests
and posts a desktop banner when something changes — CI finishes, a review lands, or a
branch develops a merge conflict.

Built with SwiftUI (`MenuBarExtra` + `WindowGroup`). No Xcode required — SwiftPM plus a
hand-assembled, ad-hoc-signed `.app` bundle (this machine is Command Line Tools only).

## Requirements

- **macOS 14+** on Apple Silicon.
- **Swift toolchain** — Xcode *or* just the Command Line Tools (`xcode-select --install`).
  No Xcode/`xcodebuild` needed; the build uses SwiftPM directly.
- **GitHub auth** — the [`gh` CLI](https://cli.github.com) logged in (`gh auth login`), or a
  personal access token you paste into Settings. The app never stores a token on disk (it
  reuses `gh` or keeps a pasted PAT in the macOS Keychain).

## How to start it

```sh
git clone <your-repo-url> pr-watch
cd pr-watch
./build.sh          # swift build -c release → assemble "PR Watch.app" → ad-hoc sign → open
```

`build.sh` compiles, assembles **`PR Watch.app`**, ad-hoc-signs it, and launches it. On
first launch macOS asks to allow notifications — **click Allow** (needed for clickable
banners; otherwise it falls back to a non-clickable banner).

You'll get:
- a **window** with *My PRs / Other PRs / Activity* tabs, and
- a **menu-bar item** (a ✓ checklist icon + open-PR count) with a quick dropdown.

Daily use: just double-click **`PR Watch.app`** (or `open "PR Watch.app"`). To run it at
login, toggle **Settings → Launch at login**. Re-running `./build.sh` rebuilds and relaunches.

> Always launch the assembled bundle, not `swift run` — a bare SwiftPM binary won't
> activate as a GUI app (no window / menu-bar item).

## Test

```sh
./test.sh           # Swift Testing suite (wraps `swift test` with the CLT Testing.framework path)
```

The pure notification-diff logic (`notifications(for:previous:triggers:)`) is unit-tested.

## How it works

- **Auth** — reuses your `gh` CLI login: resolves a token via `/bin/zsh -lc 'gh auth token'`
  (falling back to `/opt/homebrew/bin/gh`). Optionally paste a fine-grained **PAT** in
  Settings; it's stored only in the **macOS Keychain**, never on disk.
- **Fetch** — one GraphQL `search` query per poll pulls open PRs with their CI check
  rollup, review decision, and mergeable state. Scope is configurable (authored /
  review-requested / limited to a single `owner/repo`).
- **Poll & diff** — `PRStore` polls on a timer (default 60s), snapshots each PR's
  `(ci, review, mergeable)` state to `UserDefaults`, and notifies only on a *transition*
  that matches an enabled trigger. The first fetch after launch never notifies (no spam
  for pre-existing state).
- **Notify** — `UNUserNotifications` banners (clickable — opens the PR in your browser),
  with an `osascript` fallback if UN isn't authorized. Test button in Settings.

## Window

Three tabs (segmented control in the toolbar):

- **My PRs** — PRs you authored (`author == viewer`).
- **Other PRs** — PRs where you're a reviewer or that you explicitly watch.
- **Activity** — a persisted history of every change (CI, reviews, conflicts) with
  timestamps; click a row to open the PR. Stored as a versioned, human-readable JSON file
  at `~/Library/Application Support/PRWatch/activity.json` (`{"version": 1, "events": […]}`)
  so the format can evolve without breaking old data.

The toolbar also has a live **countdown to the next poll**, a **filter popover** (repo
limit + individually-watched PRs), and a manual refresh.

## Settings

- **Notifications**: toggle CI / review / merge-conflict triggers; "Send test notification".
- **Watch scope**: authored PRs and/or PRs awaiting your review (repo limit + watched PRs
  live in the window's filter popover).
- **Polling**: 30s / 1m / 2m / 5m.
- **GitHub token**: paste/clear a PAT (Keychain); blank = reuse `gh` login.
- **Startup**: opt-in "Launch at login" (installs a launchd LaunchAgent pointing at the
  bundle).

## Layout

```
Package.swift              executable target, macOS 14, Swift 5 language mode
Sources/PRWatch/
  PRWatchApp.swift         @main: WindowGroup + MenuBarExtra + Settings; UN click handling
  ContentView.swift        window: My/Other/Activity tabs, filter popover, status glyphs
  MenuBarView.swift        menu-bar dropdown: compact list + refresh/window/settings/quit
  SettingsView.swift       triggers, scope, poll interval, PAT, launch-at-login, test notif
  PRStore.swift            @Observable @MainActor: polling timer + diff→notify + activity
  GitHubClient.swift       token resolution + GraphQL fetch (viewer/authored/review/custom)
  NotificationRules.swift  pure transition→activity/notification logic (unit-tested)
  Activity.swift           ActivityEvent + ActivityKind (history feed model)
  Notifier.swift           UNUserNotifications (clickable) + osascript fallback
  Keychain.swift           PAT storage
  AppSettings.swift        @Observable settings persisted to UserDefaults
  LaunchAgent.swift        install/remove launchd LaunchAgent
Tests/PRWatchTests/        Swift Testing suites (rules + PR parsing)
build.sh / test.sh
```
