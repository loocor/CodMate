import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
  func navigationSplitView(geometry: GeometryProxy) -> some View {
    let sidebarMaxWidth = geometry.size.width * 0.25
    _ = storeSidebarHidden
    _ = storeListHidden
    let baseView = NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebarContent(sidebarMaxWidth: sidebarMaxWidth)
    } content: {
      listContent
    } detail: {
      detailColumn
    }
    .navigationSplitViewStyle(.prominentDetail)
    .onAppear {
      applyVisibilityFromStorage(animated: false)
      permissionsManager.restoreAccess()
      SecurityScopedBookmarks.shared.restoreAllDynamicBookmarks()
      Task { await permissionsManager.ensureCriticalDirectoriesAccess() }
    }
    let viewWithTasks = applyTaskAndChangeModifiers(to: baseView)
    let viewWithNotifications = applyNotificationModifiers(to: viewWithTasks)
    let viewWithDialogs = applyDialogsAndAlerts(to: viewWithNotifications)
    return applyGlobalSearchOverlay(to: viewWithDialogs, geometry: geometry)
  }

  func applyTaskAndChangeModifiers<V: View>(to view: V) -> some View {
    let v1 = view.task { await viewModel.refreshSessions(force: true) }
    let v2 = v1.onChange(of: viewModel.sections) { _, _ in
      applyPendingSelectionIfNeeded()
      normalizeSelection()
      reconcilePendingEmbeddedRekeys()
    }
    let v3 = v2.onChange(of: selection) { _, newSel in
      normalizeSelection()
      let added = newSel.subtracting(lastSelectionSnapshot)
      if let justAdded = added.first { selectionPrimaryId = justAdded }
      if let primary = selectionPrimaryId, !newSel.contains(primary) {
        selectionPrimaryId = newSel.first
      }
      lastSelectionSnapshot = newSel
    }
    let v4 = v3.onChange(of: viewModel.errorMessage) { _, message in
      guard let message else { return }
      alertState = AlertState(title: "Operation Failed", message: message)
      viewModel.errorMessage = nil
    }
    let v5 = v4.onChange(of: viewModel.pendingEmbeddedProjectNew) { _, project in
      guard let project else { return }
      startEmbeddedNewForProject(project)
      viewModel.pendingEmbeddedProjectNew = nil
    }
    let v6 = v5.toolbar {
      ToolbarItem(placement: .primaryAction) { refreshToolbarContent }
    }
    return AnyView(v6)
  }

  func applyNotificationModifiers<V: View>(to view: V) -> some View {
    view
      .onReceive(NotificationCenter.default.publisher(for: .codMateStartEmbeddedNewProject)) {
        note in
        if let pid = note.userInfo?["projectId"] as? String,
          let project = viewModel.projects.first(where: { $0.id == pid })
        {
          startEmbeddedNewForProject(project)
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .codMateToggleSidebar)) { _ in
        toggleSidebarVisibility()
      }
      .onReceive(NotificationCenter.default.publisher(for: .codMateToggleList)) { _ in
        toggleListVisibility()
      }
      .onReceive(NotificationCenter.default.publisher(for: .codMateFocusGlobalSearch)) { _ in
        focusGlobalSearchPanel()
      }
  }

  func applyDialogsAndAlerts<V: View>(to view: V) -> some View {
    view
      .confirmationDialog(
        "Stop running session?",
        isPresented: Binding<Bool>(
          get: { confirmStopState != nil }, set: { if !$0 { confirmStopState = nil } }),
        titleVisibility: .visible
      ) {
        Button("Stop", role: .destructive) {
          if let st = confirmStopState {
            stopEmbedded(forID: st.sessionId)
            confirmStopState = nil
          }
        }
        Button("Cancel", role: .cancel) { confirmStopState = nil }
      } message: {
        Text(
          "The embedded terminal appears to be running. Stopping now will terminate the current Codex/Claude task."
        )
      }
      .confirmationDialog(
        "Resume in embedded terminal?",
        isPresented: Binding<Bool>(
          get: { pendingTerminalLaunch != nil }, set: { if !$0 { pendingTerminalLaunch = nil } }),
        presenting: pendingTerminalLaunch?.session
      ) { session in
        Button("Resume", role: .none) {
          startEmbedded(for: session)
          pendingTerminalLaunch = nil
        }
        Button("Cancel", role: .cancel) {
          pendingTerminalLaunch = nil
        }
      } message: { session in
        Text(
          "CodMate will launch \(session.source.branding.displayName) inside the built-in terminal to resume “\(session.displayName)”."
        )
      }
      .alert(item: $alertState) { state in
        Alert(
          title: Text(state.title), message: Text(state.message),
          dismissButton: .default(Text("OK")))
      }
      .alert(
        "Delete selected sessions?", isPresented: $deleteConfirmationPresented,
        presenting: Array(selection)
      ) { ids in
        Button("Cancel", role: .cancel) {}
        Button("Move to Trash", role: .destructive) { deleteSelections(ids: ids) }
      } message: { _ in
        Text("Session files will be moved to Trash and can be restored in Finder.")
      }
      .fileImporter(
        isPresented: $selectingSessionsRoot, allowedContentTypes: [.folder],
        allowsMultipleSelection: false
      ) { result in
        handleFolderSelection(result: result, update: viewModel.updateSessionsRoot)
      }
  }
}
