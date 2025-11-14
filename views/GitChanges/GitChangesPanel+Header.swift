import SwiftUI

extension GitChangesPanel {
    // MARK: - Header view
    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Dynamic title and icon based on mode
                let title: String = {
                    switch mode {
                    case .browser: return "Explorer"
                    case .diff: return "Changes"
                    case .graph: return "History"
                    }
                }()
                let icon: String = {
                    switch mode {
                    case .browser: return "folder"
                    case .diff: return "arrow.triangle.branch"
                    case .graph: return "clock"
                    }
                }()
                Label(title, systemImage: icon)
                .font(.headline)
                let rootURL = vm.repoRoot ?? projectDirectory ?? workingDirectory
                let authorized = SecurityScopedBookmarks.shared.isSandboxed
                    ? SecurityScopedBookmarks.shared.hasDynamicBookmark(for: rootURL)
                    : true
                if vm.repoRoot != nil || explorerRootExists {
                    HStack(spacing: 8) {
                        Text(rootURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                        // Inline authorization status + revoke/authorize
                        if SecurityScopedBookmarks.shared.isSandboxed {
                            Button {
                                if authorized {
                                    SecurityScopedBookmarks.shared.removeDynamic(url: rootURL)
                                    NotificationCenter.default.post(name: .codMateRepoAuthorizationChanged, object: nil)
                                } else {
                                    onRequestAuthorization?()
                                }
                            } label: {
                                Image(systemName: authorized ? "checkmark.shield" : "exclamationmark.shield")
                                    .foregroundStyle(authorized ? .green : .orange)
                            }
                            .buttonStyle(.plain)
                            .help(authorized ? "Revoke repository authorization" : "Authorize repository folder…")
                        }
                    }
                }
                Spacer()

                // Mode switcher: Explorer / History / Diff (only show when repo exists)
                if vm.repoRoot != nil {
                    Picker("", selection: $mode) {
                        Text("Explorer").tag(ReviewPanelState.Mode.browser)
                        Text("History").tag(ReviewPanelState.Mode.graph)
                        Text("Diff").tag(ReviewPanelState.Mode.diff)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .controlSize(.small)
                    .labelsHidden()
                }

                // Hidden keyboard shortcut to trigger commit confirmation via ⌘⏎
                Button("") {
                    let msg = vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !msg.isEmpty { showCommitConfirm = true }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            }
            if vm.repoRoot == nil {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Git repository not found. Explorer mode only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            // Moved authorization controls inline in header path; remove separate row
            if let err = vm.errorMessage, !err.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.08))
                )
            }
        }
    }
}
