import SwiftUI

struct PathTreeView: View {
    let root: PathTreeNode?
    let onSelect: (String) -> Void

    var body: some View {
        if let root {
            OutlineGroup([root], children: \.children) { node in
                HStack {
                    Text(node.name.isEmpty ? "/" : node.name)
                    Spacer()
                    Text("\(node.count)").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect(node.id) }
            }
        } else {
            ContentUnavailableView("暂无目录", systemImage: "folder")
        }
    }
}

