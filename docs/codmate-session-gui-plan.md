# Codex Session GUI Helper – Architecture Notes

## Goals
- Surface historical Codex CLI sessions (`~/.codex/sessions`) with rich metadata (project path, duration, activity counts).
- Provide fast sorting/search across thousands of JSONL logs without re-parsing everything on every UI interaction.
- Offer contextual actions: open session folder, delete selected sessions, resume via `codex resume`.
- Keep the experience purely local, macOS-native (SwiftUI, macOS 15+/26 design language), no network access.

## High-Level Structure
```
CodMate (SwiftUI App)
├─ Models/
│  ├─ SessionEvent.swift       // Codable representations of JSONL rows
│  ├─ SessionSummary.swift     // Aggregated metrics exposed to the UI
├─ Services/
│  ├─ SessionIndexer.swift     // Incremental scanner + caching
│  ├─ SessionActions.swift     // Delete/resume helpers wrapping `Process`
├─ Views/
│  ├─ ContentView.swift        // Sidebar layout with filters + detail pane
│  ├─ SessionDetailView.swift  // Drill-down view of a single session
│  └─ SessionListRowView.swift // Per-session summary row
└─ ViewModels/
   └─ SessionListViewModel.swift
```

## Session Parsing Strategy
- Each `.jsonl` file begins with a `session_meta` entry. Subsequent entries (`turn_context`, `event_msg`, `response_item`) describe the conversation.
- The indexer walks the sessions directory tree lazily, grouping by `YYYY/MM/DD` to support hierarchical browsing.
- Aggregated metrics computed:
  - `start`, `end`, and `duration` (ISO timestamps → `Date`).
  - Counts per payload type (user vs assistant vs tool call).
  - Top-level instruction snippet (first 600 characters from `session_meta.payload.instructions`).
  - CLI version, working directory, model, approval policy.
- JSONL rows are parsed once and cached via `NSCache` keyed by file path + mtime hash to avoid reparsing every display.

## Sorting & Filters
- Debounced search over session name, cwd, model, and instruction snippet.
- Sort toggles: `Most Recent`, `Longest Duration`, `Most Actions`, `CLI Version`.
- Group header summarises daily totals.

## Actions
- **Resume**: spawn `/usr/local/bin/codex resume <session-id>` (path configurable via settings sheet). Visible spinner + error toast.
- **Reveal in Finder**: open the containing folder for quick inspection.
- **Delete Selected**: moves session file(s) to Trash using `FileManager.trashItem`.
- Safeguards: confirmation alerts, async/await wrappers, no destructive deletions without Trash fallback.

## UI Sketch
- Split view: left column list with search field, tags for filters, aggregated chips. Right column uses `GroupBox` + `Form` sections for metadata, timeline preview (chart of events per minute), and actions bar.
- Accent color follows system accent; adopt `toolbarBackground(.visible, for: .windowToolbar)` for Sonoma/macOS 15 look. Support dark/light.

## Extensibility
- Provide `SessionTimeline` model for eventual event playback.
- Settings store (AppStorage) for sessions root override and CLI executable path.
- Export selected sessions as `.jsonl` bundle.
- Ship first-party `CodMate.xcodeproj` for Xcode debugging, leaving SwiftPM manifest for CLI builds.
