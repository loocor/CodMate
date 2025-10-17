import Foundation

struct PathTreeNode: Identifiable, Hashable {
    let id: String       // absolute path for uniqueness
    let name: String
    var count: Int
    var children: [PathTreeNode]
}

extension Array where Element == SessionSummary {
    func buildPathTree() -> PathTreeNode? {
        guard !isEmpty else { return nil }
        // Determine common root from all cwd paths
        let paths = self.map { URL(fileURLWithPath: $0.cwd, isDirectory: true).pathComponents }
        let commonPrefix = paths.reduce(paths.first ?? []) { prefix, components in
            Array(zip(prefix, components).prefix { $0.0 == $0.1 }.map { $0.0 })
        }

        let rootPath = commonPrefix.isEmpty ? "/" : commonPrefix.joined(separator: "/")
        let rootID = rootPath.hasPrefix("/") ? rootPath : "/" + rootPath
        var root = PathTreeNode(id: rootID, name: (commonPrefix.last ?? "/"), count: 0, children: [])

        var nodeMap: [String: Int] = [root.id: 0] // id -> index in flat array
        var flat: [PathTreeNode] = [root]

        func ensureNode(pathComponents: [String]) -> Int {
            let fullPath = ("/" + pathComponents.joined(separator: "/")).replacingOccurrences(of: "//", with: "/")
            if let idx = nodeMap[fullPath] { return idx }
            let name = pathComponents.last ?? "/"
            let node = PathTreeNode(id: fullPath, name: name, count: 0, children: [])
            nodeMap[fullPath] = flat.count
            flat.append(node)
            return flat.count - 1
        }

        for s in self {
            let comps = URL(fileURLWithPath: s.cwd, isDirectory: true).pathComponents
            let start = commonPrefix.count
            guard start <= comps.count else { continue }
            var pathSoFar = Array(commonPrefix)
            var parentIdx = 0
            for i in start..<comps.count {
                pathSoFar.append(comps[i])
                let idx = ensureNode(pathComponents: pathSoFar)
                // Link parent->child if not linked yet
                let childID = ("/" + pathSoFar.joined(separator: "/")).replacingOccurrences(of: "//", with: "/")
                if !flat[parentIdx].children.contains(where: { $0.id == childID }) {
                    flat[parentIdx].children.append(flat[idx])
                }
                parentIdx = idx
                // Increase count for each node along the path
                flat[idx].count += 1
            }
            // Increase root count too
            flat[0].count += 1
        }

        // Reconstruct tree from flat map preserving children that were appended with stale copies
        func rebuild(from node: PathTreeNode) -> PathTreeNode {
            var newNode = flat[nodeMap[node.id]!]
            newNode.children = node.children.map { rebuild(from: $0) }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            return newNode
        }

        return rebuild(from: flat[0])
    }
}

