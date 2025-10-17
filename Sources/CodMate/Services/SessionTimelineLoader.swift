import Foundation

struct SessionTimelineLoader {
    private let decoder: JSONDecoder

    init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(url: URL) throws -> [TimelineEvent] {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        var events: [TimelineEvent] = []
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let row = try? decoder.decode(SessionRow.self, from: Data(slice)) else { continue }
            switch row.kind {
            case .sessionMeta:
                continue
            case let .turnContext(payload):
                var parts: [String] = []
                if let model = payload.model { parts.append("model: \(model)") }
                if let ap = payload.approvalPolicy { parts.append("policy: \(ap)") }
                if let cwd = payload.cwd { parts.append("cwd: \(cwd)") }
                if let s = payload.summary, !s.isEmpty { parts.append("summary: \(s)") }
                let text = parts.joined(separator: "\n")
                events.append(TimelineEvent(id: UUID().uuidString, timestamp: row.timestamp, actor: .info, title: "Context Updated", text: text, metadata: nil))
            case let .eventMessage(payload):
                let message = payload.message ?? ""
                if payload.type == "user_message" {
                    events.append(TimelineEvent(id: UUID().uuidString, timestamp: row.timestamp, actor: .user, title: nil, text: message, metadata: nil))
                } else if payload.type == "agent_message" {
                    events.append(TimelineEvent(id: UUID().uuidString, timestamp: row.timestamp, actor: .assistant, title: nil, text: message, metadata: nil))
                } else {
                    events.append(TimelineEvent(id: UUID().uuidString, timestamp: row.timestamp, actor: .info, title: payload.type, text: message, metadata: nil))
                }
            case let .responseItem(payload):
                let type = payload.type
                if type == "message" {
                    let text = (payload.content ?? []).compactMap { $0.text }.joined(separator: "\n\n")
                    events.append(TimelineEvent(id: UUID().uuidString, timestamp: row.timestamp, actor: .assistant, title: nil, text: text, metadata: nil))
                } else if type.contains("function_call") || type.contains("tool_call") || type.contains("tool_output") {
                    var md: [String: String] = [:]
                    if let call = payload.callID { md["call_id"] = call }
                    if let name = payload.name { md["name"] = name }
                    let text = (payload.content ?? []).compactMap { $0.text }.joined(separator: "\n\n")
                    events.append(TimelineEvent(id: UUID().uuidString, timestamp: row.timestamp, actor: .tool, title: type, text: text.isEmpty ? nil : text, metadata: md.isEmpty ? nil : md))
                } else {
                    let text = (payload.summary ?? []).compactMap { $0.text }.joined(separator: "\n\n")
                    events.append(TimelineEvent(id: UUID().uuidString, timestamp: row.timestamp, actor: .info, title: type, text: text.isEmpty ? nil : text, metadata: nil))
                }
            case let .unknown(type, payload):
                events.append(TimelineEvent(id: UUID().uuidString, timestamp: row.timestamp, actor: .info, title: type, text: String(describing: payload), metadata: nil))
            }
        }
        return events
    }

    func loadInstructions(url: URL) throws -> String? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            if let row = try? decoder.decode(SessionRow.self, from: Data(slice)) {
                if case let .sessionMeta(payload) = row.kind, let i = payload.instructions, !i.isEmpty {
                    return i
                }
            }
            // early stop once we pass some reasonable number of lines
        }
        return nil
    }
}
