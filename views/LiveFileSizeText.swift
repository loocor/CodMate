import SwiftUI

/// Shows a session file's size and refreshes on file system events only.
struct LiveFileSizeText: View {
    let url: URL

    @State private var text: String = "—"
    @State private var monitor: DirectoryMonitor? = nil

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .onAppear { start() }
            .onDisappear { stop() }
            .task(id: url) { restart() }
            .help("Current session file size")
    }

    private func restart() {
        stop(); start()
    }

    private func start() {
        // Event-driven: refresh on writes/renames/deletes/extend
        monitor?.cancel()
        monitor = DirectoryMonitor(url: url) { [weak _monitor = monitor] in
            // UI updates must happen on main thread
            Task { @MainActor in refresh() }
        }
        // Initial paint
        refresh()
    }

    private func stop() {
        monitor?.cancel(); monitor = nil
    }

    private func refresh() {
        text = fileSize(url).map(formatBytes) ?? "—"
    }

    private func fileSize(_ url: URL) -> UInt64? {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let number = attrs[.size] as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
