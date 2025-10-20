import Foundation

// ProjectsStore: manages project metadata and session memberships
// Layout (under ~/.codex/projects):
//  - metadata/<projectId>.json  (one file per project)
//  - memberships.json           (central mapping: { version, sessionToProject })

struct ProjectMeta: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var directory: String?
    var trustLevel: String?
    var overview: String?
    var instructions: String?
    var profileId: String?
    var profile: ProjectProfile?
    var parentId: String?
    var createdAt: Date
    var updatedAt: Date

    init(from project: Project) {
        self.id = project.id
        self.name = project.name
        self.directory = project.directory
        self.trustLevel = project.trustLevel
        self.overview = project.overview
        self.instructions = project.instructions
        self.profileId = project.profileId
        self.profile = project.profile
        self.parentId = project.parentId
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    func asProject() -> Project {
        Project(id: id, name: name, directory: directory, trustLevel: trustLevel, overview: overview, instructions: instructions, profileId: profileId, profile: profile, parentId: parentId)
    }
}

actor ProjectsStore {
    struct Paths {
        let root: URL
        let metadataDir: URL
        let membershipsURL: URL

        static func `default`(fileManager: FileManager = .default) -> Paths {
            let home = fileManager.homeDirectoryForCurrentUser
            let root = home.appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
            return Paths(
                root: root,
                metadataDir: root.appendingPathComponent("metadata", isDirectory: true),
                membershipsURL: root.appendingPathComponent("memberships.json", isDirectory: false)
            )
        }
    }

    private let fm: FileManager
    private let paths: Paths

    // runtime caches
    private var projects: [String: ProjectMeta] = [:] // id -> meta
    private var sessionToProject: [String: String] = [:] // sessionId -> projectId

    init(paths: Paths = .default(), fileManager: FileManager = .default) {
        self.fm = fileManager
        self.paths = paths
        try? fm.createDirectory(at: paths.metadataDir, withIntermediateDirectories: true)
        // Load memberships
        if let data = try? Data(contentsOf: paths.membershipsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let map = obj["sessionToProject"] as? [String: String]
        {
            self.sessionToProject = map
        }
        // Load metadata
        if let en = fm.enumerator(at: paths.metadataDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            for case let url as URL in en {
                if url.pathExtension.lowercased() != "json" { continue }
                if let data = try? Data(contentsOf: url),
                   let meta = try? dec.decode(ProjectMeta.self, from: data)
                {
                    self.projects[meta.id] = meta
                }
            }
        }
    }

    // MARK: - Public API
    func listProjects() -> [Project] { projects.values.map { $0.asProject() }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    func getProject(id: String) -> Project? { projects[id]?.asProject() }

    func upsertProject(_ p: Project) {
        var meta = projects[p.id] ?? ProjectMeta(from: p)
        meta.name = p.name
        meta.directory = p.directory
        meta.trustLevel = p.trustLevel
        meta.overview = p.overview
        meta.instructions = p.instructions
        meta.profileId = p.profileId
        meta.profile = p.profile
        meta.parentId = p.parentId
        meta.updatedAt = Date()
        projects[p.id] = meta
        saveProjectMeta(meta)
    }

    func deleteProject(id: String) {
        // Remove meta
        projects.removeValue(forKey: id)
        let metaURL = paths.metadataDir.appendingPathComponent(id + ".json")
        try? fm.removeItem(at: metaURL)
        // Unassign all sessions under this project
        var changed = false
        for (sid, pid) in sessionToProject where pid == id {
            sessionToProject.removeValue(forKey: sid)
            changed = true
        }
        if changed { saveMemberships() }
    }

    func assign(sessionIds: [String], to projectId: String?) {
        var changed = false
        for sid in sessionIds {
            let trimmed = sid.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let pid = projectId {
                if sessionToProject[trimmed] != pid { sessionToProject[trimmed] = pid; changed = true }
            } else {
                if sessionToProject.removeValue(forKey: trimmed) != nil { changed = true }
            }
        }
        if changed { saveMemberships() }
    }

    func projectId(for sessionId: String) -> String? { sessionToProject[sessionId] }
    func membershipsSnapshot() -> [String: String] { sessionToProject }
    func counts() -> [String: Int] { sessionToProject.values.reduce(into: [:]) { $0[$1, default: 0] += 1 } }

    // MARK: - Load/Save
    private func loadAll() { /* unused post-init; kept for future reload hooks */ }

    private func saveProjectMeta(_ meta: ProjectMeta) {
        try? fm.createDirectory(at: paths.metadataDir, withIntermediateDirectories: true)
        let url = paths.metadataDir.appendingPathComponent(meta.id + ".json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]; enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(meta) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveMemberships() {
        let obj: [String: Any] = [
            "version": 1,
            "sessionToProject": sessionToProject
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try? data.write(to: paths.membershipsURL, options: .atomic)
        }
    }
}
