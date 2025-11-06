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
            guard newVal == .review else { return }
            ensureRepoAccessForReview()
        }
        .onChange(of: focusedSummary?.id) { _, _ in
            if selectedDetailTab == .review { ensureRepoAccessForReview() }
        }
    }
}
