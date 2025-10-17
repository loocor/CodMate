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
