import Foundation

actor SessionIndexer {
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let cache = NSCache<NSURL, CacheEntry>()

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

        var summaries: [SessionSummary] = []

        for url in sessionFiles {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            if let cached = cachedSummary(for: url as NSURL, modificationDate: values.contentModificationDate) {
                summaries.append(cached)
                continue
            }

            var summaryBuilder = SessionSummaryBuilder()
            if let size = values.fileSize {
                summaryBuilder.setFileSize(UInt64(size))
            }

            guard let summary = try buildSummary(for: url, builder: &summaryBuilder) else { continue }
            store(summary: summary, for: url as NSURL, modificationDate: values.contentModificationDate)
            summaries.append(summary)
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

    private func buildSummary(for url: URL, builder: inout SessionSummaryBuilder) throws -> SessionSummary? {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return nil
        }

        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        var lastError: Error?
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn {
                slice = slice.dropLast()
            }
            guard !slice.isEmpty else { continue }

            do {
                let row = try decoder.decode(SessionRow.self, from: Data(slice))
                builder.observe(row)
            } catch {
                lastError = error
                continue
            }
        }

        if let summary = builder.build(for: url) {
            return summary
        }

        if let error = lastError {
            throw error
        }

        return nil
    }

    // MARK: - Fulltext scanning
    func fileContains(url: URL, term: String) async -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        let lowered = term.lowercased()
        if let s = String(data: data, encoding: .utf8)?.lowercased() {
            return s.contains(lowered)
        }
        return false
    }
}
