import Foundation

// Persistent disk cache for ripgrep-derived data.
// Stores per-file, per-month day coverage and per-file tool invocation counts.
// Keyed by absolute file path + month key (yyyy-MM) and validated by file mtime.

actor RipgrepDiskCache {
    private struct CoverageRecord: Codable, Hashable {
        let path: String
        let monthKey: String
        let mtime: TimeInterval?
        let days: [Int]
        var lastAccess: TimeInterval = Date().timeIntervalSince1970
    }

    private struct ToolRecord: Codable, Hashable {
        let path: String
        let mtime: TimeInterval?
        let count: Int
        var lastAccess: TimeInterval = Date().timeIntervalSince1970
    }

    private struct Snapshot: Codable {
        var version: Int
        var coverage: [CoverageRecord]
        var tools: [ToolRecord]
    }

    // LRU limits: prevent unbounded cache growth
    private let maxCoverageEntries = 10_000  // ~1000 sessions × 12 months × 0.8
    private let maxToolEntries = 5_000       // ~5000 unique session files

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let url: URL
    private var coverageMap: [String: CoverageRecord] = [:] // key: path|monthKey
    private var toolMap: [String: ToolRecord] = [:]        // key: path
    private var saveTask: Task<Void, Never>? = nil
    private var dirty = false

    init() {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodMate", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        self.cacheDirectory = base
        self.url = base.appendingPathComponent("rg-cache-v1.json")
        // Load synchronously in init - safe because actor hasn't started yet
        if let data = try? Data(contentsOf: url),
           let snap = try? PropertyListDecoder().decode(Snapshot.self, from: data),
           snap.version == 1 {
            for rec in snap.coverage {
                coverageMap[rec.path + "|" + rec.monthKey] = rec
            }
            for rec in snap.tools {
                toolMap[rec.path] = rec
            }
        }
    }

    private func makeKey(path: String, monthKey: String) -> String { path + "|" + monthKey }


    private func scheduleSave() {
        guard saveTask == nil else { return }
        dirty = true
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask = nil
        guard dirty else { return }
        dirty = false
        evictOldEntriesIfNeeded()
        let snap = Snapshot(
            version: 1,
            coverage: Array(coverageMap.values),
            tools: Array(toolMap.values)
        )
        if let data = try? PropertyListEncoder().encode(snap) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Evict oldest 20% of entries when exceeding size limits (LRU policy)
    private func evictOldEntriesIfNeeded() {
        // Evict coverage entries if over limit
        if coverageMap.count > maxCoverageEntries {
            let sortedByAccess = coverageMap.sorted { $0.value.lastAccess < $1.value.lastAccess }
            let keepCount = Int(Double(maxCoverageEntries) * 0.8)  // Keep 80%, evict 20%
            let toKeep = Array(sortedByAccess.suffix(keepCount))
            coverageMap = Dictionary(uniqueKeysWithValues: toKeep.map { ($0.key, $0.value) })
            dirty = true
        }

        // Evict tool entries if over limit
        if toolMap.count > maxToolEntries {
            let sortedByAccess = toolMap.sorted { $0.value.lastAccess < $1.value.lastAccess }
            let keepCount = Int(Double(maxToolEntries) * 0.8)
            let toKeep = Array(sortedByAccess.suffix(keepCount))
            toolMap = Dictionary(uniqueKeysWithValues: toKeep.map { ($0.key, $0.value) })
            dirty = true
        }
    }

    // MARK: - Coverage
    func getCoverage(path: String, monthKey: String, mtime: Date?) -> Set<Int>? {
        let key = makeKey(path: path, monthKey: monthKey)
        guard var rec = coverageMap[key] else { return nil }
        let target = mtime?.timeIntervalSince1970
        guard rec.mtime == target, !rec.days.isEmpty else { return nil }

        // Update last access time for LRU
        rec.lastAccess = Date().timeIntervalSince1970
        coverageMap[key] = rec
        dirty = true

        return Set(rec.days)
    }

    func setCoverage(path: String, monthKey: String, mtime: Date?, days: Set<Int>) {
        var rec = CoverageRecord(path: path, monthKey: monthKey, mtime: mtime?.timeIntervalSince1970, days: Array(days))
        rec.lastAccess = Date().timeIntervalSince1970
        coverageMap[makeKey(path: path, monthKey: monthKey)] = rec
        scheduleSave()
    }

    func invalidateCoverage(path: String) {
        coverageMap = coverageMap.filter { !$0.key.hasPrefix(path + "|") }
        scheduleSave()
    }

    func invalidateCoverage(monthKey: String, projectPath: String?) {
        if let base = projectPath {
            coverageMap = coverageMap.filter { key, rec in !(rec.monthKey == monthKey && rec.path.hasPrefix(base)) }
        } else {
            coverageMap = coverageMap.filter { _, rec in rec.monthKey != monthKey }
        }
        scheduleSave()
    }

    // MARK: - Tools
    func getToolCount(path: String, mtime: Date?) -> Int? {
        guard var rec = toolMap[path] else { return nil }
        let target = mtime?.timeIntervalSince1970
        guard rec.mtime == target else { return nil }

        // Update last access time for LRU
        rec.lastAccess = Date().timeIntervalSince1970
        toolMap[path] = rec
        dirty = true

        return rec.count
    }

    func setToolCount(path: String, mtime: Date?, count: Int) {
        var rec = ToolRecord(path: path, mtime: mtime?.timeIntervalSince1970, count: count)
        rec.lastAccess = Date().timeIntervalSince1970
        toolMap[path] = rec
        scheduleSave()
    }

    func invalidateTools(path: String) {
        toolMap.removeValue(forKey: path)
        scheduleSave()
    }
}

