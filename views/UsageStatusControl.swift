import SwiftUI

struct UsageStatusControl: View {
  var snapshots: [UsageProviderKind: UsageProviderSnapshot]
  @Binding var selectedProvider: UsageProviderKind
  var onRequestRefresh: (UsageProviderKind) -> Void

  @State private var showPopover = false
  @State private var isHovering = false

  private static let countdownFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    formatter.includesTimeRemainingPhrase = false
    return formatter
  }()

  private var countdownFormatter: DateComponentsFormatter { Self.countdownFormatter }

  var body: some View {
    let referenceDate = Date()
    HStack(spacing: 8) {
      let rows = providerRows(at: referenceDate)
      let outerProgress = progress(for: .claude, relativeTo: referenceDate)
      let innerProgress = progress(for: .codex, relativeTo: referenceDate)
      let snapshotForButton = snapshots[selectedProvider] ?? snapshots.values.first
      let providerForButton = snapshotForButton?.provider ?? selectedProvider

      Button {
        showPopover.toggle()
      } label: {
        HStack(spacing: isHovering ? 8 : 0) {
          DualUsageDonutView(
            outerProgress: outerProgress,
            innerProgress: innerProgress,
            outerColor: providerColor(.claude),
            innerColor: providerColor(.codex)
          )
          VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
              Text("Usage unavailable")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            } else {
              ForEach(rows, id: \.provider) { row in
                Text(row.text)
                  .font(.system(size: 9))
                  .lineLimit(1)
              }
            }
          }
          .opacity(isHovering ? 1 : 0)
          .frame(maxWidth: isHovering ? .infinity : 0, alignment: .leading)
          .clipped()
        }
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .padding(.leading, 5)
        .padding(.vertical, 5)
        .padding(.trailing, isHovering ? 9 : 5)
        .background(
          Capsule(style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .contentShape(Capsule(style: .continuous))
      }
      .buttonStyle(.plain)
      .help("View Codex and Claude Code usage snapshots")
      .focusable(false)
      .onHover { hovering in
        withAnimation(.easeInOut(duration: 0.2)) { isHovering = hovering }
        if hovering, (snapshotForButton?.availability != .ready) {
          onRequestRefresh(providerForButton)
        }
      }
      .popover(isPresented: $showPopover, arrowEdge: .top) {
        UsageStatusPopover(
          referenceDate: referenceDate,
          snapshots: snapshots,
          selectedProvider: $selectedProvider,
          onRequestRefresh: onRequestRefresh
        )
      }
      .onChange(of: showPopover) { _, open in
        if open, (snapshotForButton?.availability != .ready) {
          onRequestRefresh(providerForButton)
        }
      }
    }
  }

  private func providerRows(at date: Date) -> [(provider: UsageProviderKind, text: String)] {
    UsageProviderKind.allCases.compactMap { provider in
      guard let snapshot = snapshots[provider] else { return nil }
      let urgent = snapshot.urgentMetric(relativeTo: date)
      switch snapshot.availability {
      case .ready:
        let percent = urgent?.percentText ?? "—"
        let info: String
        if let reset = urgent?.resetDate {
          info = resetCountdown(from: reset) ?? resetFormatter.string(from: reset)
        } else if let minutes = urgent?.fallbackWindowMinutes {
          info = "\(minutes)m window"
        } else {
          info = "—"
        }
        return (provider, "\(provider.displayName) · \(percent) · \(info)")
      case .empty:
        return (provider, "\(provider.displayName) · Not available")
      case .comingSoon:
        return nil
      }
    }
  }

  private func progress(for provider: UsageProviderKind, relativeTo date: Date) -> Double? {
    guard let snapshot = snapshots[provider], snapshot.availability == .ready else { return nil }
    return snapshot.urgentMetric(relativeTo: date)?.progress
  }

  private func providerColor(_ provider: UsageProviderKind) -> Color {
    switch provider {
    case .codex:
      return Color.accentColor
    case .claude:
      return Color(nsColor: .systemPurple)
    }
  }

  private static let resetFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d HH:mm")
    return formatter
  }()

  private var resetFormatter: DateFormatter { Self.resetFormatter }

  private func resetCountdown(from date: Date) -> String? {
    let interval = date.timeIntervalSinceNow
    guard interval > 0 else { return "reset" }
    if let formatted = countdownFormatter.string(from: interval) {
      return "resets in \(formatted)"
    }
    return nil
  }
}

private struct DualUsageDonutView: View {
  var outerProgress: Double?
  var innerProgress: Double?
  var outerColor: Color
  var innerColor: Color

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.secondary.opacity(0.25), lineWidth: 4)
        .frame(width: 22, height: 22)
      if let outerProgress {
        Circle()
          .trim(from: 0, to: CGFloat(max(0, min(outerProgress, 1))))
          .stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round))
          .foregroundStyle(outerColor)
          .rotationEffect(.degrees(-90))
          .frame(width: 22, height: 22)
      }
      Circle()
        .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
        .frame(width: 10, height: 10)
      if let innerProgress {
        Circle()
          .trim(from: 0, to: CGFloat(max(0, min(innerProgress, 1))))
          .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
          .foregroundStyle(innerColor)
          .rotationEffect(.degrees(-90))
          .frame(width: 10, height: 10)
      }
    }
  }
}

private struct UsageStatusPopover: View {
  var referenceDate: Date
  var snapshots: [UsageProviderKind: UsageProviderSnapshot]
  @Binding var selectedProvider: UsageProviderKind
  var onRequestRefresh: (UsageProviderKind) -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let providers = UsageProviderKind.allCases
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            providerIcon(for: provider)
            Text(provider.displayName)
              .font(.subheadline.weight(.semibold))
            Spacer()
          }

          if let snapshot = snapshots[provider] {
            UsageSnapshotView(
              referenceDate: referenceDate,
              snapshot: snapshot,
              provider: provider,
              onRequestRefresh: onRequestRefresh
            )
          } else {
            Text("No usage data available")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        if index < providers.count - 1 {
          Divider()
            .padding(.vertical, 6)
        }
      }
    }
    .padding(16)
    .frame(width: 300)
    .focusable(false)
  }

  @ViewBuilder
  private func providerIcon(for provider: UsageProviderKind) -> some View {
    if let name = iconName(for: provider) {
      Image(name)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: 12, height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .modifier(DarkModeInvertModifier(active: provider == .codex && colorScheme == .dark))
    } else {
      Circle()
        .fill(accent(for: provider))
        .frame(width: 9, height: 9)
    }
  }

  private func iconName(for provider: UsageProviderKind) -> String? {
    switch provider {
    case .codex: return "ChatGPTIcon"
    case .claude: return "ClaudeIcon"
    }
  }

  private func accent(for provider: UsageProviderKind) -> Color {
    switch provider {
    case .codex: return Color.accentColor
    case .claude: return Color(nsColor: .systemPurple)
    }
  }
}

private struct UsageSnapshotView: View {
  var referenceDate: Date
  var snapshot: UsageProviderSnapshot
  var provider: UsageProviderKind
  var onRequestRefresh: (UsageProviderKind) -> Void

  @State private var showReauthAlert = false

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if snapshot.availability == .ready {
        ForEach(snapshot.metrics.filter { $0.kind != .snapshot && $0.kind != .context }) { metric in
          let state = MetricDisplayState(metric: metric, referenceDate: referenceDate)
          UsageMetricRowView(metric: metric, state: state)
        }

        HStack {
          Spacer(minLength: 0)
          Label(updatedLabel(reference: referenceDate), systemImage: "clock.arrow.circlepath")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if snapshot.availability == .comingSoon {
        VStack(alignment: .leading, spacing: 8) {
          Text("Coming soon")
            .font(.headline)
          Text(snapshot.statusMessage ?? "Usage data for this provider is not yet available.")
            .foregroundStyle(.secondary)
        }
      } else {
        // Error state: show re-auth button if needed
        if snapshot.requiresReauth {
          VStack(alignment: .leading, spacing: 10) {
            Text(snapshot.statusMessage ?? "Authentication required.")
              .font(.footnote)
              .foregroundStyle(.secondary)

            Button {
              showReauthAlert = true
            } label: {
              Label("Re-authenticate", systemImage: "lock.shield")
                .font(.subheadline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          }
          .alert("Re-authenticate Claude Code", isPresented: $showReauthAlert) {
            Button("OK") {}
          } message: {
            Text("To re-authenticate:\n\n1. Open Terminal or CodMate's embedded terminal\n2. Run: claude auth login\n3. Complete the sign-in flow\n4. Refresh usage status")
          }
        } else {
          Text(snapshot.statusMessage ?? "No usage data yet.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .focusable(false)
  }

  private func updatedLabel(reference: Date) -> String {
    if let updated = snapshot.updatedAt {
      let relative = Self.relativeFormatter.localizedString(for: updated, relativeTo: reference)
      return "Updated " + relative
    }
    return "Waiting for usage data"
  }
}

private struct MetricDisplayState {
  var progress: Double?
  var usageText: String?
  var percentText: String?
  var resetText: String

  init(metric: UsageMetricSnapshot, referenceDate: Date) {
    let expired = metric.resetDate.map { $0 <= referenceDate } ?? false
    if expired {
      progress = metric.progress != nil ? 0 : nil
      percentText = metric.percentText != nil ? "0%" : nil
      if metric.kind == .fiveHour {
        usageText = "No usage since reset"
      } else {
        usageText = metric.usageText
      }
      if metric.kind == .fiveHour {
        resetText = "Reset"
      } else {
        resetText = ""
      }
    } else {
      progress = metric.progress
      percentText = metric.percentText
      usageText = metric.usageText
      resetText = Self.resetDescription(for: metric)
    }
  }

  private static func resetDescription(for metric: UsageMetricSnapshot) -> String {
    if let date = metric.resetDate {
      return "Resets " + Self.resetFormatter.string(from: date)
    }
    if let minutes = metric.fallbackWindowMinutes {
      if minutes >= 60 {
        return String(format: "%.1fh window", Double(minutes) / 60.0)
      }
      return "\(minutes) min window"
    }
    return ""
  }

  private static let resetFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d, HH:mm")
    return formatter
  }()
}

private struct UsageMetricRowView: View {
  var metric: UsageMetricSnapshot
  var state: MetricDisplayState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(metric.label)
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(state.resetText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      if let progress = state.progress {
        UsageProgressBar(progress: progress)
          .frame(height: 4)
      }

      HStack {
        Text(state.usageText ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text(state.percentText ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct UsageProgressBar: View {
  var progress: Double

  var body: some View {
    GeometryReader { geo in
      let clamped = max(0, min(progress, 1))
      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(Color.secondary.opacity(0.2))
        if clamped <= 0.002 {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
        } else {
          Capsule(style: .continuous)
            .fill(Color.accentColor)
            .frame(width: max(6, geo.size.width * CGFloat(clamped)))
        }
      }
    }
  }
}

private struct DarkModeInvertModifier: ViewModifier {
  var active: Bool

  func body(content: Content) -> some View {
    if active {
      content.colorInvert()
    } else {
      content
    }
  }
}
