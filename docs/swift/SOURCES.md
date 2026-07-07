# Vendored Swift/SwiftUI agent guidance — sources & attribution

The `.md`/`.mdc` files in this directory are **vendored copies** of open-source agent
guidance, kept locally so the agent can read them without network access. Originals and
licenses below. Trim/adapt freely for this project (they assume full Xcode in places — we
build **CLT-only via SwiftPM**, see `../../AGENTS.md`).

## Vendored here

| Local file | Source | License |
|---|---|---|
| `modern-swift.md` | [steipete/agent-rules · docs/modern-swift.md](https://github.com/steipete/agent-rules/blob/main/docs/modern-swift.md) | MIT |
| `swift-observation.mdc` | [steipete/agent-rules · docs/swift-observation.mdc](https://github.com/steipete/agent-rules/blob/main/docs/swift-observation.mdc) | MIT |
| `swift-testing-playbook.mdc` | [steipete/agent-rules · docs/swift-testing-playbook.mdc](https://github.com/steipete/agent-rules/blob/main/docs/swift-testing-playbook.mdc) | MIT |
| `swiftui-pro-hygiene.md` | [twostraws/swiftui-agent-skill · swiftui-pro/references/hygiene.md](https://github.com/twostraws/swiftui-agent-skill) | see repo |
| `swiftui-pro-performance.md` | [twostraws/swiftui-agent-skill · swiftui-pro/references/performance.md](https://github.com/twostraws/swiftui-agent-skill) | see repo |

## Large references — linked, not vendored (too big to keep inline)

- SwiftUI full API reference — [steipete/agent-rules · docs/swiftui.md](https://github.com/steipete/agent-rules/blob/main/docs/swiftui.md) (~1.8 MB)
- AppKit reference — [steipete/agent-rules · docs/appkit.md](https://github.com/steipete/agent-rules/blob/main/docs/appkit.md) (~2.4 MB); useful for `NSStatusItem` / menu-bar internals if `MenuBarExtra` is insufficient
- Swift 6 concurrency migration — [steipete/agent-rules · docs/swift6-migration.mdc](https://github.com/steipete/agent-rules/blob/main/docs/swift6-migration.mdc) (~129 KB); only if we move off Swift 5 language mode

## Other good skill packs (optional, not vendored)

- **Apple's official Agent Skills** (Xcode 26.3/27) — `swiftui-specialist`, Swift Testing,
  security hardening. Community export: [superagents-lab/xcode27-skills](https://github.com/superagents-lab/xcode27-skills).
  Overviews: [SwiftLee](https://www.avanderlee.com/ai-development/using-xcode-27s-agent-skills-in-claude-codex-and-cursor/),
  [DEV](https://dev.to/arshtechpro/xcode-263-use-ai-agents-from-cursor-claude-code-beyond-4dmi).
- **Paul Hudson — SwiftUI Pro skill:** [twostraws/swiftui-agent-skill](https://github.com/twostraws/swiftui-agent-skill)
  (`swiftui-pro/references/`: accessibility, api, data, design, navigation, views…).
- **Antoine van der Lee — SwiftUI Expert skill:** [AvdLee/SwiftUI-Agent-Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill).
- **Peter Steinberger — full agent-rules repo** (AppKit, SwiftData, arg-parser, testing,
  project-rules/commands): [steipete/agent-rules](https://github.com/steipete/agent-rules).
- Real-world macOS build writeup: [Indragie Karunaratne — "I Shipped a macOS App Built Entirely by Claude Code"](https://www.indragie.com/blog/i-shipped-a-macos-app-built-entirely-by-claude-code).
