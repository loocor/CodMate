import Foundation
import OSLog

actor SessionRipgrepStore {
    struct Diagnostics: Sendable {
        let cachedCoverageEntries: Int
        let cachedToolEntries: Int
        let cachedTokenEntries: Int
        let lastCoverageScan: Date?
        let lastToolScan: Date?
        let lastTokenScan: Date?
    }

    private struct CoverageCacheKey: Hashable {
        let path: String
        let monthKey: String
    }

    private struct CoverageEntry {
        let mtime: Date?
        let days: Set<Int>
    }

    private struct ToolEntry {
        let mtime: Date?
        let count: Int
    }

    private struct TokenEntry {
        let mtime: Date?
        let snapshot: TokenUsageSnapshot?
    }

    private let logger = Logger(subsystem: "io.umate.codmate", category: "RipgrepStore")
    private let decoder = FlexibleDecoders.iso8601Flexible()
    private let disk = RipgrepDiskCache()
    private let isoFormatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoFormatterPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private let monthFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        return df
    }()
    private var coverageCache: [CoverageCacheKey: CoverageEntry] = [:]
    private var toolCache: [String: ToolEntry] = [:]
    private var tokenCache: [String: TokenEntry] = [:]

    private var lastCoverageScan: Date?
    private var lastToolScan: Date?
    private var lastTokenScan: Date?

    func dayCoverage(for monthStart: Date, sessions: [SessionSummary]) async -> [String: Set<Int>] {
        guard !sessions.isEmpty else { return [:] }
        let monthKey = Self.monthKeyString(for: monthStart)
        var result: [String: Set<Int>] = [:]

        // Separate sessions into cached and need-scan groups
        var needScan: [(SessionSummary, Date)] = []
        var cacheHits = 0

        for session in sessions {
            if Task.isCancelled { break }
            guard let mtime = fileModificationDate(for: session.fileURL) else {
                continue
            }
            let cacheKey = CoverageCacheKey(path: session.fileURL.path, monthKey: monthKey)
            if let cached = coverageCache[cacheKey], Self.datesEqual(cached.mtime, mtime) {
                result[session.id] = cached.days
                cacheHits += 1
                continue
            }
            // Try disk cache
            if let days = await disk.getCoverage(path: cacheKey.path, monthKey: cacheKey.monthKey, mtime: mtime) {
                let set = Set(days)
                coverageCache[cacheKey] = CoverageEntry(mtime: mtime, days: set)
                result[session.id] = set
                cacheHits += 1
                continue
            }
            needScan.append((session, mtime))
        }

        // Log cache performance
        if !sessions.isEmpty {
            logger.debug("Coverage cache: \(cacheHits, privacy: .public) hits, \(needScan.count, privacy: .public) misses for \(monthKey, privacy: .public)")
        }

        // Batch scan all files that need scanning
        guard !needScan.isEmpty else { return result }

        let batchResult = await scanDaysBatch(
            sessions: needScan.map { $0.0 },
            monthKey: monthKey
        )

        // Update cache and results
        for (session, mtime) in needScan {
            guard let days = batchResult[session.id] else { continue }
            let cacheKey = CoverageCacheKey(path: session.fileURL.path, monthKey: monthKey)
            coverageCache[cacheKey] = CoverageEntry(mtime: mtime, days: days)
            result[session.id] = days
            await disk.setCoverage(path: cacheKey.path, monthKey: cacheKey.monthKey, mtime: mtime, days: days)
        }

        return result
    }

    func toolInvocationCounts(for sessions: [SessionSummary]) async -> [String: Int] {
        guard !sessions.isEmpty else { return [:] }
        var output: [String: Int] = [:]
        var needScan: [(SessionSummary, Date)] = []

        // Check cache first
        for session in sessions {
            if Task.isCancelled { break }
            guard let mtime = fileModificationDate(for: session.fileURL) else { continue }
            let path = session.fileURL.path
            if let cached = toolCache[path], Self.datesEqual(cached.mtime, mtime) {
                output[session.id] = cached.count
                continue
            }
            if let persisted = await disk.getToolCount(path: path, mtime: mtime) {
                toolCache[path] = ToolEntry(mtime: mtime, count: persisted)
                output[session.id] = persisted
                continue
            }
            needScan.append((session, mtime))
        }

        // Batch scan uncached files
        guard !needScan.isEmpty else { return output }

        let batchResult = await countToolInvocationsBatch(sessions: needScan.map { $0.0 })

        // Update cache and results
        for (session, mtime) in needScan {
            if let count = batchResult[session.id] {
                toolCache[session.fileURL.path] = ToolEntry(mtime: mtime, count: count)
                output[session.id] = count
                await disk.setToolCount(path: session.fileURL.path, mtime: mtime, count: count)
            }
        }

        return output
    }

    func latestTokenUsage(in sessions: [SessionSummary]) async -> TokenUsageSnapshot? {
        guard !sessions.isEmpty else { return nil }

        for session in sessions {
            if Task.isCancelled { break }
            guard let mtime = fileModificationDate(for: session.fileURL) else { continue }
            let path = session.fileURL.path
            if let cached = tokenCache[path], Self.datesEqual(cached.mtime, mtime) {
                if let snapshot = cached.snapshot { return snapshot }
                continue
            }
            do {
                let snapshot = try await extractTokenUsage(at: session.fileURL)
                tokenCache[path] = TokenEntry(mtime: mtime, snapshot: snapshot)
                if let snapshot { return snapshot }
            } catch is CancellationError {
                return nil
            } catch {
                logger.error("Token usage scan failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    func diagnostics() async -> Diagnostics {
        Diagnostics(
            cachedCoverageEntries: coverageCache.count,
            cachedToolEntries: toolCache.count,
            cachedTokenEntries: tokenCache.count,
            lastCoverageScan: lastCoverageScan,
            lastToolScan: lastToolScan,
            lastTokenScan: lastTokenScan
        )
    }

    func resetAll() {
        coverageCache.removeAll()
        toolCache.removeAll()
        tokenCache.removeAll()
        lastCoverageScan = nil
        lastToolScan = nil
        lastTokenScan = nil
    }

    func invalidateCoverage(monthKey: String, projectPath: String? = nil) {
        if let projectPath = projectPath {
            // Invalidate only entries matching this project path
            coverageCache = coverageCache.filter { key, _ in
                !(key.monthKey == monthKey && key.path.hasPrefix(projectPath))
            }
        } else {
            // Invalidate all entries for this month
            coverageCache = coverageCache.filter { key, _ in
                key.monthKey != monthKey
            }
        }
        Task { [monthKey, projectPath] in
            await disk.invalidateCoverage(monthKey: monthKey, projectPath: projectPath)
        }
    }

    /// Invalidate coverage for specific file paths only (more precise than invalidating entire directories)
    func invalidateCoverageForFiles(_ filePaths: Set<String>, monthKey: String) {
        coverageCache = coverageCache.filter { key, _ in
            !(key.monthKey == monthKey && filePaths.contains(key.path))
        }
        // Disk invalidation for specific files
        Task { [filePaths] in
            for path in filePaths {
                await disk.invalidateCoverage(path: path)
            }
        }
    }

    /// Invalidate tool counts for specific file paths only
    func invalidateToolsForFiles(_ filePaths: Set<String>) {
        for path in filePaths {
            toolCache.removeValue(forKey: path)
        }
        Task { [filePaths] in
            for path in filePaths {
                await disk.invalidateTools(path: path)
            }
        }
    }

    func markFileModified(_ filePath: String) {
        // Remove from all caches to force rescan
        coverageCache = coverageCache.filter { $0.key.path != filePath }
        toolCache.removeValue(forKey: filePath)
        tokenCache.removeValue(forKey: filePath)
        Task { [filePath] in
            await disk.invalidateCoverage(path: filePath)
            await disk.invalidateTools(path: filePath)
        }
    }

    // MARK: - Private helpers

    /// Calculate optimal batch size based on average file size
    private func calculateBatchSize(for sessions: [SessionSummary]) -> Int {
        guard !sessions.isEmpty else { return 30 }

        // Sample up to 10 files to estimate average size
        let sampleSize = min(10, sessions.count)
        let samples = sessions.prefix(sampleSize)

        var totalBytes: UInt64 = 0
        var validSamples = 0

        for session in samples {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: session.fileURL.path),
               let fileSize = attrs[.size] as? UInt64 {
                totalBytes += fileSize
                validSamples += 1
            }
        }

        guard validSamples > 0 else { return 30 }

        let avgBytes = totalBytes / UInt64(validSamples)
        let avgKB = avgBytes / 1024

        // Dynamic batch sizing:
        // - Small files (<100KB): 50 files/batch
        // - Medium files (100-500KB): 30 files/batch
        // - Large files (>500KB): 15 files/batch
        if avgKB < 100 {
            return 50
        } else if avgKB < 500 {
            return 30
        } else {
            return 15
        }
    }

    private func scanDaysBatch(sessions: [SessionSummary], monthKey: String) async -> [String: Set<Int>] {
        guard !sessions.isEmpty else { return [:] }

        // Build file path to session ID mapping
        var pathToSessionID: [String: String] = [:]
        var filePaths: [String] = []
        for session in sessions {
            let path = session.fileURL.path
            pathToSessionID[path] = session.id
            filePaths.append(path)
        }

        // Dynamic batch size based on file sizes
        let batchSize = calculateBatchSize(for: sessions)
        let batches = stride(from: 0, to: filePaths.count, by: batchSize).map {
            Array(filePaths[$0..<min($0 + batchSize, filePaths.count)])
        }

        let start = Date()
        var allResults: [String: Set<Int>] = [:]

        for (index, batch) in batches.enumerated() {
            if Task.isCancelled { break }

            // Add delay between batches to spread CPU load
            if index > 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms delay between batches
            }

            let pattern = #"\"timestamp\"\s*:\s*\"\#(monthKey)-(?:[0-3][0-9])T[^\"]+\""#
            let args = [
                "--no-heading",
                "--with-filename",  // Include filename in output
                "--no-line-number",
                "--color", "never",
                "--pcre2",
                "--only-matching",
                pattern
            ] + batch

            do {
                let lines = try await RipgrepRunner.run(arguments: args)
                guard !lines.isEmpty else { continue }

                // Parse batch results: each line is "filepath:timestamp"
                var fileToMatches: [String: [String]] = [:]
                for line in lines {
                    guard let colonIndex = line.firstIndex(of: ":") else { continue }
                    let filePath = String(line[..<colonIndex])
                    let match = String(line[line.index(after: colonIndex)...])
                    fileToMatches[filePath, default: []].append(match)
                }

                // Convert matches to days per session
                for (filePath, matches) in fileToMatches {
                    guard let sessionID = pathToSessionID[filePath] else { continue }
                    let days = parseDays(from: matches, monthKey: monthKey)
                    if !days.isEmpty {
                        allResults[sessionID] = days
                    }
                }
            } catch is CancellationError {
                return allResults
            } catch {
                logger.error("Ripgrep batch coverage scan failed for batch: \(error.localizedDescription, privacy: .public)")
                // Continue with next batch
            }
        }

        lastCoverageScan = Date()
        let elapsed = -start.timeIntervalSinceNow
        logger.debug("Batch scanned \(sessions.count, privacy: .public) files (\(batches.count, privacy: .public) batches) for \(monthKey, privacy: .public) in \(elapsed, format: .fixed(precision: 3))s")

        return allResults
    }

    private func countToolInvocationsBatch(sessions: [SessionSummary]) async -> [String: Int] {
        guard !sessions.isEmpty else { return [:] }

        var pathToSessionID: [String: String] = [:]
        var filePaths: [String] = []
        for session in sessions {
            let path = session.fileURL.path
            pathToSessionID[path] = session.id
            filePaths.append(path)
        }

        // Dynamic batch size based on file sizes
        let batchSize = calculateBatchSize(for: sessions)
        let batches = stride(from: 0, to: filePaths.count, by: batchSize).map {
            Array(filePaths[$0..<min($0 + batchSize, filePaths.count)])
        }

        let start = Date()
        var allResults: [String: Int] = [:]

        for (index, batch) in batches.enumerated() {
            if Task.isCancelled { break }

            if index > 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            let pattern = #"\"type\"\s*:\s*\"(?:function_call|tool_call|tool_output)""#
            let args = [
                "--no-heading",
                "--with-filename",
                "--no-line-number",
                "--color", "never",
                "--pcre2",
                "--count",  // Use --count for efficiency
                pattern
            ] + batch

            do {
                let lines = try await RipgrepRunner.run(arguments: args)
                for line in lines {
                    // Parse "filepath:count" format
                    guard let colonIndex = line.firstIndex(of: ":") else { continue }
                    let filePath = String(line[..<colonIndex])
                    let countStr = String(line[line.index(after: colonIndex)...])
                    guard let count = Int(countStr),
                          let sessionID = pathToSessionID[filePath] else { continue }
                    allResults[sessionID] = count
                }
            } catch is CancellationError {
                return allResults
            } catch {
                logger.error("Ripgrep batch tool scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        lastToolScan = Date()
        let elapsed = -start.timeIntervalSinceNow
        logger.debug("Batch scanned \(sessions.count, privacy: .public) files (\(batches.count, privacy: .public) batches) for tool invocations in \(elapsed, format: .fixed(precision: 3))s")

        return allResults
    }

    private func scanDays(for url: URL, monthKey: String) async -> Set<Int>? {
        let pattern = #"\"timestamp\"\s*:\s*\"\#(monthKey)-(?:[0-3][0-9])T[^\"]+\""#
        let args = [
            "--no-heading",
            "--no-filename",
            "--no-line-number",
            "--color", "never",
            "--pcre2",
            "--only-matching",
            pattern,
            url.path
        ]
        let start = Date()
        do {
            let lines = try await RipgrepRunner.run(arguments: args)
            guard !lines.isEmpty else { return nil }
            lastCoverageScan = Date()
            logger.debug("Scanned \(url.lastPathComponent, privacy: .public) for \(monthKey, privacy: .public) in \(-start.timeIntervalSinceNow, privacy: .public)s")
            let days = parseDays(from: lines, monthKey: monthKey)
            guard !days.isEmpty else { return nil }
            return days
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("Ripgrep coverage scan failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func countToolInvocations(at url: URL) async throws -> Int {
        let pattern = #"\"type\"\s*:\s*\"(?:function_call|tool_call|tool_output)""#
        let args = [
            "--no-heading",
            "--no-filename",
            "--no-line-number",
            "--color", "never",
            "--pcre2",
            pattern,
            url.path
        ]
        let lines = try await RipgrepRunner.run(arguments: args)
        lastToolScan = Date()
        return lines.count
    }

    private func extractTokenUsage(at url: URL) async throws -> TokenUsageSnapshot? {
        let pattern = #"\"type\"\s*:\s*\"token_count""#
        let args = [
            "--no-heading",
            "--no-filename",
            "--color", "never",
            "--pcre2",
            pattern,
            url.path
        ]
        let lines = try await RipgrepRunner.run(arguments: args)
        lastTokenScan = Date()
        guard !lines.isEmpty else { return nil }

        var latest: TokenUsageSnapshot?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let row = try? decoder.decode(SessionRow.self, from: data)
            else { continue }
            guard case let .eventMessage(payload) = row.kind else { continue }
            if let snapshot = TokenUsageSnapshotBuilder.build(timestamp: row.timestamp, payload: payload) {
                latest = snapshot
            }
        }
        return latest
    }

    private func parseDays(from lines: [String], monthKey: String) -> Set<Int> {
        var days: Set<Int> = []
        for line in lines {
            guard let timestamp = extractTimestamp(from: line) else { continue }
            guard let date = parseISODate(timestamp) else { continue }
            let monthOfDate = monthFormatter.string(from: date)
            guard monthOfDate == monthKey else { continue }
            let day = Calendar.current.component(.day, from: date)
            days.insert(day)
        }
        return days
    }

    private func extractTimestamp(from line: String) -> String? {
        let prefix = "\"timestamp\":\""
        guard let range = line.range(of: prefix) else { return nil }
        let start = range.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else { return nil }
        return String(line[start..<end])
    }

    private func parseISODate(_ string: String) -> Date? {
        if let date = isoFormatterWithFractional.date(from: string) {
            return date
        }
        return isoFormatterPlain.date(from: string)
    }

    private func fileModificationDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private static func monthKeyString(for date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        let year = comps.year ?? 0
        let month = comps.month ?? 0
        return String(format: "%04d-%02d", year, month)
    }

    private static func datesEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case let (.some(a), .some(b)): return abs(a.timeIntervalSince(b)) < 0.0001
        default: return false
        }
    }
}
