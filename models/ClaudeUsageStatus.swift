import Foundation

struct ClaudeUsageStatus: Equatable {
    let updatedAt: Date
    let modelName: String?
    let contextUsedTokens: Int?
    let contextLimitTokens: Int?
    let fiveHourUsedMinutes: Double?
    let fiveHourWindowMinutes: Double
    let fiveHourResetAt: Date?
    let weeklyUsedMinutes: Double?
    let weeklyWindowMinutes: Double
    let weeklyResetAt: Date?

    init(
        updatedAt: Date,
        modelName: String?,
        contextUsedTokens: Int?,
        contextLimitTokens: Int?,
        fiveHourUsedMinutes: Double?,
        fiveHourWindowMinutes: Double = 300,
        fiveHourResetAt: Date?,
        weeklyUsedMinutes: Double?,
        weeklyWindowMinutes: Double = 10_080,
        weeklyResetAt: Date?
    ) {
        self.updatedAt = updatedAt
        self.modelName = modelName
        self.contextUsedTokens = contextUsedTokens
        self.contextLimitTokens = contextLimitTokens
        self.fiveHourUsedMinutes = fiveHourUsedMinutes
        self.fiveHourWindowMinutes = fiveHourWindowMinutes
        self.fiveHourResetAt = fiveHourResetAt
        self.weeklyUsedMinutes = weeklyUsedMinutes
        self.weeklyWindowMinutes = weeklyWindowMinutes
        self.weeklyResetAt = weeklyResetAt
    }

    private var contextProgress: Double? {
        guard
            let used = contextUsedTokens,
            let limit = contextLimitTokens,
            limit > 0
        else { return nil }
        return Double(used) / Double(limit)
    }

    private var fiveHourProgress: Double? {
        guard let used = fiveHourUsedMinutes, fiveHourWindowMinutes > 0 else { return nil }
        return used / fiveHourWindowMinutes
    }

    private var weeklyProgress: Double? {
        guard let used = weeklyUsedMinutes, weeklyWindowMinutes > 0 else { return nil }
        return used / weeklyWindowMinutes
    }

    func asProviderSnapshot() -> UsageProviderSnapshot {
        var metrics: [UsageMetricSnapshot] = []

        metrics.append(
            UsageMetricSnapshot(
                kind: .context,
                label: "Context",
                usageText: contextUsageText,
                percentText: contextPercentText,
                progress: contextProgress?.clamped01(),
                resetDate: nil,
                fallbackWindowMinutes: nil
            )
        )

        metrics.append(
            UsageMetricSnapshot(
                kind: .fiveHour,
                label: "5h limit",
                usageText: fiveHourUsageText,
                percentText: fiveHourPercentText,
                progress: fiveHourProgress?.clamped01(),
                resetDate: fiveHourResetAt,
                fallbackWindowMinutes: Int(fiveHourWindowMinutes)
            )
        )

        metrics.append(
            UsageMetricSnapshot(
                kind: .weekly,
                label: "Weekly limit",
                usageText: weeklyUsageText,
                percentText: weeklyPercentText,
                progress: weeklyProgress?.clamped01(),
                resetDate: weeklyResetAt,
                fallbackWindowMinutes: Int(weeklyWindowMinutes)
            )
        )

        return UsageProviderSnapshot(
            provider: .claude,
            title: UsageProviderKind.claude.displayName,
            availability: .ready,
            metrics: metrics,
            updatedAt: updatedAt,
            statusMessage: nil
        )
    }

    private var contextUsageText: String? {
        guard let used = contextUsedTokens else { return nil }
        if let limit = contextLimitTokens {
            return "\(TokenFormatter.string(from: used)) used / \(TokenFormatter.string(from: limit)) total"
        }
        return "\(TokenFormatter.string(from: used)) used"
    }

    private var contextPercentText: String? {
        guard let ratio = contextProgress else { return nil }
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: ratio))
            ?? String(format: "%.0f%%", ratio * 100)
    }

    private var fiveHourUsageText: String? {
        guard let minutes = fiveHourUsedMinutes else { return nil }
        return "Used \(UsageDurationFormatter.string(minutes: minutes))"
    }

    private var fiveHourPercentText: String? {
        guard let progress = fiveHourProgress else { return nil }
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: progress))
            ?? String(format: "%.0f%%", progress * 100)
    }

    private var weeklyUsageText: String? {
        guard let minutes = weeklyUsedMinutes else { return nil }
        return "Used \(UsageDurationFormatter.string(minutes: minutes))"
    }

    private var weeklyPercentText: String? {
        guard let progress = weeklyProgress else { return nil }
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: progress))
            ?? String(format: "%.0f%%", progress * 100)
    }
}

private extension Double {
    func clamped01() -> Double {
        if self.isNaN { return 0 }
        return max(0, min(self, 1))
    }
}
