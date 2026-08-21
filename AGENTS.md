---
description: Agent house rules for the pr-watch macOS app
alwaysApply: true
---

# pr-watch — agent instructions

A native **macOS desktop app + menu-bar item** that watches the signed-in user's GitHub
PRs and sends desktop notifications on changes (CI finished, review activity, conflicts).
[`README.md`](./README.md) describes current behavior — read it first. [`PLAN.md`](./PLAN.md)
is the original build brief, kept for historical/background context.

## Build & run (READ THIS — the environment is non-standard)

- **Command Line Tools only, NO full Xcode** on this machine. There is **no `xcodebuild`**.
  - Build with **SwiftPM**: `swift build` / `swift build -c release`.
  - There is **no `.xcodeproj`/scheme** — do not assume one. Ignore the parts of any
    external Swift skill that tell you to use Xcode, schemes, or `xcodebuild`.
- To produce a runnable app, **hand-assemble a `.app` bundle** and **ad-hoc codesign** it
  (`codesign --force --deep --sign - "PR Watch.app"`). See `build.sh` (per `PLAN.md`).
  Always test by launching the **assembled bundle** (`open "PR Watch.app"`), not `swift run`
  — a bare SwiftPM binary often won't activate as a GUI app (no window / no menu-bar item).
- Tests: run **`./test.sh`** (not bare `swift test`). Swift Testing ships in the CLT
  toolchain but `Testing.framework` isn't on the SDK search path, so `test.sh` adds it for
  compile/link/rpath. Targeted: `./test.sh --filter <Suite>/<test>`.

## Definition of done (precommit gate — run before handoff)

1. `swift build -c release` compiles **warning-clean**.
2. `./test.sh` passes (targeted is fine while iterating).
3. `swift format` (if adopted) / no obvious lint issues.
4. The assembled `.app` **launches**: window opens, menu-bar item appears, a manual
   refresh shows real PRs. State this was verified — don't claim done on compile alone.
5. After changing behavior or values (poll intervals, tab names, triggers, costs), grep
   `README.md` and the Settings UI strings for stale references and update them — docs
   drift on this has already recurred twice.

## Swift / SwiftUI conventions

Follow the vendored guidance in [`docs/swift/`](./docs/swift/) (sources in
`docs/swift/SOURCES.md`). Highlights:

- **SwiftUI-first.** Use AppKit only where SwiftUI can't (e.g. `NSStatusItem` fallback).
  Notifications are `UNUserNotifications` (primary path); `osascript` is only the
  unauthorized fallback. `Process` is also used for CLI token resolution and git.
  `MenuBarExtra` + `WindowGroup` cover our needs.
- **Modern state flow:** `@Observable` (Observation framework) over `ObservableObject`
  where practical — see `docs/swift/swift-observation.mdc`. `@State` for view-local state.
- **Concurrency:** `async/await` and actors; keep UI-touching types `@MainActor`. NOTE the
  build uses **Swift 5 language mode** (`swiftLanguageModes: [.v5]`) to avoid strict-
  concurrency friction — don't switch to Swift 6 mode without a reason.
- **macOS-idiomatic UI:** follow the Human Interface Guidelines; use **SF Symbols** for
  iconography; native controls and spacing.
- **Testing:** prefer **Swift Testing** (`@Test`, `#expect`) — see
  `docs/swift/swift-testing-playbook.mdc`. Match your standing preference: no low-value
  tests (e.g. a test that only asserts an enum accepts a value); test real behavior.

## Security

- **Never commit secrets or API keys.** No GitHub tokens/PATs in source, plists, or git.
- A pasted **PAT goes only in the macOS Keychain**, never written to disk in plaintext.
- Prefer reusing the existing `gh` login for the token (`/bin/zsh -lc 'gh auth token'`).
- **Never read or access `.env`;** ask the user if env details are needed.
- Respect GitHub API rate limits — at most two GraphQL queries per poll (a cheap phase-A
  list query + a targeted phase-B thread fetch only when needed), with `x-ratelimit`-based
  backoff; stay well inside the 5,000-point/hour budget.

## Style & workflow

- **Terse comments.** One line, only when non-obvious; no rationale paragraphs.
- **Trust internal contracts;** avoid defensive guards for impossible/normalized states.
- **Git branches:** `feat/<kebab-name>` (matching this repo's history, e.g.
  `feat/demo-mode`). This is a personal repo with no Linear tickets — this convention
  overrides any global Linear-ticket-based branch naming convention.
- Commit/push only when asked; if on the default branch, branch first.
- This repo is standalone — **never** nest it inside the `app` repo/worktree.
- **Demo mode** (Settings → General → Developer) renders synthetic fixtures through the
  real views as a living visual reference. Whenever you change the UX or a rendered
  scenario (a new status glyph, badge, relation, activity kind, metadata row, tab, …),
  **update `Sources/PRWatch/DemoData.swift`** so demo mode stays a complete reference and
  keeps reviews easy.

## Reference docs (in `docs/swift/`)

| File | Use for |
|---|---|
| `modern-swift.md` | Core SwiftUI philosophy & architecture defaults |
| `swift-observation.mdc` | `@Observable` state model (for `PRStore`) |
| `swift-testing-playbook.mdc` | Writing Swift Testing suites |
| `swiftui-pro-hygiene.md` | View-code hygiene |
| `swiftui-pro-performance.md` | SwiftUI performance pitfalls |

Deeper/very large references (SwiftUI & AppKit full API dumps, Swift 6 migration) are
**linked, not vendored** — see `docs/swift/SOURCES.md`.
