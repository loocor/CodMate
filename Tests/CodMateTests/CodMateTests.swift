import XCTest
@testable import CodMate

final class CodMateTests: XCTestCase {
    func testSessionSummaryMatching() throws {
        let summary = SessionSummary(
            id: "session-1",
            fileURL: URL(fileURLWithPath: "/tmp/session-1.jsonl"),
            fileSizeBytes: 1024,
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(60),
            cliVersion: "0.46.0",
            cwd: "/Users/test/project",
            originator: "codex_cli",
            instructions: "Implement feature X",
            model: "gpt-5-codex",
            approvalPolicy: "on-request",
            userMessageCount: 3,
            assistantMessageCount: 4,
            toolInvocationCount: 1,
            responseCounts: ["message": 2],
            turnContextCount: 2,
            eventCount: 10,
            lineCount: 20,
            lastUpdatedAt: Date()
        )

        XCTAssertTrue(summary.matches(search: "feature"))
        XCTAssertTrue(summary.matches(search: "codex"))
        XCTAssertFalse(summary.matches(search: "nonexistent"))
    }

    func testCalendarCountsHandlesZeroPaddedMonth() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let yearURL = tempRoot.appendingPathComponent("2025", isDirectory: true)
        let monthURL = yearURL.appendingPathComponent("09", isDirectory: true)
        let dayURL = monthURL.appendingPathComponent("17", isDirectory: true)
        try fileManager.createDirectory(at: dayURL, withIntermediateDirectories: true)

        let fileURL = dayURL.appendingPathComponent("session.jsonl")
        try "log".data(using: .utf8)?.write(to: fileURL)

        let cal = Calendar.current
        let monthStart = cal.date(from: DateComponents(year: 2025, month: 9, day: 1))!

        let indexer = SessionIndexer()
        let counts = await indexer.computeCalendarCounts(
            root: tempRoot, monthStart: monthStart, dimension: .created)

        XCTAssertEqual(counts[17], 1)
    }

    func testRefreshSessionsLoadsFromZeroPaddedDirectories() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let yearURL = tempRoot.appendingPathComponent("2025", isDirectory: true)
        let monthURL = yearURL.appendingPathComponent("09", isDirectory: true)
        let dayURL = monthURL.appendingPathComponent("07", isDirectory: true)
        try fileManager.createDirectory(at: dayURL, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let timestamp = formatter.string(from: Date(timeIntervalSince1970: 0))

        let sessionRow = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"session-zero-pad","timestamp":"\(timestamp)","cwd":"/tmp/project","originator":"codex_cli","cli_version":"0.1.0","instructions":"Test"}}
"""
        let fileURL = dayURL.appendingPathComponent("session.jsonl")
        try sessionRow.data(using: .utf8)?.write(to: fileURL)

        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2025
        components.month = 9
        components.day = 7
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let day = calendar.date(from: components)!

        let indexer = SessionIndexer()
        let summaries = try await indexer.refreshSessions(root: tempRoot, scope: .day(day))

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.id, "session-zero-pad")
    }
}
