import SwiftUI

extension ContentView {
  var detailColumn: some View {
    VStack(spacing: 0) {
      if viewModel.projectWorkspaceMode == .review, let project = currentSelectedProject(), let dir = project.directory, !dir.isEmpty {
        // Project-level Review: detail renders right-only (header + diff/preview)
        reviewRightColumn(project: project, directory: dir)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.projectWorkspaceMode == .overview {
        projectOverviewContent()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.projectWorkspaceMode == .agents {
        projectAgentsContent()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.projectWorkspaceMode == .memory {
        placeholderSurface(title: "Memory", systemImage: "bookmark")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.projectWorkspaceMode == .settings {
        placeholderSurface(title: "Project Settings", systemImage: "gearshape")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        // Tasks or Sessions mode (both show session-focused UI)
        detailActionBar
          .padding(.horizontal, 16)
          .padding(.vertical, 12)

        Divider()

        mainDetailContent
          .animation(nil, value: isListHidden)
      }
    }
    .frame(minWidth: 640)
    .onChange(of: selectedDetailTab) { _, newVal in
      // Coerce legacy .review to .timeline in Tasks mode (session-level Git Review removed)
      if newVal == .review { selectedDetailTab = .timeline; return }
      if let focused = focusedSummary {
        sessionDetailTabs[focused.id] = newVal
      }
    }
    .onChange(of: viewModel.projectWorkspaceMode) { _, newMode in
      // When switching into project Review, ensure repository authorization
      if newMode == .review, let p = currentSelectedProject(), let dir = p.directory, !dir.isEmpty {
        ensureRepoAccessForProjectReview(directory: dir)
      }
    }
    .onChange(of: focusedSummary?.id) { _, newId in
      if let newId = newId {
        selectedDetailTab = sessionDetailTabs[newId] ?? .timeline
      } else {
        selectedDetailTab = .timeline
      }
      if selectedDetailTab == .review { selectedDetailTab = .timeline }
      normalizeDetailTabForTerminalAvailability()
    }
    .onChange(of: runningSessionIDs) { _, _ in
      normalizeDetailTabForTerminalAvailability()
      synchronizeSelectedTerminalKey()
    }
  }
}

extension ContentView {
  func currentSelectedProject() -> Project? {
    guard let pid = viewModel.selectedProjectIDs.first else { return nil }
    return viewModel.projects.first(where: { $0.id == pid })
  }

  @ViewBuilder
  func projectReviewContent(project: Project, directory: String) -> some View {
    let ws = directory
    let stateBinding = Binding<ReviewPanelState>(
      get: { viewModel.projectReviewPanelStates[project.id] ?? ReviewPanelState() },
      set: { viewModel.projectReviewPanelStates[project.id] = $0 }
    )
    EquatableGitChangesContainer(
      key: .init(
        workingDirectoryPath: ws,
        projectDirectoryPath: ws,
        state: stateBinding.wrappedValue
      ),
      workingDirectory: URL(fileURLWithPath: ws, isDirectory: true),
      projectDirectory: URL(fileURLWithPath: ws, isDirectory: true),
      presentation: .full,
      preferences: viewModel.preferences,
      onRequestAuthorization: { ensureRepoAccessForProjectReview(directory: ws) },
      savedState: stateBinding
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Match Tasks detail layout: no extra outer padding; header/content provide their own
  }

  @ViewBuilder
  func reviewRightColumn(project: Project, directory: String) -> some View {
    let ws = directory
    let stateBinding = Binding<ReviewPanelState>(
      get: { viewModel.projectReviewPanelStates[project.id] ?? ReviewPanelState() },
      set: { viewModel.projectReviewPanelStates[project.id] = $0 }
    )
    let vm = projectReviewVM(for: project.id)
    EquatableGitChangesContainer(
      key: .init(
        workingDirectoryPath: ws,
        projectDirectoryPath: ws,
        state: stateBinding.wrappedValue
      ),
      workingDirectory: URL(fileURLWithPath: ws, isDirectory: true),
      projectDirectory: URL(fileURLWithPath: ws, isDirectory: true),
      presentation: .full,
      regionLayout: .rightOnly,
      preferences: viewModel.preferences,
      onRequestAuthorization: { ensureRepoAccessForProjectReview(directory: ws) },
      externalVM: vm,
      savedState: stateBinding
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Match Tasks detail layout: no extra outer padding; header/content provide their own
  }

  @ViewBuilder
  func projectOverviewContent() -> some View {
    // Placeholder for Overview — when All/Other selected, show a blank gentle surface
    placeholderSurface(title: "Overview", systemImage: "square.grid.2x2")
  }

  @ViewBuilder
  func projectAgentsContent() -> some View {
    if let project = currentSelectedProject(), let directory = project.directory {
      ProjectAgentsView(projectDirectory: directory, preferences: viewModel.preferences)
    } else {
      placeholderSurface(title: "No Project Selected", systemImage: "folder.badge.questionmark")
    }
  }

  @ViewBuilder
  func placeholderSurface(title: String, systemImage: String) -> some View {
    VStack(alignment: .center, spacing: 8) {
      Spacer(minLength: 0)
      Image(systemName: systemImage)
        .font(.system(size: 32, weight: .regular))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.title3.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
