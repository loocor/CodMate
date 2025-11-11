import Foundation

@main
struct CodMateNotifyCLI {
    static func main() {
        do {
            try run()
        } catch {
            fputs("codmate-notify: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let args = CommandLine.arguments.dropFirst()
        guard !args.isEmpty else { return }

        var payloadArg: String?
        var selfTest = false

        for arg in args {
            if arg == "--self-test" {
                selfTest = true
                continue
            }
            if payloadArg == nil {
                payloadArg = arg
            }
        }

        let request: NotificationRequest
        if let payloadArg, let parsed = NotificationRequest(jsonString: payloadArg) {
            request = parsed
        } else if selfTest {
            request = NotificationRequest(
                event: .test,
                title: "CodMate",
                body: "Codex notifications self-test",
                threadId: "codex-test"
            )
        } else {
            return
        }

        guard request.event != .ignored else { return }
        try dispatch(request: request)

        if selfTest {
            print("__CODMATE_NOTIFIED__")
        }
    }

    private static func dispatch(request: NotificationRequest) throws {
        guard let url = request.makeURL() else {
            throw NotifyError.urlEncodingFailed
        }
        // 使用 -j (隐藏启动) 而不是 -g (后台启动) 来防止 SwiftUI WindowGroup 自动创建新窗口
        // -j 参数确保应用在后台处理 URL 而不激活或显示窗口
        if try !runOpen(arguments: ["-b", bundleIdentifier, "-j", url.absoluteString]) {
            if try !runOpen(arguments: ["-j", url.absoluteString]) {
                throw NotifyError.openFailed(code: 1)
            }
        }
    }

    private static let bundleIdentifier = "ai.umate.codmate"

    @discardableResult
    private static func runOpen(arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

private enum NotifyError: LocalizedError {
    case urlEncodingFailed
    case openFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .urlEncodingFailed:
            return "Failed to encode notification URL."
        case .openFailed(let code):
            return "Unable to dispatch codmate:// URL (open exited with \(code))."
        }
    }
}

private struct NotificationRequest {
    enum Event: String {
        case turnComplete = "turncomplete"
        case test
        case ignored
    }

    let event: Event
    let title: String
    let body: String
    let threadId: String?

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        guard let payload = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            let snippet = NotificationRequest.snippet(from: jsonString)
            self.init(event: .turnComplete, title: "Codex", body: snippet, threadId: "codex-generic")
            return
        }

        let normalizedEvent = NotificationRequest.normalizedEvent(in: payload)
        guard NotificationRequest.allowedEvents.contains(normalizedEvent) else {
            self.init(event: .ignored, title: "", body: "", threadId: nil)
            return
        }

        let message = NotificationRequest.message(from: payload)
        let thread = NotificationRequest.threadId(from: payload)
        self.init(event: .turnComplete, title: "Codex", body: message, threadId: thread)
    }

    init(event: Event, title: String, body: String, threadId: String?) {
        self.event = event
        self.title = title
        self.body = body
        self.threadId = threadId
    }

    func makeURL() -> URL? {
        var components = URLComponents()
        components.scheme = "codmate"
        components.host = "notify"
        var query: [URLQueryItem] = [
            URLQueryItem(name: "source", value: "codex"),
            URLQueryItem(name: "event", value: event.rawValue)
        ]
        if let titleData = title.data(using: .utf8)?.base64EncodedString() {
            query.append(URLQueryItem(name: "title64", value: titleData))
        }
        if let bodyData = body.data(using: .utf8)?.base64EncodedString() {
            query.append(URLQueryItem(name: "body64", value: bodyData))
        }
        if let threadId, !threadId.isEmpty {
            query.append(URLQueryItem(name: "thread", value: threadId))
        }
        components.queryItems = query
        return components.url
    }

    private static func normalizedEvent(in payload: [String: Any]) -> String {
        let rawEvent =
            (payload["type"] as? String)
            ?? (payload["event"] as? String)
            ?? ""
        let allowedCharacters = CharacterSet.alphanumerics
        let filtered = rawEvent.unicodeScalars.filter { allowedCharacters.contains($0) }
        return String(filtered).lowercased()
    }

    private static func message(from payload: [String: Any]) -> String {
        let candidates = [
            "last-assistant-message",
            "assistant",
            "message"
        ]
        for key in candidates {
            if let value = payload[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return NotificationRequest.coalesce(text: value)
            }
        }
        return "Codex turn complete"
    }

    private static func threadId(from payload: [String: Any]) -> String {
        if let thread = payload["thread-id"] as? String, !thread.isEmpty {
            return "codex-\(thread)"
        }
        if let session = payload["session-id"] as? String, !session.isEmpty {
            return "codex-\(session)"
        }
        return "codex-thread"
    }

    private static func snippet(from raw: String) -> String {
        return coalesce(text: raw)
    }

    private static func coalesce(text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 240 { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 240)
        return String(trimmed[..<endIndex])
    }

    private static let allowedEvents: Set<String> = [
        "agentturncomplete",
        "turncomplete",
        "agentcompleted",
        "agentdone",
        "runcomplete",
        "rundone",
        "sessioncomplete",
        "completed"
    ]
}
private let bundleIdentifier = "ai.umate.codmate"
