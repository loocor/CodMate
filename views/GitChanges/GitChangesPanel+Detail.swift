import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

extension GitChangesPanel {
    // MARK: - Detail view (diff/preview pane)
    var detailView: some View {
        detailContainer {
            if mode == .graph {
                graphDetailView
            } else if let path = vm.selectedPath, isImagePath(path) {
                imagePreviewContent
            } else {
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
            }
        }
        .id("detail:\(vm.selectedPath ?? "-")|\(vm.selectedSide == .staged ? "s" : "u")|\(vm.showPreviewInsteadOfDiff ? "p" : "d")|wrap:\(wrapText ? 1 : 0)|ln:\(showLineNumbers ? 1 : 0)")
        .task(id: vm.selectedPath) {
            await vm.refreshDetail()
            loadPreviewImageIfNeeded()
        }
        .task(id: vm.selectedSide) { await vm.refreshDetail() }
        .task(id: vm.showPreviewInsteadOfDiff) {
            await vm.refreshDetail()
            loadPreviewImageIfNeeded()
        }
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

    private func detailContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
            )
    }

#if canImport(AppKit)
    private var imagePreviewContent: some View {
        GeometryReader { geo in
            ZStack {
                if let image = previewImage {
                    let size = image.size
                    let widthScale = geo.size.width / max(size.width, 1)
                    let heightScale = geo.size.height / max(size.height, 1)
                    let scale = min(1.0, min(widthScale, heightScale))
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width * scale, height: size.height * scale)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func loadPreviewImageIfNeeded() {
        previewImageTask?.cancel()
        previewImage = nil
        guard let root = vm.repoRoot,
              let path = vm.selectedPath,
              isImagePath(path)
        else { return }
        let url = root.appendingPathComponent(path)
        previewImageTask = Task {
            let image = NSImage(contentsOf: url)
            if Task.isCancelled { return }
            await MainActor.run {
                previewImage = image
            }
        }
    }
#else
    private var imagePreviewContent: some View {
        Color.clear
    }

    func loadPreviewImageIfNeeded() {}
#endif
}
