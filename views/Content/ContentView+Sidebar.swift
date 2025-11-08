import SwiftUI

extension ContentView {
  func sidebarContent(sidebarMaxWidth: CGFloat) -> some View {
    SessionNavigationView(
      totalCount: viewModel.totalSessionCount,
      isLoading: viewModel.isLoading
    )
    .environmentObject(viewModel)
    .navigationSplitViewColumnWidth(min: 260, ideal: 260, max: 260)
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

      UsageStatusControl(
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
