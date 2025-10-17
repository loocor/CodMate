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

    func refreshSessions(root: URL) async throws -> [SessionSummary] {
        let sessionFiles = try sessionFileURLs(at: root)
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
                        if let cached = self.cachedSummary(for: url as NSURL, modificationDate: values.contentModificationDate) {
                            return cached
                        }
                        // Disk cache
                        if let disk = await self.diskCache.get(path: url.path, modificationDate: values.contentModificationDate) {
                            self.store(summary: disk, for: url as NSURL, modificationDate: values.contentModificationDate)
                            return disk
                        }

                        var builder = SessionSummaryBuilder()
                        if let size = values.fileSize { builder.setFileSize(UInt64(size)) }
                        // Seed updatedAt by fs metadata to avoid full scan for recency
                        if let m = values.contentModificationDate { builder.seedLastUpdated(m) }
                        guard let summary = try self.buildSummaryFast(for: url, builder: &builder) else { return nil }
                        self.store(summary: summary, for: url as NSURL, modificationDate: values.contentModificationDate)
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

    private nonisolated func cachedSummary(for key: NSURL, modificationDate: Date?) -> SessionSummary? {
        guard let entry = cache.object(forKey: key) else {
            return nil
        }
        if entry.modificationDate == modificationDate {
            return entry.summary
        }
        return nil
    }

    private nonisolated func store(summary: SessionSummary, for key: NSURL, modificationDate: Date?) {
        let entry = CacheEntry(modificationDate: modificationDate, summary: summary)
        cache.setObject(entry, forKey: key)
    }

    private func sessionFileURLs(at root: URL) throws -> [URL] {
        var urls: [URL] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "jsonl" {
                urls.append(fileURL)
            }
        }
        return urls
    }

    private nonisolated func buildSummaryFast(for url: URL, builder: inout SessionSummaryBuilder) throws -> SessionSummary? {
        // Memory-map file (fast and low memory overhead)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }

        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var lineCount = 0
        var lastError: Error?
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            // Parse first ~400 lines then stop; metadata should be captured
            if lineCount > 400 { break }
            do {
                let row = try decoder.decode(SessionRow.self, from: Data(slice))
                builder.observe(row)
            } catch {
                lastError = error
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

    private nonisolated func buildSummaryFull(for url: URL, builder: inout SessionSummaryBuilder) throws -> SessionSummary? {
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
    private nonisolated func readTailTimestamp(url: URL) -> Date? {
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
}
