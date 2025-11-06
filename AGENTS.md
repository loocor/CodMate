CodMate – AGENTS Guidelines

Purpose
- This document tells AI/code agents how to work inside the CodMate repository (macOS desktop GUI for Codex session management).
- Scope: applies to the entire repo. Prefer macOS SwiftUI/AppKit APIs; avoid iOS‑only placements or components.

Architecture
- App type: macOS SwiftUI app (min macOS 15). SwiftPM for sources + hand‑crafted Xcode project `CodMate.xcodeproj` for running/debugging.
- Layering (MVVM):
  - Models: pure data structures (SessionSummary, SessionEvent, DateDimension, SessionLoadScope, …)
  - Services: IO and side effects (SessionIndexer, SessionCacheStore, SessionActions, SessionTimelineLoader, LLMClient)
  - ViewModels: async orchestration, filtering, state (SessionListViewModel)
  - Views: SwiftUI views only (no business logic)

UI Rules (macOS specific)
- Use macOS SwiftUI and AppKit bridges; do NOT use iOS‑only placements such as `.navigationBarTrailing`.
- Settings uses macOS 15's new TabView API (`Tab("…", systemImage: "…")`) to split into multiple tabs; container padding is unified (horizontal 16pt, top 16pt).
  - Tab content uniformly uses `SettingsTabContent` container (top-aligned, overall 8pt padding) to ensure consistent layout and spacing across pages.
- Providers has been separated from the Codex tab into a top-level Settings page: Settings › Providers manages global providers and Codex/Claude bindings; Settings › Codex only retains Runtime/Notifications/Privacy/Raw Config (no longer includes Providers).
  - Built-in providers are auto-loaded from an app-bundled `payload/providers.json` (managedByCodMate=true). This avoids hardcoding and lets users simply provide API keys; base URLs/models come pre-filled. The list merges bundled entries with `~/.codmate/providers.json` (user overrides win).
  - Schema note: use a single provider-level `envKey` (preferred) for both Codex and Claude Code connectors. Connector-level `envKey` remains tolerated for backward compatibility but is considered deprecated and will be ignored at save time to avoid duplication.
- MCP Servers page (aligned with Providers style):
  - Main page directly displays existing server list (name, type icon, description, URL/command), with enable toggle on the left; provides pencil edit entry on the right.
  - Fixed "Add" button in top-right corner; clicking opens independent "New MCP Server" window for Uni‑Import.
  - New window supports paste/drag JSON text (can be extended to TOML/.mcpb later), previews parsing results and confirms import.
  - Advanced capabilities (MCPMate download and instructions) can still provide entry at page bottom or independent instruction area, no longer as separate sub-tab.
- Search: prefer a toolbar `SearchField` in macOS, not `.searchable` when exact placement (far right) matters.
- Toolbars: place refresh as the last ToolbarItem to pin it at the far right. Keep destructive actions in the detail pane, not in the main toolbar. Command+R and the refresh button also invalidate and recompute global sidebar statistics (projects/path tree and calendar day counts) to reflect new sessions immediately.
- Sidebar (left):
  - Top (fixed): "All Sessions" row showing total count and selection state.
  - Middle (scrollable): path tree built from `cwd` counts. Rows are compact: default min row height 18, small control size, reduced insets. Single‑click selects/expands; double‑click applies filter (enter the directory).
  - Bottom (fixed): calendar month view (240pt height) with per‑day counts (created/last‑updated switch). Always pinned to the bottom with 8pt spacing above. Supports multi‑select via Command‑click to toggle multiple days; plain click selects a single day (click the same day to clear).
  - Only the middle path tree scrolls; top "All Sessions" and bottom calendar remain fixed.
  - Sidebar width: min 220pt, max 25% of window width, ideal 260pt.
- Content (middle):
  - Default scope loads “today” only for speed.
  - Sorting picker is left‑aligned with list content.
  - Each row shows: title, timestamps/duration, snippet, and compact metrics (user/assistant/tool/reasoning).
- Detail (right):
  - Sticky action bar at top: Resume, Reveal in Finder, Delete, Export Markdown.
  - Add “New” button next to Resume to start a fresh Codex session using the current session’s working directory and model.
  - When an embedded terminal is running, show a “Prompts” button beside the folder (Reveal in Finder) icon. Clicking opens a searchable popover of preset command texts; selecting one inserts it into the embedded terminal input (does not auto-execute). User presses Return to run.
  - Review mode: the list.bullet.rectangle button toggles a full-area Review view (third mode, alongside Conversation and Internal Terminal). In Review mode the detail area is fully occupied by a Git Changes surface. It:
    - Auto-detects the Git repo at the session’s working directory (uses `/usr/bin/env git` and a robust PATH).
    - Lists changed files with stage/unstage toggles and shows a unified diff or a raw file preview (updates on save). Preview is text-only in phase 1.
    - Provides a commit box. In full-area mode it uses a multi-line editor with more space.
    - Repository authorization is on-demand: when opening Review, the app resolves the repository root (the folder containing `.git`) and, if needed, prompts the user with an NSOpenPanel to authorize that folder via a security-scoped bookmark. The Settings page no longer lists authorized repositories; authorization and revoke are managed inline in the Review header.
  - “Task Instructions” uses a DisclosureGroup; load lazily when expanded.
  - Conversation timeline uses LazyVStack; differentiate user/assistant/tool/info bubbles.
  - Timeline & Markdown visibility: Settings › General provides per-surface checkboxes to choose which message types are shown in the conversation timeline and included when exporting Markdown. Defaults: Timeline shows all except Environment Context (which has its own section); Markdown includes only User and Assistant.
  - Context menu in list rows adds: “Generate Title & 100-char Summary” to run LLM on-demand for the selected session.
- Embedded Terminal: One live shell per session when resumed in-app; switching sessions in the middle list switches the attached terminal. The shell keeps running when you navigate away. “Return to history” closes the running shell for the focused session.
  - Prompt picker: When embedded terminal is running, a Prompts button opens a searchable list. Prompts are merged from per-project `.codmate/prompts.json` (if present) and `~/.codmate/prompts.json` (user), de-duplicated by command, then layered with a few built‑ins. Items accept either `{ "label": "…", "command": "…" }` or a plain string (used for both). Selection inserts into the terminal input without executing. The header wrench button opens the preferred file (project if exists, else user). Typing a new command shows “Add …” to create a prompt in the preferred file. Deleting a built‑in prompt records it in a hidden list (`prompts-hidden.json` at project if project prompts exist, else at user), which suppresses that built‑in in the UI.
  - Terminal shortcuts: (none for now). Clearing via shortcut is not implemented.

Performance Contract
- Fast path indexing: memory‑mapped reads; parse first ~400 lines + read tail ~64KB to correct `lastUpdatedAt`.
- Background enrichment: full parse in a constrained task group; batch UI updates (≈10 items per flush).
- Full‑text search: chunked stream scan (128 KB), case‑insensitive; avoid `lowercased()` on whole file.
- Disk cache: `~/Library/Caches/CodMate/sessionIndex-v1.json` keyed by path+mtime; prefer cache hits before parsing.
- Sidebar statistics (calendar/tree) must be global and computed independently of the current list scope to keep navigation usable.
 - Embedded terminals: keep shells alive when not visible; only render the selected session’s terminal. Users explicitly close shells via “Return to history” to release resources.

Coding Guidelines
- Concurrency: use `actor` for services managing shared caches; UI updates on MainActor only.
- Cancellation: cancel previous tasks on new search/scope changes. Name tasks (`fulltextTask`, `enrichmentTask`) and guard `Task.isCancelled` in loops.
- File IO: prefer `Data(mappedIfSafe:)` or `FileHandle.read(upToCount:)`; never load huge files into Strings.
- Error handling: surface user‑visible errors through `ViewModel.errorMessage` and macOS system notifications/alerts; do not crash the UI.
- Testability: keep parsers and small helpers pure; avoid `Process()`/AppKit in ViewModel.

CLI Integration (codex)
- Do not expose user-configurable CLI paths. Always invoke via `/usr/bin/env codex` (or `claude`) so resolution happens on system `PATH`.
- Always set `PATH` to include `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` before launching for robustness.
- `resume` runs with `currentDirectoryURL` = original session `cwd` when it exists (fallback: log file directory).
- New command options exposed in Settings › Command:
   - Sandbox policy (`-s/--sandbox`): `read-only`, `workspace-write`, `danger-full-access`.
   - Approval policy (`-a/--ask-for-approval`): `untrusted`, `on-failure`, `on-request`, `never`.
   - `--full-auto` convenience alias (maps to `-a on-failure` + `--sandbox workspace-write`).
   - `--dangerously-bypass-approvals-and-sandbox` (overrides other flags; only for externally sandboxed envs).
- UI adds a "Copy real command" button in the detail action bar when the embedded terminal is active; this copies the exact `codex resume <id>` invocation including flags.
- Provide a “New” command (detail toolbar) that launches `codex` in the session’s working directory while preserving the configured sandbox/approval defaults and `SessionSummary.model`.

Codex Settings
- Settings › Codex only manages Codex CLI runtime-related configuration (Model & Reasoning, Sandbox & Approvals, Notifications, Privacy, Raw Config).
- Providers page is independent: Settings › Providers (cross-application shared, for Codex and Claude Code selection/configuration).
- Notifications: TUI notifications toggle; system notifications bridge via `notify` (built‑in script path is managed by CodMate).
- Privacy: expose `shell_environment_policy`, reasoning visibility, OTEL exporter; do not surface history persistence in phase 1.
- Projects auto‑create a same‑id Profile on creation; renaming a project synchronizes the profile name. Conflict prompts are required.

Session Metadata (Rename/Comment)
- Users can rename any session and attach a short comment.
- Trigger: click the title at the top-left of the detail pane to open the editor.
- Persistence: stored per file under `~/.codmate/notes/<sessionId-sanitized>.json`. A first-run migration copies entries from the legacy Application Support JSON and migrates from the legacy `~/.codex/notes` directory when present.
- Display: the name replaces the ID in the detail header and list; the comment is used as the row snippet when present.

About Surface
- Settings › About shows app version, build timestamp (derived from the app executable’s modification date), and project URL.
- “About CodMate” menu item should open Settings pre-selecting the About tab.
 - Include an “Open Source Licenses” entry that displays `THIRD-PARTY-NOTICES.md` (bundled if present; falls back to repository URL if missing).

Diagnostics
- Settings › General adds “Diagnose Data Directories” to probe Sessions (`~/.codex/sessions`, `.jsonl`), Notes (`~/.codmate/notes`, `.json`), and Projects (`~/.codmate/projects`, `.json`) — existence, counts, sample files, and enumerator errors.
  - Also probes Claude Code sessions (`~/.claude/projects`, `.jsonl`) for presence and counts.
- When the current root has 0 sessions but the default has files, the UI suggests switching to the default path.
- Users can “Save Report…” to export a JSON diagnostics file for troubleshooting.

File/Folder Layout
- Sources/CodMate/
  - Models/  – data types
- Services/ – IO, indexing, cache, codex actions
  - ViewModels/ – observable state
  - Views/ – SwiftUI views only
- CodMate/Info.plist – bundled via build settings; do NOT add to Copy Bundle Resources.
- CodMate.xcodeproj – single app target “CodMate”.

Dialectics Page
- Adds a dedicated Settings › Dialectics page (between MCP Server and About) that aggregates diagnostics:
  - Codex sessions root probe (current vs default), counts and sample files, enumerator errors
  - Claude sessions directory probe (default path), counts and samples
  - Notes and Projects directories probes (current vs default), counts and sample files
  - CLI environment: preferred and resolved codex and Claude paths, PATH snapshot
  - Does not mutate config automatically; changes only happen via explicit user actions in other pages

PR / Change Policy for Agents
- Keep changes minimal and focused; do not refactor broadly without need.
- Maintain macOS compliance first; avoid iOS‑only modifiers/placements.
- When changing UI structure, update this AGENTS.md and the in‑app Settings if applicable.
- Validate performance: measure large session trees; ensure first paint is fast and enrichment is incremental.

Known Pitfalls
- `.searchable` may hijack the trailing toolbar slot on macOS; use `SearchField` in a `ToolbarItem` to control placement.
- Don’t put Info.plist in Copy Bundle Resources (Xcode will warn and refuse to build).
- OutlineGroup row height is affected by control size and insets; tighten with `.environment(\.defaultMinListRowHeight, 18)` and `.listRowInsets(...)` inside the row content.
- Swift KeyPath escaping when patching: do not double-escape the leading backslash in typed key paths. Always write single-backslash literals like `\ProvidersVM.codexBaseURL` in Swift sources. The apply_patch tool takes plain text; extra escaping (e.g., `\\ProvidersVM...`) will compile-fail and break symbol discovery across files.
- Prefer dot-shorthand KeyPaths in Swift (clearer, avoids escaping pitfalls): use `\.codexBaseURL` instead of `\ProvidersVM.codexBaseURL` when the generic context already constrains the base type (e.g., `ReferenceWritableKeyPath<ProvidersVM, String>`). This makes patches safer and reduces chances of accidental extra backslashes.
- String interpolation gotcha: do not escape quotes inside `\( ... )`. Write `Text("Codex: \(dict["codex"] ?? "")")`, not `Text("Codex: \(dict[\"codex\"] ?? \"\")")`. Escaping quotes inside interpolation confuses the outer string literal and can cause “Unterminated string literal”.
