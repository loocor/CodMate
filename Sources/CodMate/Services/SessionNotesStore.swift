import Foundation

struct SessionNote: Codable, Hashable {
    let id: String
    var title: String?
    var comment: String?
    var updatedAt: Date
}

actor SessionNotesStore {
    private var map: [String: SessionNote] = [:]
    private let url: URL

    init(fileManager: FileManager = .default) {
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("io.umate.codex", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("session-notes.json")
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: SessionNote].self, from: data)
        {
            map = decoded
        }
    }

    func note(for id: String) -> SessionNote? { map[id] }

    func upsert(id: String, title: String?, comment: String?) {
        var note = map[id] ?? SessionNote(id: id, title: nil, comment: nil, updatedAt: Date())
        note.title = title
        note.comment = comment
        note.updatedAt = Date()
        map[id] = note
        save()
    }

    func remove(id: String) {
        map.removeValue(forKey: id)
        save()
    }

    func all() -> [String: SessionNote] { map }

    private func save() {
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: url, options: .atomic) }
    }
}
