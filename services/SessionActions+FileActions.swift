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
        }
    }
}
