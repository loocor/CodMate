import SwiftUI

/// Shared container for settings tab panes to ensure consistent padding and top alignment.
struct SettingsTabContent<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder _ content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

