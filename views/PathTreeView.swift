import SwiftUI

struct PathTreeView: View {
    let root: PathTreeNode?
    @Binding var selectedPath: String?

    var body: some View {
        if let root, let children = root.children, !children.isEmpty {
            List(selection: $selectedPath) {
                OutlineGroup(children, children: \.children) { node in
                    PathTreeRowView(node: node)
                        .tag(node.id)
                        .listRowInsets(EdgeInsets())  // Let internal padding manage spacing
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 16)
            .environment(\.controlSize, .small)
        } else {
            ContentUnavailableView("No Directories", systemImage: "folder")
        }
    }
}

private struct PathTreeRowView: View, Equatable {
    let node: PathTreeNode

    static func == (lhs: PathTreeRowView, rhs: PathTreeRowView) -> Bool {
        lhs.node == rhs.node
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .font(.caption)

            Text(node.name.isEmpty ? "/" : node.name)
                .font(.caption)
                .lineLimit(1)

            Spacer(minLength: 4)

            if node.count > 0 {
                Text("\(node.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 16)
        .padding(.vertical, 8)  // Match All Sessions row vertical padding
        .padding(.trailing, 8)  // Ensure right padding consistent; no extra leading padding
        .contentShape(Rectangle())
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

    return PathTreeView(root: mockRoot, selectedPath: .constant(nil))
        .frame(width: 250, height: 300)
        .padding()
}

#Preview("Empty State") {
    PathTreeView(root: nil, selectedPath: .constant(nil))
        .frame(width: 250, height: 200)
        .padding()
}
