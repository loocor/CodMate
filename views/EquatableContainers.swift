import SwiftUI

// Equatable wrapper to minimize diffs for the Git Review panel when state is unchanged
struct EquatableGitChangesContainer: View, Equatable {
  struct Key: Equatable {
    var workingDirectoryPath: String
    var projectDirectoryPath: String?
    var state: ReviewPanelState
  }

  static func == (lhs: EquatableGitChangesContainer, rhs: EquatableGitChangesContainer) -> Bool {
    lhs.key == rhs.key
  }

  let key: Key
  let workingDirectory: URL
  let projectDirectory: URL?
  let presentation: GitChangesPanel.Presentation
  let preferences: SessionPreferencesStore
  var onRequestAuthorization: (() -> Void)? = nil
  @Binding var savedState: ReviewPanelState

  var body: some View {
    GitChangesPanel(
      workingDirectory: workingDirectory,
      projectDirectory: projectDirectory,
      presentation: presentation,
      preferences: preferences,
      onRequestAuthorization: onRequestAuthorization,
      savedState: $savedState
    )
  }
}

// Equatable wrapper for the Usage capsule to reduce AttributeGraph diffs.
struct EquatableUsageContainer: View, Equatable {
  struct UsageDigest: Equatable {
    var codexUpdatedAt: TimeInterval?
    var codexAvailability: Int
    var codexUrgentProgress: Double?
    var codexOrigin: Int
    var claudeUpdatedAt: TimeInterval?
    var claudeAvailability: Int
    var claudeUrgentProgress: Double?
    var claudeOrigin: Int
  }

  static func == (lhs: EquatableUsageContainer, rhs: EquatableUsageContainer) -> Bool {
    lhs.key == rhs.key
  }

  let key: UsageDigest

  var snapshots: [UsageProviderKind: UsageProviderSnapshot]
  @Binding var selectedProvider: UsageProviderKind
  var onRequestRefresh: (UsageProviderKind) -> Void

  init(
    snapshots: [UsageProviderKind: UsageProviderSnapshot],
    selectedProvider: Binding<UsageProviderKind>,
    onRequestRefresh: @escaping (UsageProviderKind) -> Void
  ) {
    self.snapshots = snapshots
    self._selectedProvider = selectedProvider
    self.onRequestRefresh = onRequestRefresh
    self.key = Self.digest(snapshots)
  }

  var body: some View {
    UsageStatusControl(
      snapshots: snapshots,
      selectedProvider: $selectedProvider,
      onRequestRefresh: onRequestRefresh
    )
  }

  private static func digest(_ snapshots: [UsageProviderKind: UsageProviderSnapshot]) -> UsageDigest {
    func parts(for provider: UsageProviderKind) -> (TimeInterval?, Int, Double?, Int) {
      guard let snap = snapshots[provider] else { return (nil, -1, nil, -1) }
      let updated = snap.updatedAt?.timeIntervalSinceReferenceDate
      let availability: Int
      switch snap.availability {
      case .ready: availability = 1
      case .empty: availability = 2
      case .comingSoon: availability = 3
      }
      let urgent = snap.urgentMetric()?.progress
      let origin = snap.origin == .thirdParty ? 1 : 0
      return (updated, availability, urgent, origin)
    }
    let cdx = parts(for: .codex)
    let cld = parts(for: .claude)
    return UsageDigest(
      codexUpdatedAt: cdx.0,
      codexAvailability: cdx.1,
      codexUrgentProgress: cdx.2,
      codexOrigin: cdx.3,
      claudeUpdatedAt: cld.0,
      claudeAvailability: cld.1,
      claudeUrgentProgress: cld.2,
      claudeOrigin: cld.3
    )
  }
}

// Digest for Sidebar state equality
struct SidebarDigest: Equatable {
  var projectsCount: Int
  var projectsIdsHash: Int
  var totalSessionCount: Int
  var selectedProjectsHash: Int
  var selectedDaysHash: Int
  var dateDimensionRaw: Int
  var monthStartInterval: TimeInterval
  var calendarCountsHash: Int
  var enabledDaysHash: Int
  var visibleAllCount: Int
  var projectWorkspaceMode: ProjectWorkspaceMode
}

// Equatable wrapper for the Sidebar content to minimize diffs while keeping
// the internal view hierarchy (which still uses EnvironmentObject) unchanged.
struct EquatableSidebarContainer<Content: View>: View, Equatable {
  static func == (lhs: EquatableSidebarContainer<Content>, rhs: EquatableSidebarContainer<Content>) -> Bool {
    lhs.key == rhs.key
  }

  let key: SidebarDigest
  let content: () -> Content

  var body: some View { content() }
}
