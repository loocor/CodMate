import Foundation

// Simple disk cache for session summaries
actor SessionCacheStore {
    private var cache: [String: (modificationDate: Date?, summary: SessionSummary)] = [:]
    
    func get(path: String, modificationDate: Date?) -> SessionSummary? {
        guard let entry = cache[path] else { return nil }
        if entry.modificationDate == modificationDate {
            return entry.summary
        }
        return nil
    }
    
    func set(path: String, modificationDate: Date?, summary: SessionSummary) {
        cache[path] = (modificationDate, summary)
    }
}

actor SessionIndexer {
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let cache = NSCache<NSURL, CacheEntry>()
    private let diskCache = SessionCacheStore()

    private final class CacheEntry {
        let modificationDate: Date?
        let summary: SessionSummary

        init(modificationDate: Date?, summary: SessionSummary) {
            self.modificationDate = modificationDate
            self.summary = summary
        }
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func refreshSessions(root: URL, scope: SessionLoadScope) async throws -> [SessionSummary] {
        let sessionFiles = try sessionFileURLs(at: root, scope: scope)
        guard !sessionFiles.isEmpty else { return [] }

        let cpuCount = max(2, ProcessInfo.processInfo.processorCount)
        var summaries: [SessionSummary] = []
        summaries.reserveCapacity(sessionFiles.count)

        try await withThrowingTaskGroup(of: SessionSummary?.self) { group in
            var iterator = sessionFiles.makeIterator()

            func addNextTasks(_ n: Int) {
                for _ in 0..<n {
                    guard let url = iterator.next() else { return }
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                        guard values.isRegularFile == true else { return nil }

                        // In-memory cache
                        if let cached = await self.cachedSummary(for: url as NSURL, modificationDate: values.contentModificationDate) {
                            return cached
                        }
                        // Disk cache
                        if let disk = await self.diskCache.get(path: url.path, modificationDate: values.contentModificationDate) {
                            await self.store(summary: disk, for: url as NSURL, modificationDate: values.contentModificationDate)
                            return disk
                        }

                        var builder = SessionSummaryBuilder()
                        if let size = values.fileSize { builder.setFileSize(UInt64(size)) }
                        // Seed updatedAt by fs metadata to avoid full scan for recency
                        if let m = values.contentModificationDate { builder.seedLastUpdated(m) }
                        guard let summary = try await self.buildSummaryFast(for: url, builder: &builder) else { return nil }
                        await self.store(summary: summary, for: url as NSURL, modificationDate: values.contentModificationDate)
                        await self.diskCache.set(path: url.path, modificationDate: values.contentModificationDate, summary: summary)
                        return summary
                    }
                }
            }

            addNextTasks(cpuCount)

            while let result = try await group.next() {
                if let s = result { summaries.append(s) }
                addNextTasks(1)
            }
        }

        return summaries
    }

    func invalidate(url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func invalidateAll() {
        cache.removeAllObjects()
    }

    // MARK: - Private

    private func cachedSummary(for key: NSURL, modificationDate: Date?) -> SessionSummary? {
        guard let entry = cache.object(forKey: key) else {
            return nil
        }
        if entry.modificationDate == modificationDate {
            return entry.summary
        }
        return nil
    }

    private func store(summary: SessionSummary, for key: NSURL, modificationDate: Date?) {
        let entry = CacheEntry(modificationDate: modificationDate, summary: summary)
        cache.setObject(entry, forKey: key)
    }

    private func sessionFileURLs(at root: URL, scope: SessionLoadScope) throws -> [URL] {
        var urls: [URL] = []
        let (base, _): (URL, Int) = {
            let cal = Calendar.current
            switch scope {
            case .today:
                let d = cal.startOfDay(for: Date())
                let comps = cal.dateComponents([.year, .month, .day], from: d)
                var u = root.appendingPathComponent("\(comps.year!)", isDirectory: true)
                u.appendPathComponent("\(comps.month!)", isDirectory: true)
                u.appendPathComponent("\(comps.day!)", isDirectory: true)
                return (u, 3)
            case let .day(d):
                let day = cal.startOfDay(for: d)
                let comps = cal.dateComponents([.year, .month, .day], from: day)
                var u = root.appendingPathComponent("\(comps.year!)", isDirectory: true)
                u.appendPathComponent("\(comps.month!)", isDirectory: true)
                u.appendPathComponent("\(comps.day!)", isDirectory: true)
                return (u, 3)
            case let .month(d):
                let comps = cal.dateComponents([.year, .month], from: d)
                var u = root.appendingPathComponent("\(comps.year!)", isDirectory: true)
                u.appendPathComponent("\(comps.month!)", isDirectory: true)
                return (u, 2)
            case .all:
                return (root, 0)
            }
        }()

        let enumeratorURL = base
        var isDir: ObjCBool = false
        if !fileManager.fileExists(atPath: enumeratorURL.path, isDirectory: &isDir) || !isDir.boolValue {
            return []
        }

        guard let enumerator = fileManager.enumerator(
            at: enumeratorURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "jsonl" {
                urls.append(fileURL)
            }
        }
        return urls
    }

    // Sidebar: month daily counts without parsing content (fast)
    func computeCalendarCounts(root: URL, monthStart: Date, dimension: DateDimension) async -> [Int: Int] {
        var counts: [Int: Int] = [:]
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: monthStart)
        guard let year = comps.year, let month = comps.month else { return [:] }
        var monthURL = root.appendingPathComponent("\(year)", isDirectory: true)
        monthURL.appendPathComponent("\(month)", isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: monthURL, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        
        // Collect URLs synchronously first to avoid Swift 6 async/iterator issues
        let urls = enumerator.compactMap { $0 as? URL }
        
        for url in urls {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            switch dimension {
            case .created:
                if let day = Int(url.deletingLastPathComponent().lastPathComponent) { counts[day, default: 0] += 1 }
            case .updated:
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                if let date = values?.contentModificationDate, cal.isDate(date, equalTo: monthStart, toGranularity: .month) {
                    let day = cal.component(.day, from: date)
                    counts[day, default: 0] += 1
                }
            }
        }
        return counts
    }

    // Sidebar: collect cwd counts using disk cache or quick head-scan
    func collectCWDCounts(root: URL) async -> [String: Int] {
        var result: [String: Int] = [:]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        
        // Collect URLs synchronously first to avoid Swift 6 async/iterator issues
        let urls = enumerator.compactMap { $0 as? URL }
        
        await withTaskGroup(of: (String, Int)?.self) { group in
            for url in urls {
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    let m = values?.contentModificationDate
                    if let cached = await self.diskCache.get(path: url.path, modificationDate: m), !cached.cwd.isEmpty {
                        return (cached.cwd, 1)
                    }
                    if let cwd = self.fastExtractCWD(url: url) { return (cwd, 1) }
                    return nil
                }
            }
            for await item in group {
                if let (cwd, inc) = item { result[cwd, default: 0] += inc }
            }
        }
        return result
    }

    nonisolated private func fastExtractCWD(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true).prefix(200) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            if let row = try? decoder.decode(SessionRow.self, from: Data(slice)) {
                switch row.kind {
                case let .sessionMeta(p): return p.cwd
                case let .turnContext(p): if let c = p.cwd { return c }
                default: break
                }
            }
        }
        return nil
    }

    private func buildSummaryFast(for url: URL, builder: inout SessionSummaryBuilder) throws -> SessionSummary? {
        // Memory-map file (fast and low memory overhead)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }

        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var lineCount = 0
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            // Parse first ~400 lines then stop; metadata should be captured
            if lineCount > 400 { break }
            do {
                let row = try decoder.decode(SessionRow.self, from: Data(slice))
                builder.observe(row)
            } catch {
                // Silently ignore parse errors for individual lines
            }
            lineCount += 1
        }
        // Ensure lastUpdatedAt reflects last JSON line timestamp
        if let tailDate = readTailTimestamp(url: url) {
            if builder.lastUpdatedAt == nil || (builder.lastUpdatedAt ?? .distantPast) < tailDate {
                builder.seedLastUpdated(tailDate)
            }
        }

        if let result = builder.build(for: url) { return result }
        // Fallback: full parse if we didn't capture session_meta early
        return try buildSummaryFull(for: url, builder: &builder)
    }

    private func buildSummaryFull(for url: URL, builder: inout SessionSummaryBuilder) throws -> SessionSummary? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var lastError: Error?
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            do {
                let row = try decoder.decode(SessionRow.self, from: Data(slice))
                builder.observe(row)
            } catch {
                lastError = error
            }
        }
        if let result = builder.build(for: url) { return result }
        if let error = lastError { throw error }
        return nil
    }

    // Public API for background enrichment
    func enrich(url: URL) async throws -> SessionSummary? {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var builder = SessionSummaryBuilder()
        if let size = values.fileSize { builder.setFileSize(UInt64(size)) }
        if let m = values.contentModificationDate { builder.seedLastUpdated(m) }
        if let tailDate = readTailTimestamp(url: url) { builder.seedLastUpdated(tailDate) }
        return try buildSummaryFull(for: url, builder: &builder)
    }

    // MARK: - Fulltext scanning
    func fileContains(url: URL, term: String) async -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let needle = term
        let chunkSize = 128 * 1024
        var carry = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var combined = carry
            combined.append(chunk)
            if let s = String(data: combined, encoding: .utf8), s.range(of: needle, options: .caseInsensitive) != nil {
                return true
            }
            // keep tail to catch matches across boundaries
            let keep = min(needle.utf8.count - 1, combined.count)
            carry = combined.suffix(keep)
            if Task.isCancelled { return false }
        }
        if !carry.isEmpty, let s = String(data: carry, encoding: .utf8), s.range(of: needle, options: .caseInsensitive) != nil { return true }
        return false
    }

    // MARK: - Tail timestamp helper
    private func readTailTimestamp(url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let chunkSize: UInt64 = 64 * 1024
        let offset = fileSize > chunkSize ? fileSize - chunkSize : 0
        do { try handle.seek(toOffset: offset) } catch { return nil }
        guard let buffer = try? handle.readToEnd(), !buffer.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        // Split and iterate from the end
        let lines = buffer.split(separator: newline, omittingEmptySubsequences: true)
        for var slice in lines.reversed() {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            if let row = try? decoder.decode(SessionRow.self, from: Data(slice)) {
                return row.timestamp
            }
        }
        return nil
    }

    // Global count for sidebar label
    func countAllSessions(root: URL) async -> Int {
        var total = 0
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        
        // Collect URLs synchronously first to avoid Swift 6 async/iterator issues
        let urls = enumerator.compactMap { $0 as? URL }
        
        for url in urls {
            if url.pathExtension.lowercased() == "jsonl" { total += 1 }
        }
        return total
    }
}
