import SwiftUI

struct PathTreeView: View {
    let root: PathTreeNode?
    let onSelect: (String) -> Void

    var body: some View {
        if let root {
            ForEach(root.children ?? [root], id: \.id) { node in
                PathTreeNodeView(node: node, level: 0, onSelect: onSelect)
            }
        } else {
            ContentUnavailableView("暂无目录", systemImage: "folder")
        }
    }
}

private struct PathTreeNodeView: View {
    let node: PathTreeNode
    let level: Int
    let onSelect: (String) -> Void

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if let children = node.children, !children.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer()
                        .frame(width: 12)
                }

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
            .padding(.leading, CGFloat(level * 12))
            .padding(.vertical, 1)
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onSelect(node.id)
            }

            if isExpanded, let children = node.children {
                ForEach(children, id: \.id) { child in
                    PathTreeNodeView(node: child, level: level + 1, onSelect: onSelect)
                }
            }
        }
    }
}

#Preview {
    // Mock path tree data
    let mockRoot = PathTreeNode(
        id: "/Users/developer",
        name: "developer",
        count: 15,
        children: [
            PathTreeNode(
                id: "/Users/developer/projects",
                name: "projects",
                count: 8,
                children: [
                    PathTreeNode(
                        id: "/Users/developer/projects/codmate", name: "codmate", count: 3,
                        children: nil),
                    PathTreeNode(
                        id: "/Users/developer/projects/other", name: "other", count: 5,
                        children: nil),
                ]
            ),
            PathTreeNode(
                id: "/Users/developer/documents",
                name: "documents",
                count: 4,
                children: [
                    PathTreeNode(
                        id: "/Users/developer/documents/notes", name: "notes", count: 2,
                        children: nil),
                    PathTreeNode(
                        id: "/Users/developer/documents/reports", name: "reports", count: 2,
                        children: nil),
                ]
            ),
            PathTreeNode(id: "/Users/developer/desktop", name: "desktop", count: 3, children: nil),
        ]
    )

    return PathTreeView(root: mockRoot) { selectedPath in
        print("Selected path: \(selectedPath)")
    }
    .frame(width: 250, height: 300)
    .padding()
}

#Preview("Empty State") {
    PathTreeView(root: nil) { selectedPath in
        print("Selected path: \(selectedPath)")
    }
    .frame(width: 250, height: 200)
    .padding()
}
