import Foundation
#if canImport(MCP)
import MCP
#endif
#if canImport(System)
import System
#endif

enum MCPQuickTestError: Error, LocalizedError {
    case invalidConfiguration(String)
    case unreachable(String)
    case timeout
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let m): return m
        case .unreachable(let m): return m
        case .timeout: return "Timeout"
        case .unknown: return "Unknown error"
        }
    }
}

struct MCPQuickTestResult: Sendable {
    let connected: Bool
    let serverName: String?
    let tools: Int
    let prompts: Int
    let resources: Int
    let models: Int
    let hasTools: Bool
    let hasPrompts: Bool
    let hasResources: Bool
}

/// Lightweight connectivity test for MCP servers.
/// NOTE: This does not perform full MCP handshake; it only verifies reachability quickly.
actor MCPQuickTestService {
    private var cancelRequested: Bool = false
    private var currentProcess: Process? = nil

    func cancelActive() async {
        cancelRequested = true
        if let p = currentProcess, p.isRunning {
            p.terminate()
            Task.detached {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if p.isRunning { p.terminate() }
            }
        }
    }

    func test(server: MCPServer, timeoutSeconds: TimeInterval = 5.0) async -> Result<MCPQuickTestResult, MCPQuickTestError> {
        cancelRequested = false
        currentProcess = nil
        switch server.kind {
        case .stdio:
            return await testStdio(server: server, timeoutSeconds: timeoutSeconds)
        case .sse, .streamable_http:
            return await testHTTP(server: server, timeoutSeconds: timeoutSeconds)
        }
    }

    private func testHTTP(server: MCPServer, timeoutSeconds: TimeInterval) async -> Result<MCPQuickTestResult, MCPQuickTestError> {
        guard let urlString = server.url, let url = URL(string: urlString) else {
            return .failure(.invalidConfiguration("Missing or invalid URL"))
        }
        #if canImport(MCP)
        // Prefer real MCP handshake via HTTPClientTransport when SDK is available
        do {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = timeoutSeconds
            cfg.timeoutIntervalForResource = timeoutSeconds
            var headers: [String: String] = [:]
            if let h = server.headers { headers = h }
            let transport = HTTPClientTransport(
                endpoint: url,
                configuration: cfg,
                streaming: true,
                sseInitializationTimeout: 3,
                requestModifier: { req in
                    var r = req
                    for (k,v) in headers { r.setValue(v, forHTTPHeaderField: k) }
                    return r
                },
                logger: nil
            )
            let client = Client(name: "CodMate", version: "1.0.0")
            let initResult = try await client.connect(transport: transport)
            // Console diagnostics for investigation
            print("[MCPTest] HTTP connect ok → protocol=\(initResult.protocolVersion) server=\(initResult.serverInfo.name) \(initResult.serverInfo.version)")
            let caps = initResult.capabilities
            let hasTools = (caps.tools != nil)
            let hasPrompts = (caps.prompts != nil)
            let hasResources = (caps.resources != nil)
            print("[MCPTest] caps: tools=\(hasTools) prompts=\(hasPrompts) resources=\(hasResources) logging=\(caps.logging != nil) sampling=\(caps.sampling != nil)")
            // Try to list counts only for declared capabilities
            var toolsCount = 0, promptsCount = 0, resourcesCount = 0, modelsCount = 0
            if hasTools {
                do { let res = try await client.listTools(); toolsCount = res.tools.count; print("[MCPTest] listTools=\(toolsCount)") } catch { print("[MCPTest] listTools error: \(error)") }
            }
            if hasPrompts {
                do { let res = try await client.listPrompts(); promptsCount = res.prompts.count; print("[MCPTest] listPrompts=\(promptsCount)") } catch { print("[MCPTest] listPrompts error: \(error)") }
            }
            if hasResources {
                do { let res = try await client.listResources(); resourcesCount = res.resources.count; print("[MCPTest] listResources=\(resourcesCount)") } catch { print("[MCPTest] listResources error: \(error)") }
            }
            // Some servers expose models via prompts/resources; if the SDK exposes listModels in future, plug here.
            return .success(.init(connected: true, serverName: initResult.serverInfo.name, tools: toolsCount, prompts: promptsCount, resources: resourcesCount, models: modelsCount, hasTools: hasTools, hasPrompts: hasPrompts, hasResources: hasResources))
        } catch {
            print("[MCPTest] HTTP SDK connect/list failed: \(error)")
            // Fallback to HTTP reachability probe
            return await httpProbe(url: url, headers: server.headers, timeoutSeconds: timeoutSeconds)
        }
        #else
        return await httpProbe(url: url, headers: server.headers, timeoutSeconds: timeoutSeconds)
        #endif
    }

    private func httpProbe(url: URL, headers: [String: String]?, timeoutSeconds: TimeInterval) async -> Result<MCPQuickTestResult, MCPQuickTestError> {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let headers { for (k,v) in headers { request.setValue(v, forHTTPHeaderField: k) } }
        do {
            let (_, resp) = try await session.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200...299).contains(code) || code == 401 || code == 403 || code == 405
            guard ok else { return .failure(.unreachable("HTTP \(code)")) }
            return .success(.init(connected: true, serverName: nil, tools: 0, prompts: 0, resources: 0, models: 0, hasTools: false, hasPrompts: false, hasResources: false))
        } catch {
            if (error as? URLError)?.code == .timedOut { return .failure(.timeout) }
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    private func testStdio(server: MCPServer, timeoutSeconds: TimeInterval) async -> Result<MCPQuickTestResult, MCPQuickTestError> {
        guard let cmdRaw = server.command?.trimmingCharacters(in: .whitespacesAndNewlines), !cmdRaw.isEmpty else {
            return .failure(.invalidConfiguration("Missing command"))
        }
        // Resolve executable: absolute path → as-is; otherwise search PATH; fallback to /usr/bin/env cmd
        let fm = FileManager.default
        var env = ProcessInfo.processInfo.environment
        if let custom = server.env { for (k,v) in custom { env[k] = v } }
        // Ensure PATH contains common Homebrew locations
        let defaultPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let mergedPATH: String = {
            if let p = env["PATH"], !p.isEmpty { return p + ":" + defaultPATH }
            return defaultPATH
        }()
        env["PATH"] = mergedPATH

        let cmd = cmdRaw
        let isAbsolute = cmd.hasPrefix("/")
        let execURL: URL?
        if isAbsolute {
            execURL = URL(fileURLWithPath: cmd)
        } else {
            // Search PATH
            var found: URL? = nil
            for dir in mergedPATH.split(separator: ":") {
                let path = String(dir) + "/" + cmd
                if fm.isExecutableFile(atPath: path) { found = URL(fileURLWithPath: path); break }
            }
            execURL = found
        }

        let proc = Process()
        let args = server.args ?? []
        if let url = execURL {
            proc.executableURL = url
            proc.arguments = args
        } else {
            // Fallback: /usr/bin/env cmd args… to honor PATH resolution on macOS
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [cmd] + args
        }
        // Diagnostics
        print("[MCPTest] stdio PATH=\(mergedPATH)")
        print("[MCPTest] stdio exec=\(execURL?.path ?? "/usr/bin/env \(cmd)") args=\(args)")
        proc.environment = env

        #if canImport(MCP)
        // Wire child process stdio to SDK stdio transport
        let childStdout = Pipe()
        let childStdin = Pipe()
        let childStderr = Pipe()
        proc.standardOutput = childStdout
        proc.standardInput = childStdin
        proc.standardError = childStderr
        do {
            try proc.run()
        } catch {
            let errMsg = (error as NSError).localizedDescription
            if (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == ENOENT {
                return .failure(.unreachable("Command not found in PATH"))
            }
            return .failure(.unreachable(errMsg))
        }

        // Build transport using the child's pipes
        // Note: input for transport is what we read FROM (child stdout), output is what we write TO (child stdin)
        #if canImport(System)
        let inFD = FileDescriptor(rawValue: CInt(childStdout.fileHandleForReading.fileDescriptor))
        let outFD = FileDescriptor(rawValue: CInt(childStdin.fileHandleForWriting.fileDescriptor))
        #else
        let inFD = CInt(childStdout.fileHandleForReading.fileDescriptor)
        let outFD = CInt(childStdin.fileHandleForWriting.fileDescriptor)
        #endif
        let transport = StdioTransport(input: inFD, output: outFD, logger: nil)
        let client = Client(name: "CodMate", version: "1.0.0")
        do {
            let initResult = try await client.connect(transport: transport)
            print("[MCPTest] stdio connect ok → protocol=\(initResult.protocolVersion) server=\(initResult.serverInfo.name) \(initResult.serverInfo.version)")
            let caps = initResult.capabilities
            let hasTools = (caps.tools != nil)
            let hasPrompts = (caps.prompts != nil)
            let hasResources = (caps.resources != nil)
            print("[MCPTest] caps: tools=\(hasTools) prompts=\(hasPrompts) resources=\(hasResources)")
            var toolsCount = 0, promptsCount = 0, resourcesCount = 0
            if hasTools {
                do { let res = try await client.listTools(); toolsCount = res.tools.count; print("[MCPTest] listTools=\(toolsCount)") } catch { print("[MCPTest] listTools error: \(error)") }
            }
            if hasPrompts {
                do { let res = try await client.listPrompts(); promptsCount = res.prompts.count; print("[MCPTest] listPrompts=\(promptsCount)") } catch { print("[MCPTest] listPrompts error: \(error)") }
            }
            if hasResources {
                do { let res = try await client.listResources(); resourcesCount = res.resources.count; print("[MCPTest] listResources=\(resourcesCount)") } catch { print("[MCPTest] listResources error: \(error)") }
            }
            // Cleanup
            await transport.disconnect()
            if proc.isRunning { proc.terminate() }
            currentProcess = nil
            return .success(.init(connected: true, serverName: initResult.serverInfo.name, tools: toolsCount, prompts: promptsCount, resources: resourcesCount, models: 0, hasTools: hasTools, hasPrompts: hasPrompts, hasResources: hasResources))
        } catch {
            print("[MCPTest] stdio SDK connect/list failed: \(error)")
            if proc.isRunning { proc.terminate() }
            return .failure(.unreachable(error.localizedDescription))
        }
        #else
        // Without SDK, do a minimal reachability ping
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            let errMsg = (error as NSError).localizedDescription
            if (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == ENOENT {
                return .failure(.unreachable("Command not found in PATH"))
            }
            return .failure(.unreachable(errMsg))
        }
        let deadline = UInt64((min(timeoutSeconds, 1.5)) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: deadline)
        if proc.isRunning { proc.terminate() }
        currentProcess = nil
        return .success(.init(connected: true, serverName: nil, tools: 0, prompts: 0, resources: 0, models: 0, hasTools: false, hasPrompts: false, hasResources: false))
        #endif
    }
}
