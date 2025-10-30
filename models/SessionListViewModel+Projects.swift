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
            self.projectMemberships = memberships
            self.recomputeProjectCounts()
            self.applyFilters()
        }
    }

    func setSelectedProject(_ id: String?) {
        selectedProjectId = id
    }

    func assignSessions(to projectId: String?, ids: [String]) async {
        await projectsStore.assign(sessionIds: ids, to: projectId)
        let counts = await projectsStore.counts()
        let memberships = await projectsStore.membershipsSnapshot()
        await MainActor.run {
            self.projectCounts = counts
            self.projectMemberships = memberships
            self.recomputeProjectCounts()
        }
        applyFilters()
    }

    func projectCountsFromStore() -> [String: Int] { projectCounts }

    func visibleProjectCountsForDateScope() -> [String: Int] {
        var visible: [String: Int] = [:]
        let cal = Calendar.current
        let allowed = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
            $0[$1.id] = $1.sources
        }
        for s in allSessions {
            let refDate: Date =
                (dateDimension == .created) ? s.startedAt : (s.lastUpdatedAt ?? s.startedAt)
            if !selectedDays.isEmpty {
                var match = false
                for d in selectedDays {
                    if cal.isDate(refDate, inSameDayAs: d) {
                        match = true
                        break
                    }
                }
                if !match { continue }
            } else if let day = selectedDay {
                if !cal.isDate(refDate, inSameDayAs: day) { continue }
            }
            if let pid = projectMemberships[s.id] {
                let allowedSources = allowed[pid] ?? ProjectSessionSource.allSet
                if !allowedSources.contains(s.source.projectSource) { continue }
                visible[pid, default: 0] += 1
            }
        }
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
        let cal = Calendar.current
        var count = 0
        for s in allSessions {
            let ref: Date =
                (dateDimension == .created) ? s.startedAt : (s.lastUpdatedAt ?? s.startedAt)
            if !selectedDays.isEmpty {
                var match = false
                for d in selectedDays {
                    if cal.isDate(ref, inSameDayAs: d) {
                        match = true
                        break
                    }
                }
                if !match { continue }
            } else if let day = selectedDay {
                if !cal.isDate(ref, inSameDayAs: day) { continue }
            }
            count += 1
        }
        return count
    }

    // Calendar helper: days within the given month that have at least one session
    // belonging to the currently selected project (including descendants), respecting
    // each project's allowed sources. Returns nil when no project is selected.
    func calendarEnabledDaysForSelectedProject(monthStart: Date, dimension: DateDimension) -> Set<Int>? {
        guard let pid = selectedProjectId else { return nil }
        let cal = Calendar.current

        // Build allowed project set: include descendants of selected project
        let descendants = Set(self.collectDescendants(of: pid, in: self.projects))
        let allowedProjects: Set<String> = Set([pid] + Array(descendants))

        // Resolve allowed sources per project
        let allowedSourcesByProject = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
            $0[$1.id] = $1.sources
        }

        var days: Set<Int> = []
        for s in allSessions {
            guard let assigned = projectMemberships[s.id], allowedProjects.contains(assigned) else { continue }
            let allowed = allowedSourcesByProject[assigned] ?? ProjectSessionSource.allSet
            if !allowed.contains(s.source.projectSource) { continue }
            let ref: Date = (dimension == .created) ? s.startedAt : (s.lastUpdatedAt ?? s.startedAt)
            guard cal.isDate(ref, equalTo: monthStart, toGranularity: .month) else { continue }
            days.insert(cal.component(.day, from: ref))
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
        if selectedProjectId == id { selectedProjectId = nil }
        applyFilters()
    }

    func deleteProjectCascade(id: String) async {
        let list = await projectsStore.listProjects()
        let ids = collectDescendants(of: id, in: list) + [id]
        for pid in ids { await projectsStore.deleteProject(id: pid) }
        await loadProjects()
        if let sel = selectedProjectId, ids.contains(sel) { selectedProjectId = nil }
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
        if selectedProjectId == id { selectedProjectId = nil }
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
            self.projectMemberships = memberships
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
