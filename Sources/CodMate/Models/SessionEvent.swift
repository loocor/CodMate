import Foundation

struct SessionRow: Decodable {
    let timestamp: Date
    let kind: Kind

    enum CodingKeys: String, CodingKey {
        case timestamp
        case type
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "session_meta":
            let payload = try container.decode(SessionMetaPayload.self, forKey: .payload)
            kind = .sessionMeta(payload)
        case "turn_context":
            let payload = try container.decode(TurnContextPayload.self, forKey: .payload)
            kind = .turnContext(payload)
        case "event_msg":
            let payload = try container.decode(EventMessagePayload.self, forKey: .payload)
            kind = .eventMessage(payload)
        case "response_item":
            let payload = try container.decode(ResponseItemPayload.self, forKey: .payload)
            kind = .responseItem(payload)
        default:
            let payload = try container.decode(JSONValue.self, forKey: .payload)
            kind = .unknown(type: type, payload: payload)
        }
    }

    enum Kind {
        case sessionMeta(SessionMetaPayload)
        case turnContext(TurnContextPayload)
        case eventMessage(EventMessagePayload)
        case responseItem(ResponseItemPayload)
        case unknown(type: String, payload: JSONValue)
    }
}

struct SessionMetaPayload: Decodable {
    let id: String
    let timestamp: Date
    let cwd: String
    let originator: String
    let cliVersion: String
    let instructions: String?

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case cwd
        case originator
        case cliVersion = "cli_version"
        case instructions
    }
}

struct TurnContextPayload: Decodable {
    let cwd: String?
    let approvalPolicy: String?
    let model: String?
    let effort: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case cwd
        case approvalPolicy = "approval_policy"
        case model
        case effort
        case summary
    }
}

struct EventMessagePayload: Decodable {
    let type: String
    let message: String?
    let kind: String?
    let text: String?
    let info: JSONValue?
    let rateLimits: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case message
        case kind
        case text
        case info
        case rateLimits = "rate_limits"
    }
}

struct ResponseItemPayload: Decodable {
    let type: String
    let status: String?
    let callID: String?
    let name: String?
    let content: [ResponseContentBlock]?
    let summary: [ResponseSummaryItem]?
    let encryptedContent: String?
    let role: String?

    enum CodingKeys: String, CodingKey {
        case type
        case status
        case callID = "call_id"
        case name
        case content
        case summary
        case encryptedContent = "encrypted_content"
        case role
    }
}

struct ResponseContentBlock: Decodable {
    let type: String
    let text: String?
}

struct ResponseSummaryItem: Decodable {
    let type: String
    let text: String?
}

enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                self = .null
            }
            return
        }

        if var arrayContainer = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !arrayContainer.isAtEnd {
                let value = try arrayContainer.decode(JSONValue.self)
                items.append(value)
            }
            self = .array(items)
            return
        }

        if let keyedContainer = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var dict: [String: JSONValue] = [:]
            for key in keyedContainer.allKeys {
                let value = try keyedContainer.decode(JSONValue.self, forKey: key)
                dict[key.stringValue] = value
            }
            self = .object(dict)
            return
        }

        self = .null
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = "\(intValue)"
    }
}

struct SessionSummaryBuilder {
    private(set) var id: String?
    private(set) var startedAt: Date?
    private(set) var lastUpdatedAt: Date?
    private(set) var cliVersion: String?
    private(set) var cwd: String?
    private(set) var originator: String?
    private(set) var instructions: String?
    private(set) var model: String?
    private(set) var approvalPolicy: String?
    private(set) var userMessageCount: Int = 0
    private(set) var assistantMessageCount: Int = 0
    private(set) var toolInvocationCount: Int = 0
    private(set) var responseCounts: [String: Int] = [:]
    private(set) var turnContextCount: Int = 0
    private(set) var eventCount: Int = 0
    private(set) var lineCount: Int = 0
    private(set) var fileSizeBytes: UInt64?

    var hasEssentialMetadata: Bool {
        id != nil && startedAt != nil && cliVersion != nil && cwd != nil
    }

    mutating func setFileSize(_ size: UInt64?) {
        fileSizeBytes = size
    }

    mutating func seedLastUpdated(_ date: Date) {
        if let existing = lastUpdatedAt {
            if date > existing { lastUpdatedAt = date }
        } else {
            lastUpdatedAt = date
        }
    }

    mutating func observe(_ row: SessionRow) {
        lineCount += 1
        seedLastUpdated(row.timestamp)

        switch row.kind {
        case let .sessionMeta(payload):
            id = payload.id
            startedAt = payload.timestamp
            cwd = payload.cwd
            originator = payload.originator
            cliVersion = payload.cliVersion
            if let instructionsText = payload.instructions, instructions == nil {
                instructions = instructionsText
            }
        case let .turnContext(payload):
            turnContextCount += 1
            if let model = payload.model {
                self.model = model
            }
            if let approval = payload.approvalPolicy {
                approvalPolicy = approval
            }
            if let cwd = payload.cwd, self.cwd == nil {
                self.cwd = cwd
            }
        case let .eventMessage(payload):
            eventCount += 1
            let type = payload.type
            if type == "user_message" {
                userMessageCount += 1
            } else if type == "agent_message" {
                assistantMessageCount += 1
            }
        case let .responseItem(payload):
            eventCount += 1
            responseCounts[payload.type, default: 0] += 1
            if payload.type == "message" {
                assistantMessageCount += 1
            }
            if payload.type.contains("function_call") || payload.type.contains("tool_call") {
                toolInvocationCount += 1
            }
        case .unknown:
            lineCount += 0
        }
    }

    func build(for url: URL) -> SessionSummary? {
        guard let id,
              let startedAt,
              let cliVersion,
              let originator,
              let cwd
        else {
            return nil
        }

        return SessionSummary(
            id: id,
            fileURL: url,
            fileSizeBytes: fileSizeBytes,
            startedAt: startedAt,
            endedAt: lastUpdatedAt,
            activeDuration: nil,
            cliVersion: cliVersion,
            cwd: cwd,
            originator: originator,
            instructions: instructions,
            model: model,
            approvalPolicy: approvalPolicy,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            toolInvocationCount: toolInvocationCount,
            responseCounts: responseCounts,
            turnContextCount: turnContextCount,
            eventCount: eventCount,
            lineCount: lineCount,
            lastUpdatedAt: lastUpdatedAt
        )
    }
}
