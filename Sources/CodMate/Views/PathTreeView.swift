import SwiftUI

struct PathTreeView: View {
    let root: PathTreeNode?
    let onSelect: (String) -> Void

    var body: some View {
        if let root {
            OutlineGroup([root], children: \.children) { node in
                HStack(spacing: 8) {
                    Text(node.name.isEmpty ? "/" : node.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if node.count > 0 {
                        Text("\(node.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 1)
                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
                .contentShape(Rectangle())
                // 单击保留默认行为（选中/展开），双击才应用筛选
                .onTapGesture(count: 2) { onSelect(node.id) }
            }
        } else {
            ContentUnavailableView("暂无目录", systemImage: "folder")
        }
    }
}
