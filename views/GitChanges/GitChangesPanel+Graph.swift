import SwiftUI

extension GitChangesPanel {
  // MARK: - Graph detail view
  var graphDetailView: some View {
    GraphContainer(vm: graphVM, wrapText: wrapText, showLineNumbers: showLineNumbers)
      .onAppear {
        graphVM.attach(to: vm.repoRoot)
      }
      .onChange(of: vm.repoRoot) { _, newVal in
        graphVM.attach(to: newVal)
      }
  }

  // Host for the graph UI
  struct GraphContainer: View {
    @StateObject var vm: GitGraphViewModel
    let wrapText: Bool
    let showLineNumbers: Bool
    init(vm: GitGraphViewModel, wrapText: Bool, showLineNumbers: Bool) {
      _vm = StateObject(wrappedValue: vm)
      self.wrapText = wrapText
      self.showLineNumbers = showLineNumbers
    }
    @State private var rowHoverId: String? = nil

    var body: some View {
      VStack(spacing: 8) {
        // Controls + full-width commit list (no right-side diff in History mode)
        // Branch scope controls + search
        HStack(spacing: 10) {
          // Branch selector
          HStack(spacing: 6) {
            Text("Branches:")
              .font(.caption)
              .foregroundStyle(.secondary)
            Picker(
              "",
              selection: Binding<String>(
                get: { vm.showAllBranches ? "__all__" : (vm.selectedBranch ?? "__current__") },
                set: { newVal in
                  if newVal == "__all__" {
                    vm.showAllBranches = true
                    vm.selectedBranch = nil
                  } else if newVal == "__current__" {
                    vm.showAllBranches = false
                    vm.selectedBranch = nil
                  } else {
                    vm.showAllBranches = false
                    vm.selectedBranch = newVal
                  }
                  vm.loadCommits()
                })
            ) {
              Text("Show All").tag("__all__")
              Text("Current").tag("__current__")
              Divider()
              ForEach(vm.branches, id: \.self) { name in
                Text(name).tag(name)
              }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
          }
          Toggle("Show Remote Branches", isOn: $vm.showRemoteBranches)
            .onChange(of: vm.showRemoteBranches) { _, _ in
              vm.loadBranches()
              vm.loadCommits()
            }
          Spacer()
          HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search commits", text: $vm.searchQuery)
              .textFieldStyle(.plain)
              .onChange(of: vm.searchQuery) { _, _ in vm.applyFilter() }
          }
          .padding(.vertical, 4)
          .padding(.horizontal, 6)
          .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
          .frame(maxWidth: 260)
        }
        .onChange(of: vm.showAllBranches) { _, _ in vm.loadCommits() }
        // Header row (fixed height, fixed column widths)
        HStack(spacing: 8) {
          Color.clear
            .frame(width: graphColumnWidth)
          Text("Description")
            .foregroundStyle(.secondary)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
          // Date
          Text("Date")
            .foregroundStyle(.secondary)
            .font(.caption)
            .frame(width: dateWidth, alignment: .leading)
          // Author
          Text("Author")
            .foregroundStyle(.secondary)
            .font(.caption)
            .frame(width: authorWidth, alignment: .leading)
          // SHA
          Text("SHA")
            .foregroundStyle(.secondary)
            .font(.caption)
            .frame(width: shaWidth, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
          Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }

        // Rows: zero spacing to keep lane connectors continuous between rows
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(vm.filteredCommits.enumerated()), id: \.element.id) { idx, c in
              HStack(spacing: 8) {
                if let info = vm.laneInfoById[c.id] {
                  GraphLaneView(
                    info: info,
                    maxLanes: vm.maxLaneCount,
                    laneSpacing: laneSpacing,
                    verticalWidth: 2,
                    hideTopForCurrentLane: idx == 0,
                    hideBottomForCurrentLane: idx == vm.filteredCommits.count - 1,
                    headIsHollow: c.id == "::working-tree::",
                    headSize: 12
                  )
                  .frame(width: graphColumnWidth, height: rowHeight)
                } else {
                  GraphGlyph()
                    .frame(width: graphColumnWidth, height: rowHeight)
                }
                // Description cell
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 6) {
                    Text(c.subject)
                      .fontWeight(c.id == "::working-tree::" ? .semibold : .regular)
                      .lineLimit(1)
                      .frame(maxWidth: .infinity, alignment: .leading)
                    // Decorations chips
                    ForEach(c.decorations.prefix(3), id: \.self) { d in
                      Text(d)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                  }
                }
                .padding(.trailing, 8)
                Text(c.date)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .frame(width: dateWidth, alignment: .leading)
                Text(c.author)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .frame(width: authorWidth, alignment: .leading)
                Text(c.shortId)
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .frame(width: shaWidth, alignment: .leading)
              }
              .frame(height: rowHeight)
              .background(rowHoverId == c.id ? Color.accentColor.opacity(0.07) : Color.clear)
              .background((idx % 2 == 1) ? Color.secondary.opacity(0.06) : Color.clear)
              .contentShape(Rectangle())
              .onHover { inside in
                rowHoverId = inside ? c.id : (rowHoverId == c.id ? nil : rowHoverId)
              }
              .onTapGesture { vm.selectCommit(c) }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var graphColumnWidth: CGFloat {
      // Graph column width scales with lanes; lane width equals row height so dot margins match vertically
      return max(rowHeight + 4, CGFloat(max(vm.maxLaneCount, 1)) * laneSpacing)
    }
    private var rowHeight: CGFloat { 24 }
    private var laneSpacing: CGFloat { rowHeight }
    private var dateWidth: CGFloat { 110 }
    private var authorWidth: CGFloat { 120 }
    private var shaWidth: CGFloat { 80 }
  }

  // Monospace-like graph glyph: a vertical line with a centered dot, mimicking a basic lane.
  struct GraphGlyph: View {
    var body: some View {
      ZStack {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).padding(.vertical, 2)
        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }
  // Simple background with alternating horizontal stripes to separate rows visually
  struct StripedBackground: View {
    var stripe: CGFloat = 28
    var body: some View {
      GeometryReader { geo in
        let count = Int(ceil(geo.size.height / max(1, stripe)))
        ZStack(alignment: .topLeading) {
          Color(nsColor: .textBackgroundColor)
          ForEach(0..<max(count, 0), id: \.self) { i in
            if i % 2 == 1 {
              Rectangle()
                .fill(Color.secondary.opacity(0.06))
                .frame(height: stripe)
                .offset(y: CGFloat(i) * stripe)
            }
          }
        }
      }
    }
  }
}

// Renders commit lanes and connectors for a single row.
private struct GraphLaneView: View {
  let info: GitGraphViewModel.LaneInfo
  let maxLanes: Int
  let laneSpacing: CGFloat
  let verticalWidth: CGFloat
  let hideTopForCurrentLane: Bool
  let hideBottomForCurrentLane: Bool
  let headIsHollow: Bool
  let headSize: CGFloat

  private let dotSize: CGFloat = 8
  private let lineWidth: CGFloat = 2

  private func x(_ lane: Int) -> CGFloat {
    CGFloat(lane) * laneSpacing + laneSpacing / 2
  }

  var body: some View {
    GeometryReader { geo in
      let h = max(geo.size.height, 18)

      // Vertical lane segments to maintain continuity across rows
      Path { p in
        let top: CGFloat = 0
        let bottom: CGFloat = h
        let count = max(info.activeLaneCount, maxLanes)
        if count > 0 {
          for i in 0..<count {
            if info.continuingLanes.contains(i) {
              let xi = x(i)
              let dotY = h * 0.5
              // margin to avoid line intruding into hollow ring
              let headRadius: CGFloat =
                headIsHollow && i == info.laneIndex ? max(ceil(headSize / 2), 5) : ceil(dotSize / 2)
              let startBelow: CGFloat = headRadius + 1
              if i == info.laneIndex {
                if hideTopForCurrentLane {
                  // start under the head
                  p.move(to: CGPoint(x: xi, y: dotY + startBelow))
                  if hideBottomForCurrentLane {
                    // draw nothing further; hidden both above and below
                  } else {
                    p.addLine(to: CGPoint(x: xi, y: bottom))
                  }
                } else if hideBottomForCurrentLane {
                  // draw from top to just above the head
                  p.move(to: CGPoint(x: xi, y: top))
                  p.addLine(to: CGPoint(x: xi, y: dotY - startBelow))
                } else {
                  p.move(to: CGPoint(x: xi, y: top))
                  p.addLine(to: CGPoint(x: xi, y: bottom))
                }
              } else if info.parentLaneIndices.contains(i) {
                // For lanes that are only reached via branch connectors on this row,
                // skip vertical segment here so only the diagonal branch is visible.
                continue
              } else {
                p.move(to: CGPoint(x: xi, y: top))
                p.addLine(to: CGPoint(x: xi, y: bottom))
              }
            }
          }
        }
      }
      .stroke(Color.accentColor.opacity(0.6), lineWidth: max(0.5, verticalWidth))

      // Connectors from current dot to parent lanes (downward curves); only draw diagonals
      Path { p in
        if !hideBottomForCurrentLane {
          let cx = x(info.laneIndex)
          let dotY = h * 0.5
          let startY: CGFloat = {
            if headIsHollow { return dotY + CGFloat(max(ceil(headSize / 2), 5)) + 1 }
            return dotY
          }()
          for parent in info.parentLaneIndices where parent != info.laneIndex {
            let px = x(parent)
            p.move(to: CGPoint(x: cx, y: startY))
            // Smooth S-shaped curve toward bottom at parent lane position
            let c1 = CGPoint(x: cx, y: startY + h * 0.25)
            let c2 = CGPoint(x: px, y: h - h * 0.25)
            p.addCurve(to: CGPoint(x: px, y: h), control1: c1, control2: c2)
          }
        }
      }
      .stroke(Color.accentColor.opacity(0.6), lineWidth: lineWidth)

      // Commit dot
      Group {
        if headIsHollow {
          Circle()
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: headSize, height: headSize)
        } else {
          Circle()
            .fill(Color.accentColor)
            .frame(width: dotSize, height: dotSize)
        }
      }
      .position(x: x(info.laneIndex), y: h * 0.5)
    }
  }
}

// ColumnResizer removed: columns use fixed widths; Description fills remaining space.
