import Foundation

// MARK: - MCP Server Models

public enum MCPServerKind: String, Codable, Sendable { case stdio, sse, streamable_http }

public struct MCPCapability: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var enabled: Bool
}

public struct MCPServerMeta: Codable, Equatable, Sendable {
    public var description: String?
    public var version: String?
    public var websiteUrl: String?
    public var repositoryURL: String?
}

public struct MCPServer: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: MCPServerKind

    // stdio
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?

    // network
    public var url: String?
    public var headers: [String: String]?

    // meta
    public var meta: MCPServerMeta?

    // dynamic
    public var enabled: Bool
    public var capabilities: [MCPCapability]

    public init(
        name: String,
        kind: MCPServerKind,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil,
        meta: MCPServerMeta? = nil,
        enabled: Bool = true,
        capabilities: [MCPCapability] = []
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.meta = meta
        self.enabled = enabled
        self.capabilities = capabilities
    }
}

// A lightweight draft parsed from import payloads before persistence
public struct MCPServerDraft: Codable, Sendable {
    public var name: String?
    public var kind: MCPServerKind
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var url: String?
    public var headers: [String: String]?
    public var meta: MCPServerMeta?
}

