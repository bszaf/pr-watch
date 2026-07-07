# PR Watch — build plan

A native **macOS desktop application that also lives in the menu bar**, which watches the
signed-in user's GitHub pull requests and sends desktop notifications when something
changes (CI finished, review activity, merge conflicts, etc.).

This document is the full brief for a fresh Claude Code instance. It has no prior
conversation context — everything needed is captured here.

---

## 1. Goal (what the user asked for)

- A **normal desktop app** (a real window you can open) that **also lives in the macOS
  menu bar** (status-bar item with a dropdown).
- You "log into GitHub" and it **actively observes your PRs** and notifies you.
- Original motivating use case: get a native macOS banner when a PR's **CI finishes**
  (pass/fail), instead of manually polling `gh pr checks`.

## 2. Decisions already made

| Topic | Decision |
|---|---|
| Form factor | Native desktop app **with a main window AND a menu-bar item** (not just a menubar-only app, not a web app). |
| Platform | macOS. Build **native Swift / SwiftUI**. |
| Notifications | Start with `osascript` banners (proven to work on this machine); upgrade to `UNUserNotifications` if bundle/signing allows. |
| Auth (v1) | **Reuse the existing `gh` CLI login** (user is already authenticated). Add a Settings screen later where a fine-grained **PAT** can be pasted and stored in the **macOS Keychain**. |

## 3. Environment (verified on this machine — 2026-07-07)

- macOS **26.5.1** (build 25F80), Apple Silicon (arm64).
- **Swift 6.2.3**, but **Command Line Tools only — NO full Xcode** (`xcodebuild` absent,
  `xcode-select -p` = `/Library/Developer/CommandLineTools`).
  - ⇒ Build with **SwiftPM (`swift build`)**, not Xcode projects.
  - ⇒ SwiftPM produces a bare binary; **hand-assemble a `.app` bundle**
    (`Contents/MacOS/<bin>` + `Contents/Info.plist`) and **ad-hoc codesign** (`codesign -s -`)
    so it can post notifications and show a Dock icon + menu-bar item.
  - `MenuBarExtra` requires macOS 13+ — fine here.
  - Use **Swift 5 language mode** in `Package.swift` (`swiftLanguageModes: [.v5]`) to avoid
    Swift 6 strict-concurrency compile friction.
- **Node v24.6** is available (Electron/Tauri is a fallback option, but native Swift is the
  chosen path and is lighter/more "native").
- `gh` CLI is **authenticated** as user **`bszaf`** (token in keyring). `gh auth token`
  returns a valid `gho_…` token.
  - ⚠️ When launched as a bundled `.app` (via `open` or launchd), `PATH` may not include
    `gh`. Resolve the token robustly by running a **login shell**:
    `/bin/zsh -lc 'gh auth token'` (sources the user profile so `gh` is on `PATH`), or probe
    `/opt/homebrew/bin/gh`, `/usr/local/bin/gh`. (The `which gh` path was not captured before
    this plan was written — the next instance should re-check: `which gh`.)
- `terminal-notifier` is **not installed** (so don't depend on it; use `osascript` or
  `UNUserNotifications`).

## 4. Open questions to confirm with the user before/while building

1. **Notification triggers** (multi-select): CI/checks finished (pass/fail) ✅ core;
   review activity (approved / changes requested / you added as reviewer); new
   comments / @-mentions; merge conflicts / branch fell behind base.
2. **Which PRs to watch**: PRs I authored (default) / also PRs where I'm a requested
   reviewer / limit to `RiverFinancial/alto` only.
3. **Auth**: is reusing `gh` login acceptable for v1, or is a real "Log in with GitHub"
   button wanted (that needs a registered OAuth app + redirect handling — heavier)?
4. **Native notifications vs osascript**: acceptable to ship osascript first?
5. **Autostart**: install a **launchd** LaunchAgent so it runs at login?

Sensible defaults if the user doesn't care: watch **authored** PRs across all repos,
notify on **CI finished + review activity + conflicts**, reuse **gh** token, osascript
notifications, poll every **60s**, offer launchd autostart as an opt-in.

## 5. Suggested architecture

SwiftPM executable package. Suggested layout:

```
pr-watch/
  Package.swift                # executable target, .macOS(.v13), swiftLanguageModes [.v5]
  Sources/PRWatch/
    PRWatchApp.swift           # @main App: WindowGroup (main window) + MenuBarExtra
    ContentView.swift          # main window: list of PRs w/ status + "open in browser"
    MenuBarView.swift          # menu-bar dropdown: compact PR list + Refresh/Quit/Settings
    SettingsView.swift         # poll interval, triggers, scope, PAT field (Keychain)
    PRStore.swift              # @MainActor ObservableObject: state, Timer polling, diff→notify
    GitHubClient.swift         # token resolution + GraphQL fetch + model decoding
    Notifier.swift             # osascript banner (v1); UNUserNotifications (upgrade)
    Keychain.swift             # store/read PAT (optional for v1)
  build.sh                     # swift build -c release → assemble .app → ad-hoc sign → open
  Resources/                   # AppIcon (optional)
  README.md
```

### Data fetch — single GraphQL query (efficient: CI + reviews + conflicts in one call)

`POST https://api.github.com/graphql` with `Authorization: bearer <token>`:

```graphql
query {
  viewer {
    login
    pullRequests(first: 30, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        title
        url
        isDraft
        repository { nameWithOwner }
        reviewDecision                 # APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | null
        mergeable                      # MERGEABLE | CONFLICTING | UNKNOWN
        commits(last: 1) {
          nodes { commit { statusCheckRollup { state } } }   # SUCCESS|FAILURE|ERROR|PENDING|EXPECTED
        }
      }
    }
  }
}
```

(For "also review-requested" scope, add a `search(query: "is:open is:pr review-requested:@me", …)`
block or a second query.)

### Poller + diff

- `PRStore` holds `[PullRequest]` and a `[prKey: LastState]` snapshot (persist to
  `UserDefaults`, keyed `owner/repo#number`).
- Timer every N seconds (default 60) → `GitHubClient.fetch()` → compare each PR's
  `(ciState, reviewDecision, mergeable)` against the snapshot.
- On a **transition** matching an enabled trigger, call `Notifier.notify(title:body:)`.
  - Suppress the very first fetch after launch (don't notify for pre-existing state).
  - Example CI transition: `PENDING → SUCCESS` ⇒ "✅ CI passed — #13290 RVR-19446".
- Menu-bar label: show a compact summary (e.g. count + a ✅/🟡/❌ glyph for worst state).

### Notifications (v1 — reliable)

```swift
func notify(title: String, body: String) {
  let p = Process()
  p.launchPath = "/usr/bin/osascript"
  p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Glass\""]
  try? p.run()
}
```
Escape `"` and `\` in strings. (Upgrade path: `UNUserNotificationCenter` with the bundle id;
requires the ad-hoc-signed `.app` — test whether banners appear before switching.)

### Token resolution

```
1. If a PAT is stored in Keychain → use it.
2. Else run  /bin/zsh -lc 'gh auth token'  and use stdout (trimmed).
3. Else surface an error in the UI prompting the user to `gh auth login` or paste a PAT.
```

### `.app` bundle + run (build.sh outline)

```sh
swift build -c release
APP="PR Watch.app"; BIN=.build/release/PRWatch
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PRWatch"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PR Watch</string>
  <key>CFBundleDisplayName</key><string>PR Watch</string>
  <key>CFBundleIdentifier</key><string>com.bszaf.prwatch</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>PRWatch</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- omit LSUIElement so it's a normal app with a window; MenuBarExtra still shows -->
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"     # ad-hoc sign (CLT has codesign)
open "$APP"
```

Optional autostart: a `LaunchAgent` plist in `~/Library/LaunchAgents/com.bszaf.prwatch.plist`
pointing at the bundle's binary, `RunAtLoad` true.

## 6. Milestones

1. **Scaffold + compile**: `Package.swift` + minimal `@main` App with a window and a
   `MenuBarExtra` that shows a static string. Confirm `swift build` succeeds and the
   assembled `.app` launches (window + menu-bar item visible).
2. **Fetch + render**: `GitHubClient` (gh token + GraphQL) → list real PRs with CI/review
   status in the window and menu bar.
3. **Poll + notify**: Timer + diff + osascript notifications on transitions; suppress first run.
4. **Settings**: poll interval, trigger toggles, scope; PAT-in-Keychain login option.
5. **Polish**: status glyphs, click-to-open-in-browser, error surfacing, optional launchd autostart.

## 7. Gotchas / notes

- **CLT-only**: no `xcodebuild`, no Xcode project. SwiftPM + manual bundle is the path.
- GUI from a SwiftPM binary can fail to activate properly unless run from a `.app` bundle —
  always test via the assembled/opened bundle, not `swift run`.
- If native notifications don't appear (unsigned/ad-hoc bundle), **stay on osascript** — it
  is confirmed working on this machine.
- Respect GitHub API rate limits: one GraphQL query per poll (~60 pts/hr at 60s interval is
  trivially fine).
- Keep secrets out of the repo; PAT only in Keychain, never written to disk in plaintext.
- Repo is standalone — **do not** put this inside the `alto` repo/worktree.

## 8. Status

- [x] Directory created, plan written.
- [ ] Everything in §6 — to be built by a fresh instance.
