import Foundation

/// Handles custom codmate:// URLs dispatched via NSWorkspace/open.
@MainActor
enum ExternalURLRouter {
    static func handle(_ urls: [URL]) {
        for url in urls {
            handle(url)
        }
    }

    static func handle(_ url: URL) {
        print("🔗 [ExternalURLRouter] Handling URL: \(url.absoluteString)")
        guard url.scheme?.lowercased() == "codmate" else {
            print("⚠️ [ExternalURLRouter] Invalid scheme: \(url.scheme ?? "nil")")
            return
        }
        switch (url.host ?? "").lowercased() {
        case "notify":
            print("📬 [ExternalURLRouter] Processing notification")
            handleNotify(url)
        default:
            print("⚠️ [ExternalURLRouter] Unknown host: \(url.host ?? "nil")")
            break
        }
    }

    private static func handleNotify(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = components.queryItems ?? []
        guard let source = NotificationSource(rawValue: (items.first(where: { $0.name == "source" })?.value ?? "").lowercased()) else { return }
        let eventName = (items.first(where: { $0.name == "event" })?.value ?? "").lowercased()
        let title = decodeQueryValue(items: items, preferred: ["title", "title64"])
        let body = decodeQueryValue(items: items, preferred: ["body", "body64"])
        let threadId = items.first(where: { $0.name == "thread" || $0.name == "threadId" })?.value
        guard let descriptor = NotificationDescriptor.make(
            source: source,
            eventName: eventName,
            providedTitle: title,
            providedBody: body,
            providedThreadId: threadId
        ) else { return }
        Task { @MainActor in
            await SystemNotifier.shared.notify(
                title: descriptor.title,
                body: descriptor.body,
                threadId: descriptor.threadId
            )
        }
    }

    private static func decodeQueryValue(items: [URLQueryItem], preferred keys: [String]) -> String? {
        for key in keys {
            if let value = items.first(where: { $0.name == key })?.value {
                if key.hasSuffix("64"), let decoded = decodeBase64(value) { return decoded }
                if !key.hasSuffix("64") { return value }
            }
        }
        return nil
    }

    private static func decodeBase64(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private enum NotificationSource: String {
    case claude
    case codex
}

private struct NotificationDescriptor {
    let title: String
    let body: String
    let threadId: String?

    static func make(
        source: NotificationSource,
        eventName: String,
        providedTitle: String?,
        providedBody: String?,
        providedThreadId: String?
    ) -> NotificationDescriptor? {
        switch source {
        case .claude:
            return makeClaudeDescriptor(eventName: eventName, providedTitle: providedTitle, providedBody: providedBody, providedThreadId: providedThreadId)
        case .codex:
            return makeCodexDescriptor(eventName: eventName, providedTitle: providedTitle, providedBody: providedBody, providedThreadId: providedThreadId)
        }
    }

    private static func makeClaudeDescriptor(
        eventName: String,
        providedTitle: String?,
        providedBody: String?,
        providedThreadId: String?
    ) -> NotificationDescriptor? {
        guard let event = ClaudeEvent(rawValue: eventName) else { return nil }
        let defaults = event.defaults
        let title = providedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? defaults.title
        let body = providedBody?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? defaults.body
        let thread = providedThreadId?.nonEmpty ?? defaults.threadId
        return NotificationDescriptor(title: title, body: body, threadId: thread)
    }

    private static func makeCodexDescriptor(
        eventName: String,
        providedTitle: String?,
        providedBody: String?,
        providedThreadId: String?
    ) -> NotificationDescriptor? {
        guard let event = CodexEvent(rawValue: eventName) else { return nil }
        let defaults = event.defaults
        let title = providedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? defaults.title
        let body = providedBody?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? defaults.body
        let thread = providedThreadId?.nonEmpty ?? defaults.threadId
        return NotificationDescriptor(title: title, body: body, threadId: thread)
    }

    private enum ClaudeEvent: String {
        case permission
        case complete
        case test

        var defaults: (title: String, body: String, threadId: String) {
            switch self {
            case .permission:
                return ("Claude", "Claude requires approval. Return to the Claude window to respond.", "claude-permission")
            case .complete:
                return ("Claude", "Claude finished its current task.", "claude-complete")
            case .test:
                return ("CodMate", "Claude notifications self-test", "claude-test")
            }
        }
    }

    private enum CodexEvent: String {
        case turncomplete
        case test

        var defaults: (title: String, body: String, threadId: String) {
            switch self {
            case .turncomplete:
                return ("Codex", "Codex turn complete.", "codex-thread")
            case .test:
                return ("CodMate", "Codex notifications self-test", "codex-test")
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
