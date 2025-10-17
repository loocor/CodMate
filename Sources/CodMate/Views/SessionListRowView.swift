import SwiftUI

struct SessionListRowView: View {
    let summary: SessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "rectangle.and.text.magnifyingglass")
                        .foregroundStyle(Color.accentColor)
                        .font(.subheadline)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayName)
                    .font(.headline)
                HStack(spacing: 12) {
                    Text(summary.startedAt.formatted(date: .numeric, time: .shortened))
                    Text(summary.readableDuration)
                    if let model = summary.model {
                        Text(model)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(summary.instructionSnippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Label("\(summary.userMessageCount)", systemImage: "person")
                Label("\(summary.assistantMessageCount)", systemImage: "sparkles")
                Label("\(summary.toolInvocationCount)", systemImage: "hammer")
            }
            .labelStyle(.iconOnly)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
