import Foundation

struct SessionNote: Codable, Hashable {
    let id: String
    var title: String?
    var comment: String?
    var projectId: String?
    var profileId: String?
    var updatedAt: Date
}

// Stores notes as individual JSON files under a notes directory that sits
// alongside the sessions directory. Provides migration from the legacy
// Application Support JSON file when the notes directory is empty.
actor SessionNotesStore {
    private let fm: FileManager
    private var notesRoot: URL
    private let legacyURL: URL

    init(notesRoot: URL? = nil, fileManager: FileManager = .default) {
        self.fm = fileManager
        // Default to ~/.codmate/notes (centralized CodMate data root)
        let home = fileManager.homeDirectoryForCurrentUser
        let defaultRoot = home.appendingPathComponent(".codmate", isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        self.notesRoot = notesRoot ?? defaultRoot

        // Legacy single-file JSON in Application Support (existing path in project)
        let legacyDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ai.umate.codmate", isDirectory: true)
        self.legacyURL = legacyDir.appendingPathComponent("session-notes.json")

        // First migrate from legacy ~/.codex/notes directory if present
        Self.migrateLegacyNotesDirectoryIfNeeded(fm: fm, newNotesRoot: self.notesRoot)
        try? fm.createDirectory(at: self.notesRoot, withIntermediateDirectories: true)
        // During init, actor isolation isn't available; use static helper for old single-file JSON
        Self.performMigration(fm: fm, notesRoot: self.notesRoot, legacyURL: self.legacyURL)
    }

    // Compute default notes directory from sessions root
    static func defaultNotesRoot(for sessionsRoot: URL) -> URL {
        // Kept for compatibility, but now always prefers centralized ~/.codmate/notes
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codmate", isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
    }

    // Update notes root (e.g., when sessions root changes)
    func updateRoot(to newRoot: URL) {
        if newRoot == notesRoot { return }
        notesRoot = newRoot
        try? fm.createDirectory(at: notesRoot, withIntermediateDirectories: true)
        migrateFromLegacyIfNeeded()
    }

    // MARK: - Public API
    func note(for id: String) -> SessionNote? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionNote.self, from: data)
    }

    func upsert(id: String, title: String?, comment: String?) {
        var note = (note(for: id) ?? SessionNote(id: id, title: nil, comment: nil, projectId: nil, profileId: nil, updatedAt: Date()))
        note.title = title
        note.comment = comment
        note.updatedAt = Date()
        if let data = try? JSONEncoder().encode(note) {
            let url = fileURL(for: id)
            try? data.write(to: url, options: .atomic)
        }
    }

    func assignProject(id: String, projectId: String?, profileId: String? = nil) {
        var note = (note(for: id) ?? SessionNote(id: id, title: nil, comment: nil, projectId: nil, profileId: nil, updatedAt: Date()))
        note.projectId = projectId
        if let profileId { note.profileId = profileId }
        note.updatedAt = Date()
        if let data = try? JSONEncoder().encode(note) {
            let url = fileURL(for: id)
            try? data.write(to: url, options: .atomic)
        }
    }

    func remove(id: String) {
        let url = fileURL(for: id)
        // Move to Trash rather than hard delete to allow recovery
        var resulting: NSURL?
        if fm.fileExists(atPath: url.path) {
            try? fm.trashItem(at: url, resultingItemURL: &resulting)
        }
    }

    func all() -> [String: SessionNote] {
        var result: [String: SessionNote] = [:]
        guard let en = fm.enumerator(at: notesRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return [:]
        }
        for case let url as URL in en {
            if url.pathExtension.lowercased() != "json" { continue }
            if let data = try? Data(contentsOf: url), let n = try? JSONDecoder().decode(SessionNote.self, from: data) {
                result[n.id] = n
            }
        }
        return result
    }

    // MARK: - Helpers
    private func migrateFromLegacyIfNeeded() {
        Self.performMigration(fm: fm, notesRoot: notesRoot, legacyURL: legacyURL)
    }

    private static func performMigration(fm: FileManager, notesRoot: URL, legacyURL: URL) {
        // Only migrate when notes directory is empty and legacy file exists
        let existing = (try? fm.contentsOfDirectory(at: notesRoot, includingPropertiesForKeys: nil)) ?? []
        guard existing.first(where: { $0.pathExtension.lowercased() == "json" }) == nil else { return }
        guard fm.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let decoded = try? JSONDecoder().decode([String: SessionNote].self, from: data) else { return }
        for (id, note) in decoded {
            if let d = try? JSONEncoder().encode(note) {
                let safe = safeFileNameStatic(for: id)
                let url = notesRoot.appendingPathComponent(safe + ".json")
                try? d.write(to: url, options: .atomic)
            }
        }
        // Keep legacy file as-is; do not delete to avoid destructive surprises
    }

    /// Migrate notes directory from old `~/.codex/notes` to new `~/.codmate/notes`.
    /// Prefer moving the entire directory if the destination is missing or empty; otherwise copy only missing files.
    private static func migrateLegacyNotesDirectoryIfNeeded(fm: FileManager, newNotesRoot: URL) {
        let home = fm.homeDirectoryForCurrentUser
        let oldRoot = home.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: oldRoot.path, isDirectory: &isDir), isDir.boolValue else { return }

        // Determine if new root exists and is empty
        var newIsDir: ObjCBool = false
        let newExists = fm.fileExists(atPath: newNotesRoot.path, isDirectory: &newIsDir) && newIsDir.boolValue
        let newIsEmpty: Bool = {
            guard newExists else { return true }
            do { return try fm.contentsOfDirectory(atPath: newNotesRoot.path).isEmpty } catch { return true }
        }()

        if !newExists || newIsEmpty {
            do {
                if newExists && newIsEmpty { try? fm.removeItem(at: newNotesRoot) }
                try fm.moveItem(at: oldRoot, to: newNotesRoot)
                return
            } catch {
                // Fallback to copy flow
            }
        }
        // Ensure destination exists for copy
        try? fm.createDirectory(at: newNotesRoot, withIntermediateDirectories: true)
        if let en = fm.enumerator(at: oldRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                if url.pathExtension.lowercased() != "json" { continue }
                let dest = newNotesRoot.appendingPathComponent(url.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: url, to: dest)
                }
            }
        }
    }

    private func fileURL(for id: String) -> URL {
        let safe = safeFileName(for: id) + ".json"
        return notesRoot.appendingPathComponent(safe, isDirectory: false)
    }

    private func safeFileName(for id: String) -> String {
        // Sanitize and add stable short hash suffix to avoid collisions
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        let sanitized = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: String(), { $0.append($1) })
        let hash = fnv1a32(id)
        return sanitized + "-" + String(format: "%08x", hash)
    }

    private static func safeFileNameStatic(for id: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        let sanitized = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: String(), { $0.append($1) })
        let hash = fnv1a32Static(id)
        return sanitized + "-" + String(format: "%08x", hash)
    }

    private func fnv1a32(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h ^= UInt32(b); h = h &* 16777619 }
        return h
    }

    private static func fnv1a32Static(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h ^= UInt32(b); h = h &* 16777619 }
        return h
    }
}
