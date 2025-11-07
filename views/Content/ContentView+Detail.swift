import SwiftUI

extension ContentView {
    var detailColumn: some View {
        VStack(spacing: 0) {
            detailActionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            mainDetailContent
                .animation(nil, value: isListHidden)
        }
        .onChange(of: selectedDetailTab) { _, newVal in
            // Save current session's tab state
            if let focused = focusedSummary {
                sessionDetailTabs[focused.id] = newVal
            }
            if newVal == .review {
                ensureRepoAccessForReview()
            }
        }
        .onChange(of: focusedSummary?.id) { _, newId in
            // Restore new session's tab state
            if let newId = newId {
                selectedDetailTab = sessionDetailTabs[newId] ?? .timeline
            }
            if selectedDetailTab == .review { ensureRepoAccessForReview() }
            normalizeDetailTabForTerminalAvailability()
        }
        .onChange(of: runningSessionIDs) { _, _ in
            normalizeDetailTabForTerminalAvailability()
            synchronizeSelectedTerminalKey()
        }
    }
}
