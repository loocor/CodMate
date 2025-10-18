CodMate – AGENTS Guidelines

Purpose
- This document tells AI/code agents how to work inside the CodMate repository (macOS desktop GUI for Codex session management).
- Scope: applies to the entire repo. Prefer macOS SwiftUI/AppKit APIs; avoid iOS‑only placements or components.

Architecture
- App type: macOS SwiftUI app (min macOS 14). SwiftPM for sources + hand‑crafted Xcode project `CodMate.xcodeproj` for running/debugging.
- Layering (MVVM):
  - Models: pure data structures (SessionSummary, SessionEvent, DateDimension, SessionLoadScope, …)
  - Services: IO and side effects (SessionIndexer, SessionCacheStore, SessionActions, SessionTimelineLoader, LLMClient)
  - ViewModels: async orchestration, filtering, state (SessionListViewModel)
  - Views: SwiftUI views only (no business logic)

UI Rules (macOS specific)
- Use macOS SwiftUI and AppKit bridges; do NOT use iOS‑only placements such as `.navigationBarTrailing`.
- Search: prefer a toolbar `SearchField` in macOS, not `.searchable` when exact placement (far right) matters.
- Toolbars: place refresh as the last ToolbarItem to pin it at the far right. Keep destructive actions in the detail pane, not in the main toolbar.
- Sidebar (left):
  - Top (fixed): "All Sessions" row showing total count and selection state.
  - Middle (scrollable): path tree built from `cwd` counts. Rows are compact: default min row height 18, small control size, reduced insets. Single‑click selects/expands; double‑click applies filter (enter the directory).
  - Bottom (fixed): calendar month view (240pt height) with per‑day counts (created/last‑updated switch). Always pinned to the bottom with 8pt spacing above.
  - Only the middle path tree scrolls; top "All Sessions" and bottom calendar remain fixed.
  - Sidebar width: min 220pt, max 25% of window width, ideal 260pt.
- Content (middle):
  - Default scope loads “today” only for speed.
  - Sorting picker is left‑aligned with list content.
  - Each row shows: title, timestamps/duration, snippet, and compact metrics (user/assistant/tool/reasoning).
- Detail (right):
  - Sticky action bar at top: Resume, Reveal in Finder, Delete, Export Markdown.
  - Add “New” button next to Resume to start a fresh Codex session using the current session’s working directory and model.
  - “Task Instructions” uses a DisclosureGroup; load lazily when expanded.
  - Conversation timeline uses LazyVStack; differentiate user/assistant/tool/info bubbles.
  - Context menu in list rows adds: “Generate Title & 100-char Summary” to run LLM on-demand for the selected session.

Performance Contract
- Fast path indexing: memory‑mapped reads; parse first ~400 lines + read tail ~64KB to correct `lastUpdatedAt`.
- Background enrichment: full parse in a constrained task group; batch UI updates (≈10 items per flush).
- Full‑text search: chunked stream scan (128 KB), case‑insensitive; avoid `lowercased()` on whole file.
- Disk cache: `~/Library/Caches/CodMate/sessionIndex-v1.json` keyed by path+mtime; prefer cache hits before parsing.
- Sidebar statistics (calendar/tree) must be global and computed independently of the current list scope to keep navigation usable.

Coding Guidelines
- Concurrency: use `actor` for services managing shared caches; UI updates on MainActor only.
- Cancellation: cancel previous tasks on new search/scope changes. Name tasks (`fulltextTask`, `enrichmentTask`) and guard `Task.isCancelled` in loops.
- File IO: prefer `Data(mappedIfSafe:)` or `FileHandle.read(upToCount:)`; never load huge files into Strings.
- Error handling: surface user‑visible errors through `ViewModel.errorMessage` and transient Toast/Alert; do not crash the UI.
- Testability: keep parsers and small helpers pure; avoid `Process()`/AppKit in ViewModel.

CLI Integration (codex)
- Resolve executable path: prefer user setting; fallback to `/opt/homebrew/bin` → `/usr/local/bin` → `env which codex`.
- Always set `PATH` to include `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` before launching.
- `resume` runs with `currentDirectoryURL` = original session `cwd` when it exists (fallback: log file directory).
- New command options exposed in Settings › Command:
   - Sandbox policy (`-s/--sandbox`): `read-only`, `workspace-write`, `danger-full-access`.
   - Approval policy (`-a/--ask-for-approval`): `untrusted`, `on-failure`, `on-request`, `never`.
   - `--full-auto` convenience alias (maps to `-a on-failure` + `--sandbox workspace-write`).
   - `--dangerously-bypass-approvals-and-sandbox` (overrides other flags; only for externally sandboxed envs).
- UI adds a "Copy real command" button in the detail action bar when the embedded terminal is active; this copies the exact `codex resume <id>` invocation including flags.
- Provide a “New” command (detail toolbar) that launches `codex` in the session’s working directory while preserving the configured sandbox/approval defaults and `SessionSummary.model`.

Session Metadata (Rename/Comment)
- Users can rename any session and attach a short comment.
- Trigger: click the title at the top-left of the detail pane to open the editor.
- Persistence: stored in `~/Library/Application Support/CodMate/sessionNotes-v1.json`, keyed by session id.
- Display: the name replaces the ID in the detail header and list; the comment is used as the row snippet when present.

About Surface
- Settings › About shows app version, build timestamp (derived from the app executable’s modification date), and project URL.
- “About CodMate” menu item should open Settings pre-selecting the About tab.

File/Folder Layout
- Sources/CodMate/
  - Models/  – data types
- Services/ – IO, indexing, cache, codex actions
  - ViewModels/ – observable state
  - Views/ – SwiftUI views only
- CodMate/Info.plist – bundled via build settings; do NOT add to Copy Bundle Resources.
- CodMate.xcodeproj – single app target “CodMate”.

PR / Change Policy for Agents
- Keep changes minimal and focused; do not refactor broadly without need.
- Maintain macOS compliance first; avoid iOS‑only modifiers/placements.
- When changing UI structure, update this AGENTS.md and the in‑app Settings if applicable.
- Validate performance: measure large session trees; ensure first paint is fast and enrichment is incremental.

Known Pitfalls
- `.searchable` may hijack the trailing toolbar slot on macOS; use `SearchField` in a `ToolbarItem` to control placement.
- Don’t put Info.plist in Copy Bundle Resources (Xcode will warn and refuse to build).
- OutlineGroup row height is affected by control size and insets; tighten with `.environment(\.defaultMinListRowHeight, 18)` and `.listRowInsets(...)` inside the row content.
