import SwiftUI

extension ContentView {
    // Extracted to reduce ContentView.swift size
    var mainDetailContent: some View {
        Group {
            // Priority 1: explicit Git Review tab
            if selectedDetailTab == .review, let focused = focusedSummary, let ws = focusedSummary.map({ workingDirectory(for: $0) }) {
                GitChangesPanel(
                    workingDirectory: URL(fileURLWithPath: ws, isDirectory: true),
                    presentation: .full,
                    preferences: viewModel.preferences,
                    onRequestAuthorization: { ensureRepoAccessForReview() },
                    savedState: Binding<ReviewPanelState>(
                        get: { viewModel.reviewPanelStates[focused.id] ?? ReviewPanelState() },
                        set: { viewModel.reviewPanelStates[focused.id] = $0 }
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                // Non-review paths: either Terminal tab or Timeline
                #if canImport(SwiftTerm) && !APPSTORE
                if selectedDetailTab == .terminal, let anchorId = fallbackRunningAnchorId() {
                    let isConsole = viewModel.preferences.useEmbeddedCLIConsole
                    let host = TerminalHostView(
                        terminalKey: anchorId,
                        initialCommands: embeddedInitialCommands[anchorId] ?? "",
                        consoleSpec: isConsole ? consoleSpecForAnchor(anchorId) : nil,
                        font: makeTerminalFont(),
                        cursorStyleOption: viewModel.preferences.terminalCursorStyleOption,
                        isDark: colorScheme == .dark
                    )
                    host
                        .id(anchorId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                } else if selectedDetailTab == .terminal, let focused = focusedSummary, runningSessionIDs.contains(focused.id) {
                    let isConsole = viewModel.preferences.useEmbeddedCLIConsole
                    let host = TerminalHostView(
                        terminalKey: focused.id,
                        initialCommands: embeddedInitialCommands[focused.id]
                            ?? viewModel.buildResumeCommands(session: focused),
                        consoleSpec: isConsole ? consoleSpecForResume(focused) : nil,
                        font: makeTerminalFont(),
                        cursorStyleOption: viewModel.preferences.terminalCursorStyleOption,
                        isDark: colorScheme == .dark
                    )
                    host
                        .id(focused.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                } else if let focused = focusedSummary {
                    SessionDetailView(
                        summary: focused,
                        isProcessing: isPerformingAction,
                        onResume: {
                            guard let current = focusedSummary else { return }
                            #if APPSTORE
                            openPreferredExternal(for: current)
                            #else
                            if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                                startEmbedded(for: current)
                            } else {
                                openPreferredExternal(for: current)
                            }
                            #endif
                        },
                        onReveal: {
                            guard let current = focusedSummary else { return }
                            viewModel.reveal(session: current)
                        },
                        onDelete: presentDeleteConfirmation,
                        columnVisibility: $columnVisibility
                    )
                    .environmentObject(viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    placeholder
                }
                #else
                if selectedDetailTab == .terminal, let focused = focusedSummary {
                    // Terminal tab requested but SwiftTerm unavailable in this build → fallback to detail
                    SessionDetailView(
                        summary: focused,
                        isProcessing: isPerformingAction,
                        onResume: {
                            guard let current = focusedSummary else { return }
                            #if APPSTORE
                            openPreferredExternal(for: current)
                            #else
                            if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                                startEmbedded(for: current)
                            } else {
                                openPreferredExternal(for: current)
                            }
                            #endif
                        },
                        onReveal: {
                            guard let current = focusedSummary else { return }
                            viewModel.reveal(session: current)
                        },
                        onDelete: presentDeleteConfirmation,
                        columnVisibility: $columnVisibility
                    )
                    .environmentObject(viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let focused = focusedSummary {
                    SessionDetailView(
                        summary: focused,
                        isProcessing: isPerformingAction,
                        onResume: {
                            guard let current = focusedSummary else { return }
                            #if APPSTORE
                            openPreferredExternal(for: current)
                            #else
                            if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                                startEmbedded(for: current)
                            } else {
                                openPreferredExternal(for: current)
                            }
                            #endif
                        },
                        onReveal: {
                            guard let current = focusedSummary else { return }
                            viewModel.reveal(session: current)
                        },
                        onDelete: presentDeleteConfirmation,
                        columnVisibility: $columnVisibility
                    )
                    .environmentObject(viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    placeholder
                }
                #endif
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .codMateTerminalExited)) { note in
            guard let info = note.userInfo as? [String: Any],
                  let key = info["sessionID"] as? String,
                  !key.isEmpty else { return }
            let exitCode = info["exitCode"] as? Int32
            print("[EmbeddedTerminal] Process for \(key) terminated, exitCode=\(exitCode.map(String.init) ?? "nil")")
            if runningSessionIDs.contains(key) {
                stopEmbedded(forID: key)
            }
        }
    }
}
