import Foundation

/// Stores user-provided metadata (title and comment) for sessions
actor SessionNotesStore {
    private var notes: [String: SessionNote] = [:]
    private let fileURL: URL
    
    struct SessionNote: Codable, Sendable {
        var id: String
        var title: String?
        var comment: String?
        var updatedAt: Date
    }
    
    init() {
        // Store notes in Application Support directory
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codmate"
        let directory = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        
        self.fileURL = directory.appendingPathComponent("session-notes.json")
        
        // Load existing notes synchronously during init
        // We can safely access notes directly during init before actor isolation begins
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([String: SessionNote].self, from: data)
            notes = decoded
        } catch {
            print("Failed to load session notes: \(error)")
        }
    }
    
    func note(for sessionID: String) -> SessionNote? {
        notes[sessionID]
    }
    
    func upsert(id: String, title: String?, comment: String?) {
        if title == nil && comment == nil {
            notes.removeValue(forKey: id)
        } else {
            notes[id] = SessionNote(id: id, title: title, comment: comment, updatedAt: Date())
        }
        Task {
            self.save()
        }
    }
    
    func all() -> [String: SessionNote] {
        notes
    }
    
    func delete(id: String) {
        notes.removeValue(forKey: id)
        Task {
            self.save()
        }
    }
    
    private func save() {
        do {
            let data = try JSONEncoder().encode(notes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save session notes: \(error)")
        }
    }
}
