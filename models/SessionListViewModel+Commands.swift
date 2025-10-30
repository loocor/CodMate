import AppKit
import Foundation

@MainActor
extension SessionListViewModel {
    func resume(session: SessionSummary) async -> Result<ProcessResult, Error> {
        do {
            let result = try await actions.resume(
                session: session,
                executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func preferredExecutableURL(for source: SessionSource) -> URL {
        switch source {
        case .codex: return preferences.codexExecutableURL
        case .claude: return preferences.claudeExecutableURL
        }
    }

    func copyResumeCommands(session: SessionSummary) {
        actions.copyResumeCommands(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions,
            simplifiedForExternal: true
        )
    }

    func copyResumeCommandsRespectingProject(session: SessionSummary) {
        if session.source != .codex {
            actions.copyResumeCommands(
                session: session,
                executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions,
                simplifiedForExternal: true
            )
            return
        }
        if let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            actions.copyResumeUsingProjectProfileCommands(
                session: session, project: p,
                executableURL: preferredExecutableURL(for: .codex),
                options: preferences.resumeOptions)
        } else {
            actions.copyResumeCommands(
                session: session,
                executableURL: preferredExecutableURL(for: .codex),
                options: preferences.resumeOptions, simplifiedForExternal: true)
        }
    }

    func openInTerminal(session: SessionSummary) -> Bool {
        actions.openInTerminal(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions)
    }

    func buildResumeCommands(session: SessionSummary) -> String {
        actions.buildResumeCommandLines(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions
        )
    }

    func buildExternalResumeCommands(session: SessionSummary) -> String {
        actions.buildExternalResumeCommands(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions
        )
    }

    func buildResumeCLIInvocation(session: SessionSummary) -> String {
        let execPath =
            actions.resolveExecutableURL(
                preferred: preferredExecutableURL(for: session.source),
                executableName: session.source == .codex ? "codex" : "claude")?.path
            ?? preferredExecutableURL(for: session.source).path
        return actions.buildResumeCLIInvocation(
            session: session,
            executablePath: execPath,
            options: preferences.resumeOptions
        )
    }

    func buildResumeCLIInvocationRespectingProject(session: SessionSummary) -> String {
        if session.source == .codex,
            let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            let execPath =
                actions.resolveExecutableURL(
                    preferred: preferredExecutableURL(for: .codex), executableName: "codex")?.path
                ?? preferredExecutableURL(for: .codex).path
            return actions.buildResumeUsingProjectProfileCLIInvocation(
                session: session, project: p, executablePath: execPath,
                options: preferences.resumeOptions)
        }
        let execPath =
            actions.resolveExecutableURL(
                preferred: preferredExecutableURL(for: session.source),
                executableName: session.source == .codex ? "codex" : "claude")?.path
            ?? preferredExecutableURL(for: session.source).path
        return actions.buildResumeCLIInvocation(
            session: session, executablePath: execPath, options: preferences.resumeOptions)
    }

    func copyNewSessionCommands(session: SessionSummary) {
        actions.copyNewSessionCommands(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions
        )
    }

    func buildNewSessionCLIInvocation(session: SessionSummary) -> String {
        actions.buildNewSessionCLIInvocation(
            session: session,
            options: preferences.resumeOptions
        )
    }

    func openNewSession(session: SessionSummary) {
        _ = actions.openNewSession(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions
        )
    }

    func buildNewProjectCLIInvocation(project: Project) -> String {
        actions.buildNewProjectCLIInvocation(project: project, options: preferences.resumeOptions)
    }

    func copyNewProjectCommands(project: Project) {
        actions.copyNewProjectCommands(
            project: project,
            executableURL: preferredExecutableURL(for: .codex),
            options: preferences.resumeOptions
        )
    }

    /// Unified Project "New Session" entry. Respects embedded/external preference
    /// to reduce branching between Sidebar and Detail flows.
    func newSession(project: Project) {
        // Record intent so the new session can be auto-assigned to this project
        recordIntentForProjectNew(project: project)

        if preferences.defaultResumeUseEmbeddedTerminal {
            // Embedded terminal path: signal ContentView to start an embedded
            // shell anchored to this project and perform targeted refresh.
            pendingEmbeddedProjectNew = project
            setIncrementalHintForCodexToday()
            // Also broadcast a notification for robustness across views
            NotificationCenter.default.post(
                name: .codMateStartEmbeddedNewProject,
                object: nil,
                userInfo: ["projectId": project.id]
            )
            Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Starting embedded New…") }
            return
        }

        // External terminal path: copy command and open preferred terminal.
        actions.copyNewProjectCommands(
            project: project,
            executableURL: preferredExecutableURL(for: .codex),
            options: preferences.resumeOptions
        )

        // Resolve preferred external terminal and open at the project directory
        let app = preferences.defaultResumeExternalApp
        let dir: String = {
            let d = (project.directory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return d.isEmpty ? NSHomeDirectory() : d
        }()

        switch app {
        case .iterm2:
            // Build inline invocation for iTerm scheme and launch directly
            let cmd = actions.buildNewProjectCLIInvocation(project: project, options: preferences.resumeOptions)
            openPreferredTerminalViaScheme(app: .iterm2, directory: dir, command: cmd)
        case .warp:
            // Warp scheme cannot run a command; open path only and rely on clipboard
            openPreferredTerminalViaScheme(app: .warp, directory: dir)
        case .terminal:
            // Fallback: open Apple Terminal at directory; user pastes from clipboard
            _ = openAppleTerminal(at: dir)
        case .none:
            break
        }

        // Friendly nudge so users know the command was placed on clipboard
        Task {
            await SystemNotifier.shared.notify(
                title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
        }

        // Event-driven incremental refresh hint + proactive targeted refresh for today
        setIncrementalHintForCodexToday()
        Task { await self.refreshIncrementalForNewCodexToday() }
    }

    /// Build CLI invocation, respecting project profile if applicable.
    /// - Parameters:
    ///   - session: Session to launch.
    ///   - initialPrompt: Optional initial prompt text to pass to CLI.
    /// - Returns: Complete CLI command string.
    func buildNewSessionCLIInvocationRespectingProject(
        session: SessionSummary,
        initialPrompt: String? = nil
    ) -> String {
        if session.source == .codex,
            let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            return actions.buildNewSessionUsingProjectProfileCLIInvocation(
                session: session,
                project: p,
                options: preferences.resumeOptions,
                initialPrompt: initialPrompt)
        }
        return actions.buildNewSessionCLIInvocation(
            session: session,
            options: preferences.resumeOptions,
            initialPrompt: initialPrompt)
    }

    func copyNewSessionCommandsRespectingProject(session: SessionSummary) {
        if session.source == .codex,
            let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            actions.copyNewSessionUsingProjectProfileCommands(
                session: session, project: p, executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions)
        } else {
            actions.copyNewSessionCommands(
                session: session,
                executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions)
        }
    }

    func copyNewSessionCommandsRespectingProject(session: SessionSummary, initialPrompt: String) {
        if session.source == .codex,
            let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            actions.copyNewSessionUsingProjectProfileCommands(
                session: session, project: p, executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions, initialPrompt: initialPrompt)
        } else {
            let cmd = actions.buildNewSessionCLIInvocation(
                session: session, options: preferences.resumeOptions, initialPrompt: initialPrompt)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cmd + "\n", forType: .string)
        }
    }

    func openNewSessionRespectingProject(session: SessionSummary) {
        if session.source == .codex,
            let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            _ = actions.openNewSessionUsingProjectProfile(
                session: session, project: p, executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions)
        } else {
            _ = actions.openNewSession(
                session: session,
                executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions)
        }
    }

    func openNewSessionRespectingProject(session: SessionSummary, initialPrompt: String) {
        if session.source == .codex,
            let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            _ = actions.openNewSessionUsingProjectProfile(
                session: session, project: p, executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions, initialPrompt: initialPrompt)
        } else {
            _ = actions.openNewSession(
                session: session,
                executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions)
        }
    }

    func projectIdForSession(_ id: String) -> String? {
        projectMemberships[id]
    }

    func projectForId(_ id: String) async -> Project? {
        await projectsStore.getProject(id: id)
    }

    func allowedSources(for session: SessionSummary) -> [ProjectSessionSource] {
        if let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid })
        {
            let allowed = p.sources.isEmpty ? ProjectSessionSource.allSet : p.sources
            return Array(allowed).sorted { $0.displayName < $1.displayName }
        }
        return ProjectSessionSource.allCases
    }

    func copyRealResumeCommand(session: SessionSummary) {
        actions.copyRealResumeInvocation(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions
        )
    }

    func openWarpLaunch(session: SessionSummary) {
        _ = actions.openWarpLaunchConfig(session: session, options: preferences.resumeOptions)
    }

    func openPreferredTerminal(app: TerminalApp) {
        actions.openTerminalApp(app)
    }

    func openPreferredTerminalViaScheme(app: TerminalApp, directory: String, command: String? = nil) {
        actions.openTerminalViaScheme(app, directory: directory, command: command)
    }

    func openAppleTerminal(at directory: String) -> Bool {
        actions.openAppleTerminal(at: directory)
    }
}
