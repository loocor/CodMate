import SwiftUI

extension ContentView {
  func applyGlobalSearchOverlay<V: View>(to view: V, geometry: GeometryProxy) -> some View {
    view.overlay(alignment: .top) {
      if globalSearchViewModel.shouldShowPanel {
        let panelWidth = max(360, min(geometry.size.width * 0.55, 640))
        GlobalSearchPanel(
          viewModel: globalSearchViewModel,
          maxWidth: panelWidth,
          onSelect: { handleGlobalSearchSelection($0) },
          onClose: { globalSearchViewModel.dismissPanel() }
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.horizontal, max(24, (geometry.size.width - panelWidth) / 2))
        .transition(.move(edge: .top).combined(with: .opacity))
        .zIndex(20)
      }
    }
  }

  func focusGlobalSearchPanel() {
    globalSearchViewModel.setFocus(true)
  }

  func handleGlobalSearchSelection(_ result: GlobalSearchResult) {
    defer { globalSearchViewModel.dismissPanel() }
    let trimmedTerm = globalSearchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
    switch result.kind {
    case .project:
      guard let project = result.project else { return }
      highlightProject(project)
    case .note:
      guard let note = result.note else { return }
      guard let summary = viewModel.sessionSummary(withId: note.id) else {
        if let pid = note.projectId, let project = viewModel.projects.first(where: { $0.id == pid }) {
          highlightProject(project)
        }
        return
      }
      focusOnSession(
        summary,
        explicitProjectId: note.projectId,
        searchTerm: nil,
        filterConversation: false
      )
    case .session:
      guard let summary = result.sessionSummary ?? viewModel.sessionSummary(forFileURL: result.fileURL) else { return }
      let projectId = viewModel.projectIdForSession(summary.id)
      focusOnSession(
        summary,
        explicitProjectId: projectId,
        searchTerm: trimmedTerm.isEmpty ? nil : trimmedTerm,
        filterConversation: true
      )
    }
  }

  private func highlightProject(_ project: Project) {
    viewModel.clearScopeFilters()
    viewModel.setSelectedProject(project.id)
    viewModel.requestProjectExpansion(for: project.id)
    isListHidden = false
  }

  func focusOnSession(
    _ summary: SessionSummary,
    explicitProjectId: String?,
    searchTerm: String?,
    filterConversation: Bool
  ) {
    viewModel.clearScopeFilters()
    let projectToApply = explicitProjectId ?? viewModel.projectIdForSession(summary.id)
    if let pid = projectToApply {
      viewModel.setSelectedProject(pid)
      viewModel.requestProjectExpansion(for: pid)
    }
    let referenceDate = summary.lastUpdatedAt ?? summary.startedAt
    let day = Calendar.current.startOfDay(for: referenceDate)
    viewModel.selectedDay = day
    viewModel.selectedDays = Set([day])
    pendingSelectionID = summary.id
    applyPendingSelectionIfNeeded()
    selectedDetailTab = .timeline
    isListHidden = false

    if filterConversation, let term = searchTerm, !term.isEmpty {
      if selectionPrimaryId == summary.id {
        notifyConversationFilter(sessionId: summary.id, term: term)
      } else {
        pendingConversationFilter = (summary.id, term)
      }
    } else {
      pendingConversationFilter = nil
    }
  }

  private func notifyConversationFilter(sessionId: String, term: String) {
    let info: [String: Any] = ["sessionId": sessionId, "term": term]
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      NotificationCenter.default.post(
        name: .codMateConversationFilter,
        object: nil,
        userInfo: info
      )
    }
  }

  func applyPendingSelectionIfNeeded() {
    guard let pending = pendingSelectionID else { return }
    let visibleIDs = viewModel.sections.flatMap { $0.sessions.map(\.id) }
    guard visibleIDs.contains(pending) else { return }
    selection = [pending]
    selectionPrimaryId = pending
    pendingSelectionID = nil
    if let filter = pendingConversationFilter, filter.id == pending {
      notifyConversationFilter(sessionId: filter.id, term: filter.term)
      pendingConversationFilter = nil
    }
  }
}
