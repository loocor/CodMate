import Foundation

@MainActor
extension SessionListViewModel {
    func loadProjects() async {
        var list = await projectsStore.listProjects()
        if list.isEmpty {
            let cfg = await configService.listProjects()
            if !cfg.isEmpty {
                for p in cfg { await projectsStore.upsertProject(p) }
                list = await projectsStore.listProjects()
            }
        }
        let counts = await projectsStore.counts()
        let memberships = await projectsStore.membershipsSnapshot()
        await MainActor.run {
            self.projects = list
            self.projectCounts = counts
            self.setProjectMemberships(memberships)
            self.recomputeProjectCounts()
            self.invalidateProjectVisibleCountsCache()
            self.applyFilters()
        }
    }

    func setSelectedProject(_ id: String?) {
        if let id {
            selectedProjectIDs = Set([id])
        } else {
            selectedProjectIDs.removeAll()
        }
    }

    func setSelectedProjects(_ ids: Set<String>) {
        selectedProjectIDs = ids
    }

    func toggleProjectSelection(_ id: String) {
        if selectedProjectIDs.contains(id) {
            selectedProjectIDs.remove(id)
        } else {
            selectedProjectIDs.insert(id)
        }
    }

    func assignSessions(to projectId: String?, ids: [String]) async {
        await projectsStore.assign(sessionIds: ids, to: projectId)
        let counts = await projectsStore.counts()
        let memberships = await projectsStore.membershipsSnapshot()
        await MainActor.run {
            self.projectCounts = counts
            self.setProjectMemberships(memberships)
            self.recomputeProjectCounts()
        }
        applyFilters()
    }

    func projectCountsFromStore() -> [String: Int] { projectCounts }

    func visibleProjectCountsForDateScope() -> [String: Int] {
        let key = ProjectVisibleKey(
            dimension: dateDimension,
            selectedDay: selectedDay,
            selectedDays: selectedDays,
            sessionCount: allSessions.count,
            membershipVersion: projectMembershipsVersion
        )
        if let cached = cachedProjectVisibleCounts, cached.key == key {
            return cached.value
        }
        var visible: [String: Int] = [:]
        let allowed = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
            $0[$1.id] = $1.sources
        }
        let dayTargets: Set<Date>
        if !selectedDays.isEmpty {
            dayTargets = selectedDays
        } else if let single = selectedDay {
            dayTargets = [single]
        } else {
            dayTargets = []
        }
        let filterByDay = !dayTargets.isEmpty

        for session in allSessions {
            var passesDayFilter = true
            if filterByDay {
                let bucket = dayStart(for: session, dimension: dateDimension)
                passesDayFilter = dayTargets.contains(bucket)
            }
            if !passesDayFilter { continue }
            if let pid = projectMemberships[session.id] {
                let allowedSources = allowed[pid] ?? ProjectSessionSource.allSet
                if !allowedSources.contains(session.source.projectSource) { continue }
                visible[pid, default: 0] += 1
            }
        }
        cachedProjectVisibleCounts = (key, visible)
        return visible
    }

    func projectCountsDisplay() -> [String: (visible: Int, total: Int)] {
        let directVisible = visibleProjectCountsForDateScope()
        let directTotal = projectCounts
        var children: [String: [String]] = [:]
        for p in projects {
            if let parent = p.parentId { children[parent, default: []].append(p.id) }
        }
        func aggregate(for id: String, using map: inout [String: (Int, Int)]) -> (Int, Int) {
            if let cached = map[id] { return cached }
            var v = directVisible[id] ?? 0
            var t = directTotal[id] ?? 0
            for c in (children[id] ?? []) {
                let (cv, ct) = aggregate(for: c, using: &map)
                v += cv
                t += ct
            }
            map[id] = (v, t)
            return (v, t)
        }
        var memo: [String: (Int, Int)] = [:]
        var out: [String: (visible: Int, total: Int)] = [:]
        for p in projects {
            let (v, t) = aggregate(for: p.id, using: &memo)
            out[p.id] = (v, t)
        }
        return out
    }

    func visibleAllCountForDateScope() -> Int {
        let key = SessionListViewModel.VisibleCountKey(
            dimension: dateDimension,
            selectedDay: selectedDay,
            selectedDays: selectedDays,
            sessionCount: allSessions.count
        )
        if let cached = cachedVisibleCount, cached.key == key {
            return cached.value
        }

        let value: Int
        if selectedDay == nil && selectedDays.isEmpty {
            value = allSessions.count
        } else {
            let targets: Set<Date>
            if !selectedDays.isEmpty {
                targets = selectedDays
            } else if let single = selectedDay {
                targets = [single]
            } else {
                targets = []
            }
            if targets.isEmpty {
                value = allSessions.count
            } else {
                let matched = allSessions.lazy.filter { [weak self] session in
                    guard let self else { return false }
                    return targets.contains(self.dayStart(for: session, dimension: self.dateDimension))
                }
                value = matched.count
            }
        }
        cachedVisibleCount = (key, value)
        return value
    }

    // Calendar helper: days within the given month that have at least one session
    // belonging to any of the currently selected projects (including descendants), respecting
    // each project's allowed sources. Returns nil when no project is selected.
    func calendarEnabledDaysForSelectedProject(monthStart: Date, dimension: DateDimension) -> Set<Int>? {
        guard !selectedProjectIDs.isEmpty else { return nil }
        let monthKey = monthKey(for: monthStart)

        // Build allowed project set: include descendants of each selected project
        var allowedProjects = Set<String>()
        for pid in selectedProjectIDs {
            allowedProjects.insert(pid)
            allowedProjects.formUnion(collectDescendants(of: pid, in: projects))
        }

        // Resolve allowed sources per project
        let allowedSourcesByProject = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
            $0[$1.id] = $1.sources
        }

        var days: Set<Int> = []
        for session in allSessions {
            guard let assigned = projectMemberships[session.id], allowedProjects.contains(assigned) else { continue }
            let allowed = allowedSourcesByProject[assigned] ?? ProjectSessionSource.allSet
            if !allowed.contains(session.source.projectSource) { continue }
            let bucket = dayIndex(for: session)
            switch dimension {
            case .created:
                guard bucket.createdMonthKey == monthKey else { continue }
                days.insert(bucket.createdDay)
            case .updated:
                guard bucket.updatedMonthKey == monthKey else { continue }
                days.insert(bucket.updatedDay)
            }
        }
        return days
    }

    func allSessionsInSameProject(as anchor: SessionSummary) -> [SessionSummary] {
        if let pid = projectMemberships[anchor.id] {
            let allowed = projects.first(where: { $0.id == pid })?.sources ?? ProjectSessionSource.allSet
            return allSessions.filter {
                projectMemberships[$0.id] == pid && allowed.contains($0.source.projectSource)
            }
        }
        return allSessions
    }

    func createOrUpdateProject(_ project: Project) async {
        await projectsStore.upsertProject(project)
        await loadProjects()
    }

    func deleteProject(id: String) async {
        await projectsStore.deleteProject(id: id)
        await loadProjects()
        if selectedProjectIDs.contains(id) {
            selectedProjectIDs.remove(id)
        }
        applyFilters()
    }

    func deleteProjectCascade(id: String) async {
        let list = await projectsStore.listProjects()
        let ids = collectDescendants(of: id, in: list) + [id]
        for pid in ids { await projectsStore.deleteProject(id: pid) }
        await loadProjects()
        if !selectedProjectIDs.isDisjoint(with: ids) {
            selectedProjectIDs.subtract(ids)
        }
        applyFilters()
    }

    func deleteProjectMoveChildrenUp(id: String) async {
        let list = await projectsStore.listProjects()
        for p in list where p.parentId == id {
            var moved = p
            moved.parentId = nil
            await projectsStore.upsertProject(moved)
        }
        await projectsStore.deleteProject(id: id)
        await loadProjects()
        if selectedProjectIDs.contains(id) {
            selectedProjectIDs.remove(id)
        }
        applyFilters()
    }

    func collectDescendants(of id: String, in list: [Project]) -> [String] {
        var result: [String] = []
        func dfs(_ pid: String) {
            for p in list where p.parentId == pid {
                result.append(p.id)
                dfs(p.id)
            }
        }
        dfs(id)
        return result
    }

    func importMembershipsFromNotesIfNeeded(notes: [String: SessionNote]) async {
        let existing = await projectsStore.membershipsSnapshot()
        if !existing.isEmpty { return }
        var buckets: [String: [String]] = [:]
        for (sid, n) in notes { if let pid = n.projectId { buckets[pid, default: []].append(sid) } }
        guard !buckets.isEmpty else { return }
        for (pid, sids) in buckets { await projectsStore.assign(sessionIds: sids, to: pid) }
        let counts = await projectsStore.counts()
        let memberships = await projectsStore.membershipsSnapshot()
        await MainActor.run {
            self.projectCounts = counts
            self.setProjectMemberships(memberships)
            self.recomputeProjectCounts()
        }
    }

    @MainActor
    func recomputeProjectCounts() {
        var counts: [String: Int] = [:]
        let allowed = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
            $0[$1.id] = $1.sources
        }
        for session in allSessions {
            guard let pid = projectMemberships[session.id] else { continue }
            let allowedSources = allowed[pid] ?? ProjectSessionSource.allSet
            if allowedSources.contains(session.source.projectSource) {
                counts[pid, default: 0] += 1
            }
        }
        projectCounts = counts
    }
}
