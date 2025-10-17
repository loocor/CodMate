# CodMate Sessions Viewer

Native SwiftUI utility that scans `~/.codex/sessions` JSONL logs, surfaces rich statistics, and streamlines resume/cleanup workflows for Codex CLI users on macOS.

## Feature Highlights
- **Directory-aware indexer**: Parses session archives grouped by date, caching metadata (duration, event counts, CLI version, instructions).
- **Search & sort**: Filter by repo path, instruction text, or model; sort by recency, duration, activity, or file size.
- **Actionable detail pane**: Review key metrics, instructions, and metadata side-by-side with quick actions.
- **One-click resume**: Launch `codex resume <session-id>` directly from the UI using your configured CLI binary.
- **Safe cleanup**: Move selected sessions to the system Trash with confirmation dialogs.
- **Configurable paths**: Adjust the sessions root or Codex CLI executable via toolbar shortcuts.
- **Xcode ready**: Native `.xcodeproj` included for full debugger support (breakpoints, previews, signing).

## Getting Started
1. **Prerequisites**
   - macOS 14+ with Swift toolchain 5.9 or later.
   - Codex CLI installed (`codex --version`) and accessible (default search path `/usr/local/bin/codex`).
   - Existing session logs under `~/.codex/sessions` (created by Codex CLI runs).
2. **Build (CLI)**
   ```sh
   swift build
   ```
   Open the generated `.app` bundle from `.build/debug/CodMate.app`.
   - Alternatively open `CodMate.xcodeproj` directly in Xcode 15.2+ and pick the **CodMate** scheme (My Mac destination). Building from Xcode produces `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/CodMate.app` ready for Run/Debug.
3. **First Run**
   - On launch, the app scans the default Codex sessions directory.
   - Use the toolbar to refresh, pick a different sessions folder, or point to a custom Codex CLI binary.
4. **Resuming Sessions**
   - Select a session in the sidebar and click **恢复** (Resume).
   - The app spawns `codex resume <session-id>` in the session file’s directory and surfaces command output via a toast.
5. **Cleanup**
   - Command-click to multi-select sessions, then click **删除**. Files are moved to the Trash (Finder can restore them if needed).

## Validation
- `swift build` succeeds (compiles the SwiftUI executable target).
- `swift test` runs lightweight coverage (session summary matching).

## Roadmap Ideas
- Event timeline visualization with filtering by event type.
- Export selected sessions as a zipped bundle for archiving.
- Intelligent deduplication hints (detect overlapping working directories).
- Optional telemetry (per-project usage counts, token usage charts).

## Tips
- Logs can grow quickly; schedule periodic cleanups or archive old days.
- Keep the Codex CLI up to date so `resume` restores full terminal context.
