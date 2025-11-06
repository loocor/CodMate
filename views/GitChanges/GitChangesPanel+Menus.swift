import SwiftUI

// MARK: - Lightweight menu list for popovers
struct PopMenuItem: Identifiable {
    enum Role { case normal, destructive }
    let id = UUID()
    var title: String
    var role: Role = .normal
    var action: () -> Void
}

struct PopMenuList: View {
    var items: [PopMenuItem]
    var tail: [PopMenuItem] = [] // optional trailing group separated by a divider
    @State private var hovered: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            groupView(items)
            if !tail.isEmpty {
                Divider().padding(.vertical, 4)
                groupView(tail)
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private func groupView(_ group: [PopMenuItem]) -> some View {
        ForEach(group) { item in
            Button(action: item.action) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .foregroundStyle(item.role == .destructive ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
        }
    }
}
