import SwiftUI

struct SessionSourceBranding {
    let displayName: String
    let symbolName: String
    let iconColor: Color
    let badgeBackground: Color
    let badgeAssetName: String?
}

extension SessionSource {
    var branding: SessionSourceBranding {
        switch self {
        case .codex:
            return SessionSourceBranding(
                displayName: "Codex",
                symbolName: "sparkles",
                iconColor: Color.accentColor,
                badgeBackground: Color.accentColor.opacity(0.08),
                badgeAssetName: "ChatGPTIcon"
            )
        case .claude:
            return SessionSourceBranding(
                displayName: "Claude",
                symbolName: "cloud.fill",
                iconColor: Color.purple,
                badgeBackground: Color.purple.opacity(0.10),
                badgeAssetName: "ClaudeIcon"
            )
        }
    }
}

struct SessionListRowView: View {
    let summary: SessionSummary
    var isRunning: Bool = false
    var isSelected: Bool = false
    var isUpdating: Bool = false
    var awaitingFollowup: Bool = false
    var inProject: Bool = false
    var projectTip: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        let branding = summary.source.branding
        HStack(alignment: .top, spacing: 12) {
            let container = RoundedRectangle(cornerRadius: 9, style: .continuous)
            ZStack {
                if !isRunning {
                    container
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.08), radius: 1.5, x: 0, y: 1)
                    container
                        .stroke(
                            isSelected ? branding.iconColor.opacity(0.5) : Color.black.opacity(0.06),
                            lineWidth: isSelected ? 1.5 : 1)
                }

                if isRunning {
                    SpinningBeachballView(spins: true)
                        .padding(2)
                        .opacity(
                            reduceMotion ? 1.0 : (awaitingFollowup ? (breathing ? 1.0 : 0.55) : 1.0)
                        )
                } else if awaitingFollowup {
                    // Draw a non-spinning beachball and apply a subtle breathing fade
                    SpinningBeachballView(spins: false)
                        .padding(2)
                        .opacity(reduceMotion ? 1.0 : (breathing ? 1.0 : 0.55))
                } else if let asset = branding.badgeAssetName {
                    Image(asset)
                        .resizable()
                        .renderingMode(.original)
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(systemName: branding.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(branding.iconColor)
                }
            }
            .frame(width: 32, height: 32)
            .help("\(branding.displayName) session")

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.effectiveTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(summary.startedAt.formatted(date: .numeric, time: .shortened))
                        .layoutPriority(1)
                    Text(summary.readableDuration)
                        .layoutPriority(1)
                    if let model = summary.displayModel ?? summary.model {
                        Text(model)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text(summary.commentSnippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                // Compact metrics moved from detail view
                HStack(spacing: 8) {
                    metric(icon: "person", value: summary.userMessageCount)
                    metric(icon: "sparkles", value: summary.assistantMessageCount)
                    metric(icon: "hammer", value: summary.toolInvocationCount)
                    if let reasoning = summary.responseCounts["reasoning"], reasoning > 0 {
                        metric(icon: "brain", value: reasoning)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, 8)
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if inProject {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(Color.secondary)
                        .font(.system(size: 12, weight: .regular))
                        .help(projectTip ?? "Project")
                }
                if isUpdating {
                    Image(systemName: "timer")
                        .foregroundStyle(Color.orange)
                        .font(.system(size: 16, weight: .semibold))
                        .symbolEffect(.pulse, isActive: true)
                        .help("Updating…")
                }
            }
            .padding(.trailing, 8)
            .padding(.top, 8)
            .allowsHitTesting(false)
        }
        .onAppear {
            // Start breathing for running rows (legacy; may be imperceptible) or
            // attention pulse for follow-up rows.
            guard !reduceMotion else { return }
            if isRunning || awaitingFollowup {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
        }
        .onChange(of: isRunning) { _, newValue in
            if newValue {
                if reduceMotion {
                    breathing = false
                } else {
                    breathing = false
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        breathing = true
                    }
                }
            } else {
                // Smoothly fade out the background when session stops running
                withAnimation(.easeOut(duration: 0.2)) {
                    breathing = false
                }
            }
        }
        .onChange(of: awaitingFollowup) { _, needed in
            guard !reduceMotion else { return }
            if needed {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { breathing = false }
            }
        }
    }
}

private func metric(icon: String, value: Int) -> some View {
    HStack(spacing: 4) {
        Image(systemName: icon)
        Text("\(value)")
    }
}

// Spinning macOS-style rainbow beachball indicator
private struct SpinningBeachballView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0
    var spins: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(
                    gradient: Gradient(colors: [
                        .red, .orange, .yellow, .green, .blue, .purple, .red
                    ]),
                    center: .center))
            // White center cap
            Circle()
                .fill(Color.white.opacity(0.92))
                .scaleEffect(0.30)
            // Thin white separators to hint the segments
            ForEach(0..<6) { i in
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 1.2)
                    .offset(y: -14)
                    .rotationEffect(.degrees(Double(i) * 60))
            }
        }
        .rotationEffect(.degrees(angle))
        .onAppear { startIfNeeded() }
        .onChange(of: reduceMotion) { _, _ in startIfNeeded() }
        .drawingGroup()
    }

    private func startIfNeeded() {
        if reduceMotion || !spins {
            angle = 0
            return
        }
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

private extension SessionListRowView {}

#Preview {
    let mockSummary = SessionSummary(
        id: "session-preview",
        fileURL: URL(fileURLWithPath: "/Users/developer/.codex/sessions/session-preview.json"),
        fileSizeBytes: 12340,
        startedAt: Date().addingTimeInterval(-3600),
        endedAt: Date().addingTimeInterval(-1800),
        activeDuration: nil,
        cliVersion: "1.2.3",
        cwd: "/Users/developer/projects/codmate",
        originator: "developer",
        instructions:
            "Please help optimize this SwiftUI app's performance, especially scroll stutter in lists. It should remain smooth with large datasets.",
        model: "gpt-4o-mini",
        approvalPolicy: "auto",
        userMessageCount: 5,
        assistantMessageCount: 4,
        toolInvocationCount: 3,
        responseCounts: ["reasoning": 2],
        turnContextCount: 8,
        eventCount: 12,
        lineCount: 156,
        lastUpdatedAt: Date().addingTimeInterval(-1800),
        source: .codex
    )

    return SessionListRowView(summary: mockSummary)
        .frame(width: 400, height: 120)
        .padding()
}

#Preview("Short Instructions") {
    let mockSummary = SessionSummary(
        id: "session-short",
        fileURL: URL(fileURLWithPath: "/Users/developer/.codex/sessions/session-short.json"),
        fileSizeBytes: 5600,
        startedAt: Date().addingTimeInterval(-7200),
        endedAt: Date().addingTimeInterval(-6900),
        activeDuration: nil,
        cliVersion: "1.2.3",
        cwd: "/Users/developer/projects/test",
        originator: "developer",
        instructions: "Create a to-do app",
        model: "gpt-4o",
        approvalPolicy: "manual",
        userMessageCount: 2,
        assistantMessageCount: 1,
        toolInvocationCount: 0,
        responseCounts: [:],
        turnContextCount: 3,
        eventCount: 3,
        lineCount: 45,
        lastUpdatedAt: Date().addingTimeInterval(-6900),
        source: .codex
    )

    return SessionListRowView(summary: mockSummary)
        .frame(width: 300, height: 100)
        .padding()
}

#Preview("No Instructions") {
    let mockSummary = SessionSummary(
        id: "session-no-instructions",
        fileURL: URL(
            fileURLWithPath: "/Users/developer/.codex/sessions/session-no-instructions.json"),
        fileSizeBytes: 3200,
        startedAt: Date().addingTimeInterval(-10800),
        endedAt: Date().addingTimeInterval(-10500),
        activeDuration: nil,
        cliVersion: "1.2.2",
        cwd: "/Users/developer/documents",
        originator: "developer",
        instructions: nil,
        model: "gpt-4o-mini",
        approvalPolicy: "auto",
        userMessageCount: 1,
        assistantMessageCount: 1,
        toolInvocationCount: 0,
        responseCounts: [:],
        turnContextCount: 2,
        eventCount: 2,
        lineCount: 20,
        lastUpdatedAt: Date().addingTimeInterval(-10500),
        source: .codex
    )

    return SessionListRowView(summary: mockSummary)
        .frame(width: 400, height: 100)
        .padding()
}
