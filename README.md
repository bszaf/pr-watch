# PR Watch

A native macOS desktop app **and** menu-bar item that watches your **GitHub** pull requests
**and GitLab** merge requests — concurrently, merged into one view — posts a desktop banner
when something changes (CI finishes, a review lands, a branch develops a merge conflict), and
links each PR to its **local git worktree** so you can jump straight into a terminal.

Built with SwiftUI (`MenuBarExtra` + `WindowGroup`). No Xcode required — SwiftPM plus a
hand-assembled, ad-hoc-signed `.app` bundle (this machine is Command Line Tools only).

## Requirements

- **macOS 14+** on Apple Silicon.
- **Swift toolchain** — Xcode *or* just the Command Line Tools (`xcode-select --install`).
  No Xcode/`xcodebuild` needed; the build uses SwiftPM directly.
- **Provider auth** (at least one):
  - **GitHub** — the [`gh` CLI](https://cli.github.com) logged in (`gh auth login`), or a PAT.
  - **GitLab** — the [`glab` CLI](https://gitlab.com/gitlab-org/cli), or a PAT with `read_api`
    scope pasted in Settings (gitlab.com or a self-managed host).
  The app never stores a token on disk — it reuses `gh`/`glab`, or keeps a pasted PAT in the
  macOS Keychain (per provider).

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
- a **window** with *My PRs / Other PRs / Activity / Projects* tabs, and
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

- **Providers** — GitHub and GitLab are fetched **concurrently** each poll and merged into
  one list. Each is independently toggleable; per-provider token resolution is
  **Keychain PAT → CLI (`gh`/`glab`) → env var**. A provider with no credentials is simply
  "not configured" (no error), and one provider failing never blanks the other's results.
- **Fetch** —
  - *GitHub*: one GraphQL `search` query for authored / review-requested PRs (+ any
    individually-watched PRs), with CI check rollup, review decision, and mergeable state.
  - *GitLab*: GraphQL `currentUser.authoredMergeRequests` / `reviewRequestedMergeRequests`,
    mapping pipeline status → CI, `conflicts` → merge conflict, `approved` → review. Refs
    render as `!123` (GitLab) vs `#123` (GitHub).
- **Poll & diff** — `PRStore` polls on an **adaptive timer**, snapshots each PR's
  `(ci, review, mergeable)` state, and notifies only on a *transition* that matches an
  enabled trigger. The first fetch after launch never notifies (no spam for pre-existing
  state). `mergeable == UNKNOWN` (which GitHub computes asynchronously and flaps into) is
  treated as "no new info", so a `CONFLICTING→UNKNOWN→CONFLICTING` flap won't re-notify.
- **Adaptive polling** — polls every **15s while something is in flight** (a CI run is
  pending, or a change was seen in the last 2 min) and relaxes to your **configured idle
  interval** otherwise. GitHub GraphQL costs ~1–5 of 5,000 points/hour, so even the 15s
  tier is a small fraction of the budget. (GraphQL can't use HTTP ETag conditional
  requests, and the ETag-capable REST feeds don't report CI, so adaptive cadence — not
  ETag — is the effective lever here.)
- **Notify** — `UNUserNotifications` banners (clickable — opens the PR in your browser),
  with an `osascript` fallback if UN isn't authorized. Approval/changes banners name the
  reviewer (e.g. *"👍 Approved by @alice — alto #123"*). Test button in Settings.

## Window

Tabs (segmented control in the titlebar):

- **My PRs** — PRs/MRs you authored (matched against each provider's own viewer).
- **Other PRs** — ones where you're a reviewer or that you explicitly watch.
- **Activity** — a persisted history of every change (CI, reviews, conflicts) with
  timestamps; click a row to open the PR. Stored as a versioned, human-readable JSON file
  at `~/Library/Application Support/PRWatch/activity.json` (`{"version": 1, "events": […]}`)
  so the format can evolve without breaking old data.
- **Projects** — local git projects/worktrees found under your configurable scan folders
  (Settings → Projects), each showing branch + origin repo, opened in your terminal.

**Expandable PR rows** — click a PR to reveal details: reviewers (approved / changes /
**pending**), metadata (base branch, +/−, labels, updated, comments), and the matched local
worktree with Terminal/Finder actions.

**PR ↔ project correlation** — matched on `owner/repo` + head branch. A PR with a local
worktree shows a terminal chip (opens the worktree); a Projects row shows a chip back to its
open PR.

A bottom **status bar** shows the live poll countdown + refresh; the titlebar also holds the
**Watched PRs** popover (individually-watched PRs) and **Settings**.

## Settings

Native tabbed preferences:

- **General** — **idle** poll interval (30s / 1m / 2m / 5m; polls at 15s while CI is running —
  see Adaptive polling) and opt-in "Launch at login" (installs a launchd LaunchAgent).
- **Sources** — enable/disable **GitHub** and **GitLab**, each showing its active source
  (e.g. `Using: gh — user:bszaf` or `Using: gitlab — no CLI`), a Keychain PAT field, and (for
  GitLab) the host URL; **watch scope** (authored and/or review-requested); and
  **Repositories** — a list limiting which repos to watch (empty = all), with suggestions
  drawn from local projects and open PRs.
- **Projects** — folders to scan for local git projects, and which **terminal** to open a
  project in (iTerm2 new tab / Terminal / custom `{path}` command).
- **Notifications** — CI / review / merge-conflict trigger toggles, a shortcut to choose
  persistent **Alerts** in macOS Notification settings, and "Send test notification".

Individually-watched PRs live in the main window's **Watched PRs** popover.

## Layout

```
Package.swift              executable target, macOS 14, Swift 5 language mode
Sources/PRWatch/
  PRWatchApp.swift         @main: WindowGroup + MenuBarExtra + Settings; UN click handling
  ContentView.swift        window: titlebar tabs, expandable PR rows, Projects, status footer
  MenuBarView.swift        menu-bar dropdown: compact list + refresh/window/settings/quit
  SettingsView.swift       tabbed prefs: General / Sources / Projects / Notifications
  PRStore.swift            @Observable @MainActor: concurrent multi-provider fetch + diff→notify
  Provider.swift           Provider enum, token source, per-provider status model
  GitHubClient.swift       GitHub token resolution + GraphQL (viewer/authored/review/custom)
  GitLabClient.swift       GitLab token resolution + GraphQL (currentUser MRs) → shared model
  LocalProjects.swift      local git-project scanner + store (Projects tab, PR correlation)
  TerminalLauncher.swift   open a project in iTerm2 / Terminal / a custom command
  NotificationRules.swift  pure transition→activity/notification logic (unit-tested)
  Activity.swift           ActivityEvent + ActivityKind + versioned file store
  Notifier.swift           UNUserNotifications (clickable) + osascript fallback
  Keychain.swift           per-provider PAT storage
  AppSettings.swift        @Observable settings persisted to UserDefaults
  LaunchAgent.swift        install/remove launchd LaunchAgent
Tests/PRWatchTests/        Swift Testing suites (rules + mergeable dedupe + PR parsing)
build.sh / test.sh
```
