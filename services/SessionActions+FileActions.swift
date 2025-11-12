import AppKit
import Foundation

extension SessionActions {
    func revealInFinder(session: SessionSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
    }

    func delete(summaries: [SessionSummary]) throws {
        for summary in summaries {
            var resulting: NSURL?
            do {
                try fileManager.trashItem(at: summary.fileURL, resultingItemURL: &resulting)
            } catch {
                throw SessionActionError.deletionFailed(summary.fileURL)
            }

            // For Claude Code sessions, also delete associated agent-*.jsonl files
            if summary.source.baseKind == .claude {
                deleteAssociatedAgentFiles(for: summary)
            }
        }
    }

    /// Delete agent-*.jsonl files associated with a Claude Code session.
    /// Agent files are sidechain warmup files that share the same sessionId.
    private func deleteAssociatedAgentFiles(for summary: SessionSummary) {
        let directory = summary.fileURL.deletingLastPathComponent()
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [URLResourceKey.isRegularFileKey],
            options: [
                FileManager.DirectoryEnumerationOptions.skipsHiddenFiles,
                FileManager.DirectoryEnumerationOptions.skipsSubdirectoryDescendants,
            ]
        ) else { return }

        for case let url as URL in enumerator {
            let filename = url.deletingPathExtension().lastPathComponent
            guard filename.hasPrefix("agent-"),
                  url.pathExtension.lowercased() == "jsonl" else { continue }

            // Check if this agent file belongs to the session being deleted
            if agentFileMatchesSession(agentURL: url, sessionId: summary.id) {
                var resulting: NSURL?
                try? fileManager.trashItem(at: url, resultingItemURL: &resulting)
            }
        }
    }

    /// Check if an agent file belongs to a specific session by reading its sessionId.
    private func agentFileMatchesSession(agentURL: URL, sessionId: String) -> Bool {
        guard let data = try? Data(contentsOf: agentURL, options: [.mappedIfSafe]),
              !data.isEmpty else { return false }

        // Read first line to extract sessionId
        let lines = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true)
        guard let firstLine = lines.first else { return false }

        // Simple JSON check for sessionId (avoid full JSON parsing for performance)
        let lineStr = String(decoding: firstLine, as: UTF8.self)
        return lineStr.contains("\"sessionId\":\"\(sessionId)\"")
    }
}
