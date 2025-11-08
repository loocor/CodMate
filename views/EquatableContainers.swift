import SwiftUI

// Equatable wrapper to minimize diffs for the Git Review panel when state is unchanged
struct EquatableGitChangesContainer: View, Equatable {
  struct Key: Equatable {
    var workingDirectoryPath: String
    var state: ReviewPanelState
  }

  static func == (lhs: EquatableGitChangesContainer, rhs: EquatableGitChangesContainer) -> Bool {
    lhs.key == rhs.key
  }

  let key: Key
  let workingDirectory: URL
  let presentation: GitChangesPanel.Presentation
  let preferences: SessionPreferencesStore
  var onRequestAuthorization: (() -> Void)? = nil
  @Binding var savedState: ReviewPanelState

  var body: some View {
    GitChangesPanel(
      workingDirectory: workingDirectory,
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
    var claudeUpdatedAt: TimeInterval?
    var claudeAvailability: Int
    var claudeUrgentProgress: Double?
  }

  static func == (lhs: EquatableUsageContainer, rhs: EquatableUsageContainer) -> Bool {
    lhs.key == rhs.key && lhs.selectedProviderValue == rhs.selectedProviderValue
  }

  let key: UsageDigest
  let selectedProviderValue: UsageProviderKind

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
    self.selectedProviderValue = selectedProvider.wrappedValue
  }

  var body: some View {
    UsageStatusControl(
      snapshots: snapshots,
      selectedProvider: $selectedProvider,
      onRequestRefresh: onRequestRefresh
    )
  }

  private static func digest(_ snapshots: [UsageProviderKind: UsageProviderSnapshot]) -> UsageDigest {
    func parts(for provider: UsageProviderKind) -> (TimeInterval?, Int, Double?) {
      guard let snap = snapshots[provider] else { return (nil, -1, nil) }
      let updated = snap.updatedAt?.timeIntervalSinceReferenceDate
      let availability: Int
      switch snap.availability {
      case .ready: availability = 1
      case .empty: availability = 2
      case .comingSoon: availability = 3
      }
      let urgent = snap.urgentMetric()?.progress
      return (updated, availability, urgent)
    }
    let cdx = parts(for: .codex)
    let cld = parts(for: .claude)
    return UsageDigest(
      codexUpdatedAt: cdx.0,
      codexAvailability: cdx.1,
      codexUrgentProgress: cdx.2,
      claudeUpdatedAt: cld.0,
      claudeAvailability: cld.1,
      claudeUrgentProgress: cld.2
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
