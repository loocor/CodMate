import Foundation

/// Tracks real-time session activity and followup status
@MainActor
final class SessionActivityTracker: ObservableObject {
    @Published private(set) var activeUpdatingIDs: Set<String> = []
    @Published private(set) var awaitingFollowupIDs: Set<String> = []

    private var activityHeartbeat: [String: Date] = [:]
    private var fileMTimeCache: [String: Date] = [:]
    private var activityPruneTask: Task<Void, Never>?
    private var quickPulseTask: Task<Void, Never>?
    private var lastQuickPulseAt: Date = .distantPast

    init() {
        startPruneTicker()
        observeAgentCompletions()
    }

    deinit {
        activityPruneTask?.cancel()
        quickPulseTask?.cancel()
    }

    func registerHeartbeat(previous: [SessionSummary], current: [SessionSummary]) {
        var prevMap: [String: Date] = [:]
        for s in previous { if let t = s.lastUpdatedAt { prevMap[s.id] = t } }
        let now = Date()
        for s in current {
            guard let newT = s.lastUpdatedAt else { continue }
            if let oldT = prevMap[s.id], newT > oldT {
                activityHeartbeat[s.id] = now
            }
        }
        recomputeActiveIDs()
    }

    func isActivelyUpdating(_ id: String) -> Bool {
        activeUpdatingIDs.contains(id)
    }

    func isAwaitingFollowup(_ id: String) -> Bool {
        awaitingFollowupIDs.contains(id)
    }

    func markAwaitingFollowup(_ id: String) {
        awaitingFollowupIDs.insert(id)
    }

    func quickPulse(sessions: [SessionSummary]) {
        let now = Date()
        guard now.timeIntervalSince(lastQuickPulseAt) > 0.4 else { return }
        lastQuickPulseAt = now
        quickPulseTask?.cancel()

        let displayed = sessions.prefix(200)
        quickPulseTask = Task.detached { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            var modified: [String: Date] = [:]
            for s in displayed {
                let path = s.fileURL.path
                if let attrs = try? fm.attributesOfItem(atPath: path),
                    let m = attrs[.modificationDate] as? Date
                {
                    modified[s.id] = m
                }
            }
            let snapshot = modified
            await MainActor.run {
                let now = Date()
                for (id, m) in snapshot {
                    let previous = self.fileMTimeCache[id]
                    self.fileMTimeCache[id] = m
                    if let previous, m > previous {
                        self.activityHeartbeat[id] = now
                    }
                }
                self.recomputeActiveIDs()
            }
        }
    }

    func cancelPulse() {
        quickPulseTask?.cancel()
        quickPulseTask = nil
    }

    private func startPruneTicker() {
        activityPruneTask?.cancel()
        activityPruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self?.recomputeActiveIDs() }
            }
        }
    }

    private func recomputeActiveIDs() {
        let cutoff = Date().addingTimeInterval(-3.0)
        activeUpdatingIDs = Set(activityHeartbeat.filter { $0.value > cutoff }.keys)
    }

    private func observeAgentCompletions() {
        NotificationCenter.default.addObserver(
            forName: .codMateAgentCompleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? String else { return }
            Task { @MainActor in
                self?.awaitingFollowupIDs.insert(id)
            }
        }
    }
}
