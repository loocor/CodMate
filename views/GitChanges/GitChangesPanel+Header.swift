import SwiftUI

extension GitChangesPanel {
  // MARK: - Header view
  var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        // Mode switcher: Diff | History | Explorer (only show when repo exists)
        if vm.repoRoot != nil {
          let items: [SegmentedIconPicker<ReviewPanelState.Mode>.Item] = [
            .init(title: "Diff", systemImage: "doc.text.magnifyingglass", tag: .diff),
            .init(title: "History", systemImage: "clock.arrow.circlepath", tag: .graph),
            .init(title: "Explorer", systemImage: "folder", tag: .browser),
          ]
          SegmentedIconPicker(items: items, selection: $mode)
        }

        let rootURL = vm.repoRoot ?? projectDirectory ?? workingDirectory
        let authorized =
          SecurityScopedBookmarks.shared.isSandboxed
          ? SecurityScopedBookmarks.shared.hasDynamicBookmark(for: rootURL)
          : true
        if vm.repoRoot != nil || explorerRootExists,
          SecurityScopedBookmarks.shared.isSandboxed
        {
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

        Spacer()

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
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.orange.opacity(0.08))
        )
      }
    }
  }
}
