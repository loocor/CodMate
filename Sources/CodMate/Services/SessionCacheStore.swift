import Foundation

actor SessionCacheStore {
    private struct Entry: Codable {
        let path: String
        let modificationTime: TimeInterval?
        let summary: SessionSummary
    }

    private var map: [String: Entry] = [:] // key: file path
    private let url: URL
    private var needsSave = false

    init(fileManager: FileManager = .default) {
        let dir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodMate", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("sessionIndex-v1.json")
        
        // 在 init 中同步加载缓存（init 是 nonisolated 的）
        if let data = try? Data(contentsOf: url),
           let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            map = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        }
    }

    private func saveIfNeededDebounced() {
        guard needsSave else { return }
        needsSave = false
        let entries = Array(map.values)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func get(path: String, modificationDate: Date?) -> SessionSummary? {
        guard let entry = map[path] else { return nil }
        let mt = modificationDate?.timeIntervalSince1970
        if entry.modificationTime == mt {
            return entry.summary
        }
        return nil
    }

    func set(path: String, modificationDate: Date?, summary: SessionSummary) {
        let mt = modificationDate?.timeIntervalSince1970
        map[path] = Entry(path: path, modificationTime: mt, summary: summary)
        needsSave = true
        saveIfNeededDebounced()
    }
}

