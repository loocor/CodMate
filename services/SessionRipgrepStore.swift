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

        for session in sessions {
            if Task.isCancelled { break }
            guard let mtime = fileModificationDate(for: session.fileURL) else {
                continue
            }
            let cacheKey = CoverageCacheKey(path: session.fileURL.path, monthKey: monthKey)
            if let cached = coverageCache[cacheKey], Self.datesEqual(cached.mtime, mtime) {
                result[session.id] = cached.days
                continue
            }
            guard let days = await scanDays(for: session.fileURL, monthKey: monthKey) else {
                continue
            }
            coverageCache[cacheKey] = CoverageEntry(mtime: mtime, days: days)
            result[session.id] = days
        }
        return result
    }

    func toolInvocationCounts(for sessions: [SessionSummary]) async -> [String: Int] {
        guard !sessions.isEmpty else { return [:] }
        var output: [String: Int] = [:]

        for session in sessions {
            if Task.isCancelled { break }
            guard let mtime = fileModificationDate(for: session.fileURL) else { continue }
            let path = session.fileURL.path
            if let cached = toolCache[path], Self.datesEqual(cached.mtime, mtime) {
                output[session.id] = cached.count
                continue
            }
            do {
                let count = try await countToolInvocations(at: session.fileURL)
                toolCache[path] = ToolEntry(mtime: mtime, count: count)
                output[session.id] = count
            } catch is CancellationError {
                return output
            } catch {
                logger.error("Tool invocation scan failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

    // MARK: - Private helpers

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
