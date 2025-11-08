import Foundation

// Actor to maintain an incrementally updatable directory tree built from cwd counts.
actor PathTreeStore {
  private var root: PathTreeNode? = nil
  private var rootPrefix: [String] = []

  func currentRoot() -> PathTreeNode? { root }

  func applySnapshot(counts: [String: Int]) -> PathTreeNode? {
    guard !counts.isEmpty else {
      root = nil
      rootPrefix = []
      return nil
    }
    let newRoot = counts.buildPathTreeFromCounts()
    root = newRoot
    if let id = newRoot?.id {
      rootPrefix = URL(fileURLWithPath: id, isDirectory: true).pathComponents
    } else {
      rootPrefix = []
    }
    return root
  }

  // Apply a delta map: path -> +/- count. Returns nil if a rebuild is required.
  func applyDelta(_ delta: [String: Int]) -> PathTreeNode? {
    guard !delta.isEmpty else { return root }
    guard var current = root else {
      // Nothing to update incrementally; signal rebuild
      return nil
    }

    func isPrefix(_ prefix: [String], of array: [String]) -> Bool {
      guard prefix.count <= array.count else { return false }
      if prefix.isEmpty { return true }
      let slice = Array(array.prefix(prefix.count))
      return slice.elementsEqual(prefix)
    }

    // Verify all paths stay within the same root prefix; otherwise request rebuild
    for (path, _) in delta {
      let comps = URL(fileURLWithPath: path, isDirectory: true).pathComponents
      if !isPrefix(rootPrefix, of: comps) {
        return nil
      }
    }

    // Mutating helpers
    func ensureChildren(_ node: inout PathTreeNode) {
      if node.children == nil { node.children = [] }
    }

    func buildChain(from current: PathTreeNode, components: [String], startIndex: Int, delta: Int) -> PathTreeNode {
      var node = current
      var pathSoFar = URL(fileURLWithPath: node.id, isDirectory: true).pathComponents
      for i in startIndex..<components.count {
        pathSoFar.append(components[i])
        let id = NSString.path(withComponents: pathSoFar)
        ensureChildren(&node)
        var child = PathTreeNode(id: id, name: components[i], count: 0, children: [])
        child.count += delta
        node.children?.append(child)
        node.count += delta
        node = child
      }
      return current
    }

    func updatedNode(_ node: PathTreeNode, components: [String], index: Int, delta: Int) -> PathTreeNode? {
      var n = node
      n.count += delta
      if index >= components.count { return n }

      let nextName = components[index]
      let targetId = NSString.path(withComponents: Array(URL(fileURLWithPath: n.id, isDirectory: true).pathComponents + [nextName]))
      ensureChildren(&n)
      if let idx = n.children?.firstIndex(where: { $0.id == targetId }) {
        if let childUpdated = updatedNode(n.children![idx], components: components, index: index + 1, delta: delta) {
          n.children![idx] = childUpdated
        } else {
          return nil
        }
      } else {
        // Missing intermediate node: request a rebuild instead of creating deep chains here
        return nil
      }

      // Prune zero-count children without descendants
      if var kids = n.children {
        kids.removeAll { $0.count <= 0 && ($0.children == nil || $0.children!.isEmpty) }
        n.children = kids.isEmpty ? nil : kids
      }
      return n
    }

    // Apply each delta, bailing out if any update fails
    for (path, d) in delta {
      if d == 0 { continue }
      let comps = URL(fileURLWithPath: path, isDirectory: true).pathComponents
      guard let updated = updatedNode(current, components: comps, index: rootPrefix.count, delta: d) else { return nil }
      current = updated
    }
    // All deltas applied successfully
    root = current
    return root
  }
}
