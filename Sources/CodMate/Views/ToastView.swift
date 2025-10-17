import SwiftUI

struct ToastView: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .foregroundStyle(.primary)
            Button(role: .cancel) {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .frame(maxWidth: 420)
    }
}

#Preview {
    ToastView(
        text: "Session saved to local storage successfully",
        onDismiss: { print("Toast dismissed") }
    )
    .padding()
}

#Preview("Long Message") {
    ToastView(
        text: "This is a longer message to test the Toast component layout with multiple lines. The content should wrap correctly and remain readable.",
        onDismiss: { print("Long toast dismissed") }
    )
    .padding()
}

#Preview("Short Message") {
    ToastView(
        text: "Operation completed",
        onDismiss: { print("Short toast dismissed") }
    )
    .padding()
}
