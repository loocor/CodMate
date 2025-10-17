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
        text: "会话已成功保存到本地存储",
        onDismiss: { print("Toast dismissed") }
    )
    .padding()
}

#Preview("Long Message") {
    ToastView(
        text: "这是一个较长的提示消息，用于测试 Toast 组件在显示多行文本时的布局效果。消息内容应该能够正确换行并保持良好的可读性。",
        onDismiss: { print("Long toast dismissed") }
    )
    .padding()
}

#Preview("Short Message") {
    ToastView(
        text: "操作完成",
        onDismiss: { print("Short toast dismissed") }
    )
    .padding()
}
