import SwiftUI

struct PathTreeView: View {
    let root: PathTreeNode?
    let onSelect: (String) -> Void

    var body: some View {
        if let root {
            OutlineGroup([root], children: \.children) { node in
                HStack(spacing: 8) {
                    Text(node.name.isEmpty ? "/" : node.name)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if node.count > 0 {
                        Text("\(node.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(node.id) }
                .onTapGesture(count: 2) { onSelect(node.id) }
            }
        } else {
            ContentUnavailableView("暂无目录", systemImage: "folder")
        }
    }
}
