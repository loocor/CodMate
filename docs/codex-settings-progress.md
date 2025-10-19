# Codex Settings, Providers, Projects/Profiles – Progress & Decisions

Status: planning → implementation kickoff

Date: 2025-10-19

Scope: Implement a top-level Settings › Codex page and supporting services to manage Codex CLI configuration (providers, defaults, notifications, privacy), plus Projects ↔ Profiles integration and instructions injection. MCP management is explicitly out-of-scope (handled by MCPMate). Minimum macOS raised to 15 (use new TabView API).

Principle (SORT): Prefer the simplest option that delivers value quickly; defer optional complexity behind flags and clearly document alternatives in this file.

---

## High-level Goals

- Centralize Codex-related configuration under Settings › Codex (separate from General/Terminal/MCP).
- Providers: CRUD a list of `model_providers`, single-select to set the current `model_provider`.
- Notifications: two toggles — TUI notifications; system notifications via a bundled bridge script wired to Codex `notify`.
- Privacy: expose `shell_environment_policy`, reasoning visibility, OTEL exporter; do not disable Codex history in phase 1.
- Projects × Profiles: create a Project → auto-create same-id Profile; keep them in sync on rename; allow session → project association (drag/menus); inject project instructions into Codex at launch (opt-in per project).
- Same-root archive suggestion: system notification offering one-click archive to the matching Project.

Non-goals (phase 1):
- MCP servers management (handled by MCPMate).
- Network probing/“test connection” for providers.
- Attaching historical conversations to instructions (to avoid token bloat).

---

## Architecture & Files

- Service actors
  - `CodexConfigService` (actor): read/merge/write `~/.codex/config.toml`; minimal-diff writes; backup/rollback; manages only CodMate-owned blocks (tagged with `# managed-by=codmate`).
  - `ProjectStore` (actor): CRUD for `~/Library/Application Support/CodMate/projects-v1.json`; session ↔ project mapping; same-root suggestions (rate‑limited).
  - `InstructionInjector` (actor): generates per-launch temp instructions file when a project has injection enabled; cleans up.
- ViewModels
  - `CodexSettingsViewModel` plus scoped VMs (Providers/Notifications/Privacy/Profiles) for Settings › Codex page.
- Views
  - Settings › Codex: sections for Providers, Model & Reasoning, Sandbox & Approvals, Notifications, Privacy, Profiles. Respect macOS toolbar/placement rules.

---

## User-visible Behavior

### Providers
- List view with radio selection sets `model_provider`.
- Add/Edit/Delete provider blocks (`[model_providers.<id>]`): fields `id`, `name`, `base_url`, `env_key`, `wire_api`, `query_params`, `http_headers`, `env_http_headers`, `request_max_retries`, `stream_max_retries`, `stream_idle_timeout_ms`.
- Delete current provider allowed with confirmation; after delete, fallback to first available or unset.
- Validation: lightweight, non-blocking; Azure hints for `api-version`.

### Notifications
- Toggle 1: TUI notifications (`tui.notifications = true|false`).
- Toggle 2: System notifications bridge; sets `notify = ["<codemate-notify>"]`.
  - Bridge resolution: `~/Library/Application Support/CodMate/bin/codemate-notify`.
  - Behavior: consume single JSON arg; prefer `terminal-notifier`, fallback to `osascript`.
  - Event coverage: currently only `agent-turn-complete` (explicitly documented).
- Same-root archive suggestion is emitted by CodMate itself (not via Codex `notify`).

### Privacy
- `shell_environment_policy` editor (inherit template, include_only/exclude/set) with a preview of the final env.
- `hide_agent_reasoning` / `show_raw_agent_reasoning` toggles with risk notes.
- OTEL exporter config (default disabled).
- Do not surface `history.persistence` in phase 1 to avoid breaking CodMate value.

### Projects × Profiles
- Project model: `{ id, name, description, instructionsMarkdown, rootDirectories[], linkedProfileName }`.
- Create Project → auto-create `[profiles.<project.id>]` (minimal keys: `model_provider`/`model`/approval/sandbox); `linkedProfileName = <id>`.
- Rename Project → atomically rename profile block `[profiles.old] → [profiles.new]`; update any top-level `profile="old"` to `"new"`; update all sessions `projectId`.
- Conflict handling on rename (no auto-suffix):
  1) Re-link to existing profile with same id;
  2) Replace existing profile with current project’s config (diff preview);
  3) Enter a different ID.
- Session association: drag from list or via row menu / details editor; optional “suggest archive to project” notification when `cwd` ∈ project roots.
- Launch behavior in Project context: inject `--profile <project.id>`; optional instructions injection via `-c experimental_instructions_file=…` when enabled per project.

---

## Open Decisions (deferred; revisit post-implementation)

- Diff UX: in‑app TOML diff preview widget vs. external diff tool invocation.
- Bridge implementation: shell script vs. tiny binary; start with script, consider binary if security/hardening is required.
- Instructions composition: allow light templating (e.g., project variables) vs. plain markdown; start plain.
- Project-mode sidebar UX: quick filters by profile/model in addition to project list.

---

## Validation & Recovery

- Before write: show diff; create `config.toml.bak` and `projects-v1.json.bak`.
- On failure: rollback and surface toast + error message field on ViewModel.
- Logging: minimal structured logs for config writes and project/profile rename operations.

---

## Task List (trackable)

[] Create `CodexSettingsView` scaffold and navigation entry (top-level Settings page).
[] Implement `CodexConfigService` actor: load/merge/write with minimal diffs and backups.
[] Providers UI: list + radio select; add/edit/delete forms; persistence via service.
[] Sandbox & Approvals defaults: bind to top-level keys; non-blocking validation.
[] Notifications: add TUI toggle and system-bridge toggle; install/point to bridge script.
[] Privacy: `shell_environment_policy` editor + preview; reasoning toggles; OTEL config.
[] Implement `ProjectStore` actor and `projects-v1.json` schema; add CRUD UI.
[] Auto-create/sync Profiles when creating/renaming Projects; conflict dialog flow.
[] InstructionInjector: per-project opt-in injection; temp file lifecycle.
[] Same-root archive suggestion: detector + system notification + one-click action.
[] Update AGENTS.md (UI structure change and rules) and in-app Settings description.
[] Smoke tests on macOS 14+: large session trees; verify first paint + incremental enrichment intact.

---

## Release Notes Draft (for later)

- New: Settings › Codex centralizes Codex CLI configuration.
- New: Provider management with single-select active provider.
- New: System notifications for turn completion via built-in bridge.
- New: Projects auto-create and sync Profiles; optional instructions injection.
- Privacy: environment policy editor and reasoning visibility toggles.
