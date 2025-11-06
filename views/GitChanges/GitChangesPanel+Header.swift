import SwiftUI

extension GitChangesPanel {
    // MARK: - Header view
    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Changes", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                if let rootURL = vm.repoRoot {
                    let authorized = SecurityScopedBookmarks.shared.isSandboxed
                        ? SecurityScopedBookmarks.shared.hasDynamicBookmark(for: rootURL)
                        : true
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
                if mode == .diff {
                    Picker("", selection: $vm.showPreviewInsteadOfDiff) {
                        Text("Diff").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 116)
                    .controlSize(.small)
                    .labelsHidden()
                }

                // (wand button moved into commit message box overlay)

                // Hidden keyboard shortcut to trigger commit confirmation via ⌘⏎
                Button("") {
                    let msg = vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !msg.isEmpty { showCommitConfirm = true }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)

                Button {
                    Task { await vm.refreshStatus() }
                } label: {
                    Image(systemName: vm.isLoading ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
