# Remote Session Support — Design Overview

## Goals
- Discover remote Codex / Claude CLI sessions on developer workstations (e.g. Ubuntu hosts) over SSH using existing `~/.ssh/config` entries.
- Let users opt in to the specific SSH hosts that CodMate should mirror instead of blindly attempting every alias found in the config.
- Mirror remote session logs locally so that the existing parsers, indexers, and SwiftUI UI can continue to operate without large refactors.
- Reuse current resume/new/export flows while routing commands through `ssh` when a session originates from a remote host.
- Provide a lightweight Settings pane so users can toggle which SSH hosts CodMate mirrors while still leveraging their existing `~/.ssh/config` entries.

## Architecture

### Host Discovery
- New `SSHConfigResolver` scans `~/.ssh/config`, collecting concrete host aliases (skipping wildcard-only entries).
- Each resolved host becomes a candidate remote provider. Users enable a subset of these aliases from Settings ▸ Codex ▸ Remote Hosts. For v1 we assume Codex sessions live under `~/.codex/sessions` and Claude logs under `~/.claude/projects`.

### Remote Mirroring
- `RemoteSessionMirror` (actor) maintains a cache root inside `~/Library/Caches/CodMate/remote/<host>/<provider>`.
- On refresh, the mirror:
  1. Derives the minimal remote subdirectories required by the requested `SessionLoadScope` (day, month, all, etc.).
  2. Uses `ssh host "cd <base> && find <subdir> -type f -name '*.jsonl' -printf '%P|%s|%T@'"` to list files plus size/mtime.
  3. Downloads missing or stale files via `scp -p`.
  4. Records a mapping of `localURL → remoteAbsolutePath` for later CLI usage.

### Session Providers
- `RemoteCodexSessionProvider` and `RemoteClaudeSessionProvider` call the mirror, then run the existing `SessionIndexer` / `ClaudeSessionParser` over the mirrored tree.
- Returned `SessionSummary` objects are re-tagged with new `SessionSource` cases (`codexRemote(host)`, `claudeRemote(host)`) and decorated with their originating remote path.

### Model & UI Updates
- `SessionSource` gains locality-aware cases plus helper properties (`isRemote`, `remoteHost`, `branding`).
- `SessionSummary` stores `remotePath` so resume/export flows can regenerate the remote command.
- `SessionListRowView` shows a host badge when `summary.source.isRemote`.
- Filtering, sorting, projects, and quick search continue to operate on merged datasets; search includes the remote host name.
- A new Remote Hosts pane in Codex settings surfaces the discovered host aliases, allowing opt-in toggles and showing any enabled hosts that are currently missing from the SSH config.

### Actions & Terminal Integration
- `SessionActions` branches on `session.source.isRemote` to:
  - Execute commands via `/usr/bin/ssh host "<codex command>"`.
  - Produce `ssh` command lines for copy/export and Terminal/iTerm/Warp launches.
  - Seed embedded terminals with `ssh host` preamble so SwiftTerm sessions control the remote shell.

## Scope & Limitations
- Mirrors rely on GNU `find`/`stat` (Ubuntu default). Non-GNU systems may need adjustments later.
- Remote directories are assumed to follow the same Codex/Claude layout as the local machine.
- v1 performs whole-directory listing per refresh; further optimisations (incremental polling, metadata caches) can be layered later.
- Fallback behaviour: if SSH commands fail, the UI surfaces an error banner and omits that host for the current refresh while leaving local sessions unaffected.
