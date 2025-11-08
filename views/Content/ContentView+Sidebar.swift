import SwiftUI

extension ContentView {
  func sidebarContent(sidebarMaxWidth: CGFloat) -> some View {
    let state = viewModel.sidebarStateSnapshot
    let digest = makeSidebarDigest(for: state)
    return EquatableSidebarContainer(key: digest) {
      SessionNavigationView(
        state: state,
        actions: makeSidebarActions()
      ) {
        ProjectsListView()
          .environmentObject(viewModel)
      }
      .navigationSplitViewColumnWidth(min: 260, ideal: 260, max: 260)
    }
    .sheet(isPresented: $showSidebarNewProjectSheet) {
      ProjectEditorSheet(isPresented: $showSidebarNewProjectSheet, mode: .new)
        .environmentObject(viewModel)
    }
  }

  var listContent: some View {
    SessionListColumnView(
      sections: viewModel.sections,
      selection: $selection,
      sortOrder: $viewModel.sortOrder,
      isLoading: viewModel.isLoading,
      isEnriching: viewModel.isEnriching,
      enrichmentProgress: viewModel.enrichmentProgress,
      enrichmentTotal: viewModel.enrichmentTotal,
      onResume: resumeFromList,
      onReveal: { viewModel.reveal(session: $0) },
      onDeleteRequest: handleDeleteRequest,
      onExportMarkdown: exportMarkdownForSession,
      isRunning: { runningSessionIDs.contains($0.id) },
      isUpdating: { viewModel.isActivelyUpdating($0.id) },
      isAwaitingFollowup: { viewModel.isAwaitingFollowup($0.id) },
      onPrimarySelect: { s in selectionPrimaryId = s.id }
    )
    .id(isListHidden ? "list-hidden" : "list-shown")
    .environmentObject(viewModel)
    .navigationSplitViewColumnWidth(
      min: isListHidden ? 0 : 360,
      ideal: isListHidden ? 0 : 420,
      max: isListHidden ? 0 : 480
    )
    .allowsHitTesting(!isListHidden)
    .sheet(item: $viewModel.editingSession, onDismiss: { viewModel.cancelEdits() }) { _ in
      EditSessionMetaView(viewModel: viewModel)
    }
    .sheet(isPresented: $showNewWithContext) {
      if let focused = focusedSummary {
        NewWithContextSheet(isPresented: $showNewWithContext, anchor: focused)
          .environmentObject(viewModel)
      }
    }
  }

  private func makeSidebarDigest(for state: SidebarState) -> SidebarDigest {
    func hashInt<S: Sequence>(_ seq: S) -> Int where S.Element == String {
      var h = Hasher()
      for s in seq { h.combine(s) }
      return h.finalize()
    }
    func hashIntDates<S: Sequence>(_ seq: S) -> Int where S.Element == Date {
      var h = Hasher()
      for d in seq { h.combine(d.timeIntervalSinceReferenceDate.bitPattern) }
      return h.finalize()
    }
    let projectsIdsHash = hashInt(viewModel.projects.map { $0.id + ("|" + ($0.parentId ?? "")) })
    func hashCounts(_ counts: [Int: Int]) -> Int {
      var h = Hasher()
      for key in counts.keys.sorted() {
        h.combine(key)
        h.combine(counts[key] ?? 0)
      }
      return h.finalize()
    }
    func hashEnabled(_ set: Set<Int>?) -> Int {
      guard let set else { return -1 }
      var h = Hasher()
      for value in set.sorted() { h.combine(value) }
      return h.finalize()
    }
    let selectedProjectsHash = hashInt(state.selectedProjectIDs.sorted())
    let selectedDaysHash = hashIntDates(state.selectedDays.sorted())
    return SidebarDigest(
      projectsCount: viewModel.projects.count,
      projectsIdsHash: projectsIdsHash,
      totalSessionCount: state.totalSessionCount,
      selectedProjectsHash: selectedProjectsHash,
      selectedDaysHash: selectedDaysHash,
      dateDimensionRaw: state.dateDimension == .created ? 1 : 2,
      monthStartInterval: state.monthStart.timeIntervalSinceReferenceDate,
      calendarCountsHash: hashCounts(state.calendarCounts),
      enabledDaysHash: hashEnabled(state.enabledProjectDays),
      visibleAllCount: state.visibleAllCount
    )
  }

  var refreshToolbarContent: some View {
    HStack(spacing: 12) {
      if permissionsManager.needsAuthorization {
        Button {
          openWindow(id: "settings")
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(
              .system(size: 14, weight: .medium)
            ).foregroundStyle(.orange)
            Text("Grant Access").font(.system(size: 12, weight: .medium))
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .controlSize(.small)
        .help("Some directories need authorization to access sessions data")
      }

      EquatableUsageContainer(
        snapshots: viewModel.usageSnapshots,
        selectedProvider: $usageProviderSelection,
        onRequestRefresh: { viewModel.requestUsageStatusRefresh(for: $0) }
      )

      Button {
        Task { await viewModel.refreshSessions(force: true) }
      } label: {
        Group {
          if viewModel.isEnriching {
            ProgressView()
              .progressViewStyle(.circular)
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 16, weight: .medium))
          }
        }
        .frame(width: 14, height: 14)
        .padding(8)
        .background(
          Circle()
            .fill(Color(nsColor: .separatorColor).opacity(0.25))
        )
        .overlay(
          Circle()
            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
        .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help("Refresh session index")
      .disabled(viewModel.isEnriching || viewModel.isLoading)
    }
    .padding(.horizontal, 3)
    .padding(.vertical, 2)
  }
}
