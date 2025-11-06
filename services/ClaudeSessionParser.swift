import Foundation

struct ClaudeParsedLog {
    let summary: SessionSummary
    let rows: [SessionRow]
}

struct ClaudeSessionParser {
    private let decoder: JSONDecoder
    private let newline: UInt8 = 0x0A
    private let carriageReturn: UInt8 = 0x0D

    init() {
        self.decoder = FlexibleDecoders.iso8601Flexible()
    }

    /// Fast path: extract sessionId by scanning until a line that carries it.
    /// Avoids doing full conversion work. Returns nil if not found.
    func fastSessionId(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
            return nil
        }
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true).prefix(256) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let line = decodeLine(Data(slice)) else { continue }
            if let sid = line.sessionId, !sid.isEmpty { return sid }
        }
        return nil
    }

    func parse(at url: URL, fileSize: UInt64? = nil) -> ClaudeParsedLog? {
        // Skip agent-*.jsonl files entirely (sidechain warmup files)
        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("agent-") {
            return nil
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty else { return nil }

        var accumulator = MetadataAccumulator()
        var rows: [SessionRow] = []
        rows.reserveCapacity(256)

        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let line = decodeLine(Data(slice)) else { continue }
            let renderedText = line.message.flatMap(renderFlatText)
            let model = line.message?.model
            accumulator.consume(line, renderedText: renderedText, model: model)
            rows.append(contentsOf: convert(line))
        }

        let contextRow = accumulator.makeContextRow()
        guard let metaRow = accumulator.makeMetaRow(),
              let summary = buildSummary(
                url: url,
                fileSize: fileSize,
                metaRow: metaRow,
                contextRow: contextRow,
                additionalRows: rows,
                lastTimestamp: accumulator.lastTimestamp) else {
            return nil
        }

        var combinedRows: [SessionRow] = [metaRow]
        if let contextRow { combinedRows.append(contextRow) }
        combinedRows.append(contentsOf: rows)
        return ClaudeParsedLog(summary: summary, rows: combinedRows)
    }

    private func decodeLine(_ data: Data) -> ClaudeLogLine? {
        do {
            return try decoder.decode(ClaudeLogLine.self, from: data)
        } catch {
            return nil
        }
    }

    private func convert(_ line: ClaudeLogLine) -> [SessionRow] {
        guard let timestamp = line.timestamp else { return [] }
        guard let type = line.type else { return [] }

        // Skip sidechain messages (warmup, etc.)
        if line.isSidechain == true {
            return []
        }

        switch type {
        case "user":
            return convertUser(line, timestamp: timestamp)
        case "assistant":
            return convertAssistant(line, timestamp: timestamp)
        case "system":
            return convertSystem(line, timestamp: timestamp)
        case "summary":
            guard let summary = line.summary else { return [] }
            let payload = EventMessagePayload(
                type: "system_summary",
                message: summary,
                kind: nil,
                text: summary,
                info: nil,
                rateLimits: nil)
            return [SessionRow(timestamp: timestamp, kind: .eventMessage(payload))]
        default:
            return []
        }
    }

    private func convertUser(_ line: ClaudeLogLine, timestamp: Date) -> [SessionRow] {
        guard let message = line.message else { return [] }
        let blocks = blocks(from: message)
        var rows: [SessionRow] = []

        for block in blocks {
            switch block.type {
            case "text", nil:
                if let text = renderText(from: block), !text.isEmpty {
                    let payload = EventMessagePayload(
                        type: "user_message",
                        message: text,
                        kind: nil,
                        text: text,
                        info: nil,
                        rateLimits: nil)
                    rows.append(SessionRow(timestamp: timestamp, kind: .eventMessage(payload)))
                }
            case "tool_result":
                if let text = renderText(from: block), !text.isEmpty {
                    let item = ResponseItemPayload(
                        type: "tool_output",
                        status: nil,
                        callID: block.toolUseId,
                        name: block.name,
                        content: [ResponseContentBlock(type: "text", text: text)],
                        summary: nil,
                        encryptedContent: nil,
                        role: "system")
                    rows.append(SessionRow(timestamp: timestamp, kind: .responseItem(item)))
                }
            default:
                break
            }
        }

        if let toolResult = line.toolUseResult,
           let rendered = stringify(toolResult),
           !rendered.isEmpty {
            let payload = EventMessagePayload(
                type: "tool_output",
                message: rendered,
                kind: nil,
                text: rendered,
                info: nil,
                rateLimits: nil)
            rows.append(SessionRow(timestamp: timestamp, kind: .eventMessage(payload)))
        }

        return rows
    }

    private func convertAssistant(_ line: ClaudeLogLine, timestamp: Date) -> [SessionRow] {
        guard let message = line.message else { return [] }
        let blocks = blocks(from: message)
        var rows: [SessionRow] = []

        for block in blocks {
            switch block.type {
            case "text", nil:
                if let text = renderText(from: block), !text.isEmpty {
                    let payload = EventMessagePayload(
                        type: "agent_message",
                        message: text,
                        kind: nil,
                        text: text,
                        info: nil,
                        rateLimits: nil)
                    rows.append(SessionRow(timestamp: timestamp, kind: .eventMessage(payload)))
                }
            case "tool_use":
                let rendered = block.input.flatMap { stringify($0) } ?? ""
                let contentBlocks = rendered.isEmpty
                    ? []
                    : [ResponseContentBlock(type: "text", text: rendered)]
                let item = ResponseItemPayload(
                    type: "tool_call",
                    status: nil,
                    callID: block.id,
                    name: block.name,
                    content: contentBlocks,
                    summary: nil,
                    encryptedContent: nil,
                    role: "assistant")
                rows.append(SessionRow(timestamp: timestamp, kind: .responseItem(item)))
            default:
                break
            }
        }

        return rows
    }

    private func convertSystem(_ line: ClaudeLogLine, timestamp: Date) -> [SessionRow] {
        guard let message = line.message else { return [] }
        let text = renderFlatText(message) ?? renderText(from: blocks(from: message).first)
        guard let text, !text.isEmpty else { return [] }
        let payload = EventMessagePayload(
            type: "system_message",
            message: text,
            kind: line.subtype,
            text: text,
            info: nil,
            rateLimits: nil)
        return [SessionRow(timestamp: timestamp, kind: .eventMessage(payload))]
    }

    private func buildSummary(
        url: URL,
        fileSize: UInt64?,
        metaRow: SessionRow,
        contextRow: SessionRow?,
        additionalRows: [SessionRow],
        lastTimestamp: Date?
    ) -> SessionSummary? {
        var builder = SessionSummaryBuilder()
        builder.setSource(.claude)
        builder.setFileSize(fileSize)

        builder.observe(metaRow)
        if let contextRow { builder.observe(contextRow) }
        for row in additionalRows { builder.observe(row) }
        if let lastTimestamp { builder.seedLastUpdated(lastTimestamp) }
        builder.setModelFallback("Claude")
        return builder.build(for: url)
    }

    private func blocks(from message: ClaudeMessage) -> [ClaudeContentBlock] {
        switch message.content {
        case .string(let text):
            return [ClaudeContentBlock(type: "text", text: text, id: nil, name: nil, input: nil, toolUseId: nil, content: nil)]
        case .blocks(let blocks):
            return blocks
        case .none:
            return []
        }
    }

    private func renderFlatText(_ message: ClaudeMessage) -> String? {
        switch message.content {
        case .string(let text):
            return text
        case .blocks(let blocks):
            let rendered = blocks.compactMap { renderText(from: $0) }.joined(separator: "\n")
            return rendered.isEmpty ? nil : rendered
        case .none:
            return nil
        }
    }

    private func renderText(from block: ClaudeContentBlock?) -> String? {
        guard let block else { return nil }
        if let text = block.text, !text.isEmpty { return text }
        if let rendered = block.content.flatMap({ stringify($0) }), !rendered.isEmpty {
            return rendered
        }
        if let rendered = block.input.flatMap({ stringify($0) }), !rendered.isEmpty {
            return rendered
        }
        return nil
    }

    private func stringify(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let str):
            return str
        case .number(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .array(let array):
            let rendered = array.compactMap { stringify($0) }.joined(separator: "\n")
            return rendered.isEmpty ? nil : rendered
        case .object(let object):
            let raw = object.mapValues { $0.toAnyValue() }
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text
        case .null:
            return nil
        }
    }

    private struct MetadataAccumulator {
        var sessionId: String?
        var agentId: String?
        var version: String?
        var cwd: String?
        var model: String?
        var instructions: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        mutating func consume(_ line: ClaudeLogLine, renderedText: String?, model: String?) {
            if let sid = line.sessionId, sessionId == nil { sessionId = sid }
            if let aid = line.agentId, agentId == nil { agentId = aid }
            if let ver = line.version, version == nil { version = ver }
            if let path = line.cwd, cwd == nil { cwd = path }
            if let timestamp = line.timestamp {
                if firstTimestamp == nil || timestamp < firstTimestamp! { firstTimestamp = timestamp }
                if lastTimestamp == nil || timestamp > lastTimestamp! { lastTimestamp = timestamp }
            }
            if instructions == nil, line.isMeta == true,
               let text = renderedText, !text.isEmpty {
                instructions = text
            }
            if self.model == nil, let model, !model.isEmpty {
                self.model = model
            }
        }

        func makeMetaRow() -> SessionRow? {
            guard let sessionId, let timestamp = firstTimestamp, let cwd else { return nil }
            let payload = SessionMetaPayload(
                id: sessionId,
                timestamp: timestamp,
                cwd: cwd,
                originator: "Claude Code",
                cliVersion: "claude-code \(version ?? "unknown")",
                instructions: instructions
            )
            return SessionRow(timestamp: timestamp, kind: .sessionMeta(payload))
        }

        func makeContextRow() -> SessionRow? {
            // For Claude sessions, we don't generate context update rows.
            // Model info is already shown in the session info card at the top.
            // This avoids duplicate "Syncing / Context Updated / model: xxx" entries in the timeline.
            return nil
        }
    }

    private struct ClaudeLogLine: Decodable {
        let type: String?
        let timestamp: Date?
        let sessionId: String?
        let agentId: String?
        let version: String?
        let cwd: String?
        let message: ClaudeMessage?
        let toolUseResult: JSONValue?
        let summary: String?
        let isMeta: Bool?
        let subtype: String?
        let isSidechain: Bool?
    }

    private struct ClaudeMessage: Decodable {
        let role: String?
        let model: String?
        let content: ClaudeMessageContent?
    }

    private enum ClaudeMessageContent: Decodable {
        case string(String)
        case blocks([ClaudeContentBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .string(text)
                return
            }
            if let block = try? container.decode(ClaudeContentBlock.self) {
                self = .blocks([block])
                return
            }
            if let blocks = try? container.decode([ClaudeContentBlock].self) {
                self = .blocks(blocks)
                return
            }
            self = .blocks([])
        }
    }

    private struct ClaudeContentBlock: Decodable {
        let type: String?
        let text: String?
        let id: String?
        let name: String?
        let input: JSONValue?
        let toolUseId: String?
        let content: JSONValue?
    }
}

private extension JSONValue {
    func toAnyValue() -> Any {
        switch self {
        case .string(let str): return str
        case .number(let number): return number
        case .bool(let flag): return flag
        case .array(let array): return array.map { $0.toAnyValue() }
        case .object(let dict): return dict.mapValues { $0.toAnyValue() }
        case .null: return NSNull()
        }
    }
}
