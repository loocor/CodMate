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
}
