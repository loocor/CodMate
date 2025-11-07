import Foundation

struct GitReviewNode: Identifiable, Hashable, Sendable {
    var name: String
    var fullPath: String?
    var dirPath: String?
    var children: [GitReviewNode]? = nil

    var isDirectory: Bool { dirPath != nil }

    var id: String {
        if let dirPath { return "dir:\(dirPath)" }
        if let fullPath { return "file:\(fullPath)" }
        return "node:\(name)"
    }
}

struct GitReviewTreeSnapshot: Equatable, Sendable {
    var staged: [GitReviewNode]
    var unstaged: [GitReviewNode]

    static let empty = GitReviewTreeSnapshot(staged: [], unstaged: [])
}

enum GitReviewTreeBuilder {
    static func buildSnapshot(from changes: [GitService.Change]) -> GitReviewTreeSnapshot {
        let staged = changes.filter { $0.staged != nil }
        // Include all worktree entries (including MM) for unstaged tree
        let unstaged = changes.filter { $0.worktree != nil }
        return GitReviewTreeSnapshot(
            staged: buildTree(from: staged),
            unstaged: buildTree(from: unstaged)
        )
    }

    static func buildTree(from changes: [GitService.Change]) -> [GitReviewNode] {
        struct BuilderNode {
            var children: [String: BuilderNode] = [:]
            var filePath: String?
        }

        var root = BuilderNode()
        for change in changes {
            let components = change.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            func insert(_ index: Int, current: inout BuilderNode) {
                let key = components[index]
                if index == components.count - 1 {
                    var child = current.children[key, default: BuilderNode()]
                    child.filePath = change.path
                    current.children[key] = child
                } else {
                    var child = current.children[key, default: BuilderNode()]
                    insert(index + 1, current: &child)
                    current.children[key] = child
                }
            }

            insert(0, current: &root)
        }

        func convert(_ node: BuilderNode, prefix: String?) -> [GitReviewNode] {
            var output: [GitReviewNode] = []
            for (name, child) in node.children {
                let fullPath = prefix.map { "\($0)/\(name)" } ?? name
                if let filePath = child.filePath, child.children.isEmpty {
                    output.append(GitReviewNode(name: name, fullPath: filePath, dirPath: nil, children: nil))
                } else {
                    let childrenNodes = convert(child, prefix: fullPath)
                    output.append(
                        GitReviewNode(
                            name: name,
                            fullPath: nil,
                            dirPath: fullPath,
                            children: explorerSort(childrenNodes)
                        )
                    )
                }
            }
            return explorerSort(output)
        }

        return convert(root, prefix: nil)
    }

    static func explorerSort(_ nodes: [GitReviewNode]) -> [GitReviewNode] {
        func category(for node: GitReviewNode) -> Int {
            let isDot = node.name.hasPrefix(".")
            if node.isDirectory {
                return isDot ? 1 : 0
            } else {
                return isDot ? 3 : 2
            }
        }
        return nodes.sorted {
            let lhs = category(for: $0)
            let rhs = category(for: $1)
            if lhs != rhs { return lhs < rhs }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
