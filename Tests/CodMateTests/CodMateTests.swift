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

    func testTimelineLoaderSkipsInstructionsAndNoise() throws {
        let fileManager = FileManager.default
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".jsonl")
        defer { try? fileManager.removeItem(at: tempURL) }

        let lines = [
            #"{"timestamp":"2025-10-18T12:00:00Z","type":"session_meta","payload":{"id":"session","timestamp":"2025-10-18T12:00:00Z","cwd":"/tmp","originator":"codex","cli_version":"0.1.0","instructions":"Task info"}}"#,
            #"{"timestamp":"2025-10-18T12:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<user_instructions>Hidden</user_instructions>"}]}}"#,
            #"{"timestamp":"2025-10-18T12:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"Need help with task","kind":"plain"}}"#,
            #"{"timestamp":"2025-10-18T12:00:03Z","type":"event_msg","payload":{"type":"token_count","message":"","kind":"plain"}}"#,
            #"{"timestamp":"2025-10-18T12:00:04Z","type":"response_item","payload":{"type":"function_call","call_id":"call1","name":"noop","content":[]}}"#,
            #"{"timestamp":"2025-10-18T12:00:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Here is the answer"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)?.write(to: tempURL)

        let loader = SessionTimelineLoader()
        let turns = try loader.load(url: tempURL)

        XCTAssertEqual(turns.count, 1)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.userMessage?.text, "Need help with task")
        XCTAssertEqual(turn.outputs.count, 1)
        XCTAssertEqual(turn.outputs.first?.text, "Here is the answer")
        XCTAssertFalse(turn.allEvents.contains { $0.text?.contains("user_instructions") == true })
    }

    func testTimelineLoaderDeduplicatesContextUpdates() throws {
        let fileManager = FileManager.default
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".jsonl")
        defer { try? fileManager.removeItem(at: tempURL) }

        let lines = [
            #"{"timestamp":"2025-10-18T12:00:00Z","type":"session_meta","payload":{"id":"session","timestamp":"2025-10-18T12:00:00Z","cwd":"/tmp","originator":"codex","cli_version":"0.1.0"}}"#,
            #"{"timestamp":"2025-10-18T12:00:01Z","type":"turn_context","payload":{"model":"gpt-5","approval_policy":"never","cwd":"/tmp","summary":""}}"#,
            #"{"timestamp":"2025-10-18T12:00:02Z","type":"turn_context","payload":{"model":"gpt-5","approval_policy":"never","cwd":"/tmp","summary":""}}"#,
            #"{"timestamp":"2025-10-18T12:00:03Z","type":"turn_context","payload":{"model":"gpt-5","approval_policy":"never","cwd":"/tmp","summary":""}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)?.write(to: tempURL)

        let loader = SessionTimelineLoader()
        let turns = try loader.load(url: tempURL)

        XCTAssertEqual(turns.count, 1)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertNil(turn.userMessage)
        XCTAssertEqual(turn.outputs.count, 1)
        XCTAssertEqual(turn.outputs.first?.repeatCount, 3)
    }

    func testTimelineLoaderKeepsEnvironmentTokenAndReasoning() throws {
        let fileManager = FileManager.default
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".jsonl")
        defer { try? fileManager.removeItem(at: tempURL) }

        let lines = [
            #"{"timestamp":"2025-10-18T12:00:00Z","type":"session_meta","payload":{"id":"session","timestamp":"2025-10-18T12:00:00Z","cwd":"/tmp","originator":"codex","cli_version":"0.1.0"}}"#,
            #"{"timestamp":"2025-10-18T12:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context><cwd>/tmp</cwd><approval_policy>never</approval_policy><sandbox_mode>workspace-write</sandbox_mode></environment_context>"}]}}"#,
            #"{"timestamp":"2025-10-18T12:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"Hello","kind":"plain"}}"#,
            #"{"timestamp":"2025-10-18T12:00:03Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"Thinking about the answer"}} "#,
            #"{"timestamp":"2025-10-18T12:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total":{"input_tokens":100,"output_tokens":20}}, "rate_limits":{"primary":{"used_percent":10.0,"window_minutes":60,"resets_in_seconds":100}}}}"#,
            #"{"timestamp":"2025-10-18T12:00:05Z","type":"event_msg","payload":{"type":"agent_message","message":"Here you go","kind":"plain"}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)?.write(to: tempURL)

        let loader = SessionTimelineLoader()
        let turns = try loader.load(url: tempURL)

        XCTAssertEqual(turns.count, 2)

        let environmentTurn = turns[0]
        XCTAssertNil(environmentTurn.userMessage)
        XCTAssertEqual(environmentTurn.outputs.first?.title, "Environment Context")
        XCTAssertEqual(environmentTurn.outputs.first?.metadata?["cwd"], "/tmp")

        let mainTurn = turns[1]
        XCTAssertEqual(mainTurn.userMessage?.text, "Hello")
        let reasoning = mainTurn.outputs.first { $0.title == "Agent Reasoning" }
        XCTAssertEqual(reasoning?.text, "Thinking about the answer")

        let token = mainTurn.outputs.first { $0.title == "Token Usage" }
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.metadata?["totalInput_tokens"], "100.0")
        XCTAssertEqual(token?.metadata?["rate_PrimaryUsed_percent"], "10.0")
    }

    func testLoadEnvironmentContextReturnsMetadata() throws {
        let fileManager = FileManager.default
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".jsonl")
        defer { try? fileManager.removeItem(at: tempURL) }

        let lines = [
            #"{"timestamp":"2025-10-18T12:00:00Z","type":"session_meta","payload":{"id":"session","timestamp":"2025-10-18T12:00:00Z","cwd":"/tmp","originator":"codex","cli_version":"0.1.0"}}"#,
            #"{"timestamp":"2025-10-18T12:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context><cwd>/tmp</cwd><approval_policy>never</approval_policy><sandbox_mode>workspace-write</sandbox_mode></environment_context>"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)?.write(to: tempURL)

        let loader = SessionTimelineLoader()
        let info = try XCTUnwrap(loader.loadEnvironmentContext(url: tempURL))
        let entries = info.entries
        XCTAssertEqual(entries.first(where: { $0.key == "cwd" })?.value, "/tmp")
        XCTAssertEqual(entries.first(where: { $0.key == "approval_policy" })?.value, "never")
        XCTAssertEqual(entries.first(where: { $0.key == "sandbox_mode" })?.value, "workspace-write")
        XCTAssertTrue(info.hasContent)
    }
}
