import SwiftUI

struct UsageStatusControl: View {
  var snapshots: [UsageProviderKind: UsageProviderSnapshot]
  @Binding var selectedProvider: UsageProviderKind
  var onRequestRefresh: (UsageProviderKind) -> Void

  @State private var showPopover = false
  @State private var isHovering = false

  private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  var body: some View {
    HStack(spacing: 8) {
      let rows = providerRows()
      let outerProgress = progress(for: .claude)
      let innerProgress = progress(for: .codex)
      let snapshotForButton = snapshots[selectedProvider] ?? snapshots.values.first
      let providerForButton = snapshotForButton?.provider ?? selectedProvider

      Button {
        if snapshotForButton?.availability != .ready {
          onRequestRefresh(providerForButton)
        }
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
        withAnimation(.easeInOut(duration: 0.2)) {
          isHovering = hovering
        }
      }
      .popover(isPresented: $showPopover, arrowEdge: .top) {
        UsageStatusPopover(
          snapshots: snapshots,
          selectedProvider: $selectedProvider,
          onRequestRefresh: onRequestRefresh
        )
        .frame(width: 340)
      }
    }
  }

  private func providerRows() -> [(provider: UsageProviderKind, text: String)] {
    UsageProviderKind.allCases.compactMap { provider in
      guard let snapshot = snapshots[provider] else { return nil }
      switch snapshot.availability {
      case .ready:
        let percent = snapshot.urgentMetric?.percentText ?? "—"
        let info: String
        if let reset = snapshot.urgentMetric?.resetDate {
          info = resetFormatter.string(from: reset)
        } else if let minutes = snapshot.urgentMetric?.fallbackWindowMinutes {
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

  private func progress(for provider: UsageProviderKind) -> Double? {
    guard let snapshot = snapshots[provider], snapshot.availability == .ready else { return nil }
    return snapshot.urgentMetric?.progress
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
  var snapshots: [UsageProviderKind: UsageProviderSnapshot]
  @Binding var selectedProvider: UsageProviderKind
  var onRequestRefresh: (UsageProviderKind) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Picker("", selection: $selectedProvider) {
        ForEach(UsageProviderKind.allCases) { kind in
          Text(kind.displayName).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .controlSize(.small)
      .frame(maxWidth: .infinity, minHeight: 24)
      .focusable(false)

      if let snapshot = snapshots[selectedProvider] {
        UsageSnapshotView(
          snapshot: snapshot,
          provider: selectedProvider,
          onRequestRefresh: onRequestRefresh
        )
      } else {
        Text("No usage data available")
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .focusable(false)
  }
}

private struct UsageSnapshotView: View {
  var snapshot: UsageProviderSnapshot
  var provider: UsageProviderKind
  var onRequestRefresh: (UsageProviderKind) -> Void

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if snapshot.availability == .ready {
        ForEach(snapshot.metrics.filter { $0.kind != .snapshot && $0.kind != .context }) { metric in
          UsageMetricRowView(metric: metric)
        }

        HStack {
          if let updated = snapshot.updatedAt {
            Text(
              "Updated " + Self.relativeFormatter.localizedString(for: updated, relativeTo: Date())
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Refresh") { onRequestRefresh(provider) }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
            .focusable(false)
        }
      } else if snapshot.availability == .comingSoon {
        VStack(alignment: .leading, spacing: 8) {
          Text("Coming soon")
            .font(.headline)
          Text(snapshot.statusMessage ?? "Usage data for this provider is not yet available.")
            .foregroundStyle(.secondary)
        }
      } else {
        Text(snapshot.statusMessage ?? "No usage data yet.")
          .foregroundStyle(.secondary)
      }
    }
    .focusable(false)
  }
}

private struct UsageMetricRowView: View {
  var metric: UsageMetricSnapshot

  private static let resetFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d, HH:mm")
    return formatter
  }()

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(metric.label)
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(resetText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      if let progress = metric.progress {
        UsageProgressBar(progress: progress)
          .frame(height: 4)
      }

      HStack {
        Text(metric.usageText ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text(metric.percentText ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var resetText: String {
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
