import Foundation

struct PathTreeNode: Identifiable, Hashable {
    let id: String       // absolute path for uniqueness
    let name: String
    var count: Int
    var children: [PathTreeNode]? // OutlineGroup expects optional children
}

extension Array where Element == SessionSummary {
    func buildPathTree() -> PathTreeNode? {
        guard !isEmpty else { return nil }
        // Determine common root from all cwd paths
        let paths: [[String]] = self.map { URL(fileURLWithPath: $0.cwd, isDirectory: true).pathComponents }

        func commonPrefixPathComponents(_ arrays: [[String]]) -> [String] {
            guard var prefix = arrays.first else { return [] }
            for comps in arrays.dropFirst() {
                let n = Swift.min(prefix.count, comps.count)
                var i = 0
                while i < n, prefix[i] == comps[i] { i += 1 }
                prefix = [String](prefix.prefix(i))
                if prefix.isEmpty { break }
            }
            return prefix
        }

        let commonPrefix = commonPrefixPathComponents(paths)

        let rootPath: String = commonPrefix.isEmpty ? "/" : NSString.path(withComponents: commonPrefix)
        let rootID = rootPath
        let rootName = commonPrefix.last ?? "/"
        let root = PathTreeNode(id: rootID, name: rootName.isEmpty ? "/" : rootName, count: 0, children: [])

        var nodeMap: [String: Int] = [root.id: 0] // id -> index in flat array
        var flat: [PathTreeNode] = [root]

        func ensureNode(pathComponents: [String]) -> Int {
            let fullPath = NSString.path(withComponents: pathComponents)
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
            var pathSoFar = [String](commonPrefix)
            var parentIdx = 0
            for i in start..<comps.count {
                pathSoFar.append(comps[i])
                let idx = ensureNode(pathComponents: pathSoFar)
                // Link parent->child if not linked yet
                let childNode = flat[idx] // Copy to local variable to avoid overlapping access
                if flat[parentIdx].children == nil { flat[parentIdx].children = [] }
                if !(flat[parentIdx].children?.contains(where: { $0.id == childNode.id }) ?? false) {
                    flat[parentIdx].children?.append(childNode)
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
            let rebuilt = (node.children ?? []).map { rebuild(from: $0) }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            newNode.children = rebuilt.isEmpty ? nil : rebuilt
            return newNode
        }

        return rebuild(from: flat[0])
    }
}
