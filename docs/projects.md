Projects in CodMate (Phase 1)

Overview
- Introduces a virtual “Projects” view to organize Codex sessions conceptually, in addition to the existing physical directory view.
- Projects map to the `projects` group in Codex `config.toml` and can also be assigned per-session.
- Minimal viable goals: list projects, filter sessions by project, create a new project, and assign sessions to a project.

Goals (v1)
- Toggle sidebar middle area between Directories and Projects without changing top “All Sessions” and bottom Calendar.
- Read/write projects from Codex config: `[projects.<id>]` tables holding at least folder path and trust level.
- Allow creating a project (name, folder, trust, overview, instructions, optional profile).
- Assign sessions to a project (context menu; drag-and-drop planned for v1.1).
- When a project is selected, filter the middle session list accordingly.

Non-goals (deferred)
- Automatic profile creation/rename sync.
- Project-scoped overrides of all global runtime settings.
- Cross-session knowledge linking UX; export/minify pipelines.
- Drag-drop from middle list to sidebar project rows (v1.1).

Data Model
- Project (new model):
  - `id: String` – stable identifier used in config/notes
  - `name: String` – display name
  - `directory: String` – absolute path for project root
  - `trustLevel: String?` – e.g., `trusted` | `untrusted` (string passthrough)
  - `overview: String?` – short description
  - `instructions: String?` – default instructions for new sessions
  - `profileId: String?` – optional profile association (future use)

- Session metadata extension (notes JSON per session id):
  - `projectId: String?`
  - `profileId: String?` (reserved)
  - Backward compatible with existing title/comment; missing keys are tolerated.

Persistence
- Projects: Codex config at `~/.codex/config.toml` via `[projects.<id>]` tables.
  - Supported keys: `name`, `directory`, `trust_level`, `overview`, `instructions`, `profile`.
  - We read both `directory` and `path` for compatibility; we write `directory`.
- Session-to-project mapping: stored in notes JSON under `~/.codex/notes/<sessionId>.json` along with title/comment.

View Model Changes
- `SessionListViewModel`
  - New state: `projects: [Project]`, `selectedProjectId: String?`.
  - Loads projects on startup and when config changes.
  - Filters sessions by selected project (matches notes.projectId; directory matching is a future enhancement).
  - New APIs: `assignSessions(to projectId: String, ids: [String])`, `loadProjects()`, `setSelectedProject(_:)`, `clearAllFilters()` resets both path and project.

UI/UX
- Sidebar (left):
  - Top fixed: “All Sessions” row (unchanged). Click clears both path and project filters.
  - Middle scrollable: segmented toggle – “Directories” | “Projects”.
    - Directories: existing Path tree.
    - Projects: list of projects with count badges; “New Project” button.
  - Bottom fixed: calendar month view (unchanged).
  - Only the middle area scrolls. Width rules unchanged.

- Projects list interactions:
  - Click selects project → filters sessions.
  - Context menu on session rows (middle column): “Assign to Project…” flyout that lists projects.
  - “New Project” opens a sheet to input: Name, Directory (choose…), Trust Level, Overview, Instructions, Profile (optional).

CLI Integration (preparation)
- New session from a Project will reuse the project’s directory and (later) its profile/config defaults. For v1, we only expose the project selection and filtering; project-scoped new-session is planned in a follow-up.

Performance
- Projects list is small; reads config once and caches in memory. Writes rewrite only the `projects` region similar to providers.
- Session assignment uses existing notes store; no large scans. Filtering is O(n) over the already-loaded day scope.

Error Handling
- Config I/O surfaced via `SessionListViewModel.errorMessage` and non-blocking alerts.
- Notes writes are best-effort; UI does not crash on failures.

Extensibility (v1.1+)
- Drag-and-drop from middle list to project rows (drop target) to assign sessions.
- Directory inference: if a session’s `cwd` is under a project directory and no explicit assignment exists, consider it in that project (opt-in).
- Project-level overrides for model, reasoning, sandbox/approval flags.
- Auto-create and sync a same-id Profile; conflict prompts.

