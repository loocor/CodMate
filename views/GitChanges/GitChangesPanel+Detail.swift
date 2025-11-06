import SwiftUI

extension GitChangesPanel {
    // MARK: - Detail view (diff/preview pane)
    var detailView: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttributedTextView(
                text: vm.diffText.isEmpty
                    ? (vm.selectedPath == nil ? "Select a file to view diff/preview." : (vm.showPreviewInsteadOfDiff ? "(Empty preview)" : "(No diff)"))
                    : vm.diffText,
                isDiff: !vm.showPreviewInsteadOfDiff,
                wrap: wrapText,
                showLineNumbers: showLineNumbers,
                fontSize: 12
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
            )
        }
        .id("detail:\(vm.selectedPath ?? "-")|\(vm.selectedSide == .staged ? "s" : "u")|\(vm.showPreviewInsteadOfDiff ? "p" : "d")|wrap:\(wrapText ? 1 : 0)|ln:\(showLineNumbers ? 1 : 0)")
        .task(id: vm.selectedPath) { await vm.refreshDetail() }
        .task(id: vm.selectedSide) { await vm.refreshDetail() }
        .task(id: vm.showPreviewInsteadOfDiff) { await vm.refreshDetail() }
    }

    // MARK: - Commit box (legacy, for .full presentation)
    var commitBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Commit")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if presentation == .full {
                // Clamp editor height between 1 and 10 lines (≈20pt/line)
                let line: CGFloat = 20
                let minH: CGFloat = line
                let maxH: CGFloat = line * 10
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $vm.commitMessage)
                        .font(.system(.body))
                        .textEditorStyle(.plain)
                        .frame(minHeight: minH)
                        .frame(height: min(maxH, max(minH, commitEditorHeight)))
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                    // Drag handle adjusts preferred editor height within bounds
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 6)
                        .gesture(DragGesture().onChanged { value in
                            let nh = max(minH, min(maxH, commitEditorHeight + value.translation.height))
                            commitEditorHeight = nh
                        })
                    HStack {
                        Spacer()
                        Button("Commit") { showCommitConfirm = true }
                            .disabled(vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    TextField("Press Command+Return to commit", text: $vm.commitMessage)
                    Button("Commit") { showCommitConfirm = true }
                        .disabled(vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(8)
        .background(
            Group {
                if presentation == .embedded {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .underPageBackgroundColor))
                }
            }
        )
        .overlay(
            Group {
                if presentation == .embedded {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15))
                }
            }
        )
    }
}
