import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import OSLog

struct SSHHost: Hashable, Sendable {
    let alias: String
    let hostname: String?
    let port: Int?
    let user: String?
    let identityFile: String?
    let proxyJump: String?
    let proxyCommand: String?
    let forwardAgent: Bool?
    let additionalOptions: [String: String]
}

final class SSHConfigResolver {
    private let fileManager: FileManager
    private let configURL: URL
    private static let logger = Logger(subsystem: "io.umate.codemate", category: "SSHConfigResolver")

    var configurationURL: URL { configURL }

    private let nestedSSHDefaults: [String] = [
        "-o", "ControlMaster=no",
        "-o", "ControlPersist=no",
        "-o", "ControlPath=none",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "HashKnownHosts=yes"
    ]
    private let maxResolveDepth = 8
    private var cachedHosts: [SSHHost] = []
    private var cachedConfigTimestamp: Date?
    private let hostCacheQueue = DispatchQueue(label: "io.umate.codemate.sshHostCache", qos: .utility)

    private struct HostBlock {
        let patterns: [String]
        let options: [(String, String)]
    }

    init(
        fileManager: FileManager = .default,
        configURL: URL = SSHConfigResolver.resolvedHomeDirectory()
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
    ) {
        self.fileManager = fileManager
        self.configURL = configURL
    }

    /// Cache the resolved home directory to avoid repeated expensive lookups/log spam.
    private static let cachedHomeDirectory: URL = {
        // 1. Try to get from pw_dir (user database)
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let homePath = String(cString: home)
            if !homePath.contains("Library/Containers") {
                logger.debug("Resolved home via pw_dir: \(homePath, privacy: .public)")
                return URL(fileURLWithPath: homePath, isDirectory: true)
            }
        }

        // 2. Try to construct from user name
        if let userName = getpwuid(getuid())?.pointee.pw_name {
            let userNameStr = String(cString: userName)
            let constructedPath = "/Users/\(userNameStr)"
            if FileManager.default.fileExists(atPath: constructedPath) {
                logger.debug("Resolved home via constructed path: \(constructedPath, privacy: .public)")
                return URL(fileURLWithPath: constructedPath, isDirectory: true)
            }
        }

        // 3. Try to use shell to get home directory
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "echo $HOME"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if task.terminationStatus == 0,
           let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !output.contains("Library/Containers"),
           !output.isEmpty
        {
            logger.debug("Resolved home via shell: \(output, privacy: .public)")
            return URL(fileURLWithPath: output, isDirectory: true)
        }

        // 4. Last resort: use the sandboxed path
        let sandboxPath = FileManager.default.homeDirectoryForCurrentUser
        logger.debug("Resolved home fallback to sandbox path: \(sandboxPath.path, privacy: .public)")
        return sandboxPath
    }()

    /// Get the real user home directory, even in sandboxed apps
    static func resolvedHomeDirectory() -> URL {
        cachedHomeDirectory
    }

    private func cachedHostsIfValid() -> [SSHHost]? {
        hostCacheQueue.sync {
            guard let cachedTimestamp = cachedConfigTimestamp else { return nil }
            guard cachedTimestamp == currentConfigTimestamp() else { return nil }
            return cachedHosts
        }
    }

    private func currentConfigTimestamp() -> Date? {
        let attrs = try? fileManager.attributesOfItem(atPath: configURL.path)
        return attrs?[.modificationDate] as? Date
    }

    func resolvedHosts(forceReload: Bool = false) -> [SSHHost] {
        if !forceReload, let cached = cachedHostsIfValid() {
            return cached
        }
        print("SSHConfigResolver: Attempting to read SSH config from: \(configURL.path)")
        print("SSHConfigResolver: FileManager.default.homeDirectoryForCurrentUser: \(FileManager.default.homeDirectoryForCurrentUser.path)")
        print("SSHConfigResolver: ProcessInfo.HOME: \(ProcessInfo.processInfo.environment["HOME"] ?? "not found")")

        guard fileManager.fileExists(atPath: configURL.path) else {
            print("SSH config file does not exist at: \(configURL.path)")
            return []
        }

        guard fileManager.isReadableFile(atPath: configURL.path) else {
            print("SSH config file is not readable at: \(configURL.path)")
            return []
        }

        var blocks: [HostBlock] = []
        var visited: Set<URL> = []
        parseConfig(at: configURL, visited: &visited, into: &blocks)
        let hosts = buildHosts(from: blocks)
        hostCacheQueue.sync {
            cachedHosts = hosts
            cachedConfigTimestamp = currentConfigTimestamp()
        }
        return hosts
    }

    private func parseConfig(
        at url: URL,
        visited: inout Set<URL>,
        into blocks: inout [HostBlock]
    ) {
        let canonical = url.standardizedFileURL
        guard visited.insert(canonical).inserted else {
            print("SSHConfigResolver: Skipping already processed include at \(canonical.path)")
            return
        }

        guard let raw = try? String(contentsOf: canonical, encoding: .utf8) else {
            print("SSHConfigResolver: Failed to read config at \(canonical.path)")
            return
        }

        var currentPatterns: [String]? = nil
        var currentOptions: [(String, String)] = []

        func flushCurrent() {
            guard let patterns = currentPatterns else { return }
            guard !patterns.isEmpty else {
                currentPatterns = nil
                currentOptions.removeAll()
                return
            }
            if !currentOptions.isEmpty {
                blocks.append(HostBlock(patterns: patterns, options: currentOptions))
            }
            currentPatterns = nil
            currentOptions.removeAll()
        }

        let lines = raw.components(separatedBy: .newlines)
        let baseDirectory = canonical.deletingLastPathComponent()

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("#") else { continue }

            let lower = line.lowercased()
            if lower.hasPrefix("include ") {
                flushCurrent()
                let patternPart = line.dropFirst("include".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let tokens = patternPart.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if tokens.isEmpty {
                    continue
                }
                for token in tokens {
                    let targets = resolveIncludeTargets(token, relativeTo: baseDirectory)
                    if targets.isEmpty {
                        print("SSHConfigResolver: Include pattern '\(token)' had no matches")
                    } else {
                        for target in targets {
                            parseConfig(at: target, visited: &visited, into: &blocks)
                        }
                    }
                }
                continue
            }

            if lower.hasPrefix("host ") && !lower.hasPrefix("hostname ") {
                flushCurrent()
                let hostPart = line.dropFirst("host".count).trimmingCharacters(in: .whitespaces)
                let patterns = hostPart.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                currentPatterns = patterns
                continue
            }

            guard let (key, value) = parseOption(line) else { continue }
            if currentPatterns == nil {
                currentPatterns = ["*"]
            }
            currentOptions.append((key, value))
        }

        flushCurrent()
    }

    private func parseOption(_ line: String) -> (String, String)? {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let key = parts[0].lowercased()
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, value)
    }

    private func resolveIncludeTargets(_ pattern: String, relativeTo base: URL) -> [URL] {
        var expanded = pattern
        if expanded.hasPrefix("~") {
            expanded = NSString(string: expanded).expandingTildeInPath
        } else if !expanded.hasPrefix("/") {
            expanded = base.appendingPathComponent(expanded).path
        }

        var globResult = glob_t()
        defer { globfree(&globResult) }
        let status = expanded.withCString { cPattern in
            glob(cPattern, GLOB_TILDE | GLOB_BRACE, nil, &globResult)
        }
        guard status == 0 else { return [] }
        var urls: [URL] = []
        for index in 0..<Int(globResult.gl_matchc) {
            if let pointer = globResult.gl_pathv?[index] {
                let path = String(cString: pointer)
                urls.append(URL(fileURLWithPath: path))
            }
        }
        return urls
    }

    private func buildHosts(from blocks: [HostBlock]) -> [SSHHost] {
        var aliasOrder: [String] = []
        var seen: Set<String> = []
        for block in blocks {
            for pattern in block.patterns {
                guard !containsWildcards(pattern) else { continue }
                let key = pattern.lowercased()
                if seen.insert(key).inserted {
                    aliasOrder.append(pattern)
                }
            }
        }

        var optionMap: [String: [String: String]] = [:]
        for alias in aliasOrder {
            var options: [String: String] = [:]
            for block in blocks {
                guard block.patterns.contains(where: { patternMatches($0, alias: alias) }) else { continue }
                for (key, value) in block.options {
                    if options[key] == nil {
                        options[key] = value
                    }
                }
            }
            optionMap[alias.lowercased()] = options
        }

        var hosts: [SSHHost] = []
        for alias in aliasOrder {
            guard let options = optionMap[alias.lowercased()] else { continue }
            let host = makeHost(alias: alias, options: options, optionMap: optionMap)
            hosts.append(host)
        }
        return hosts
    }

    private func makeHost(
        alias: String,
        options: [String: String],
        optionMap: [String: [String: String]],
        depth: Int = 0
    ) -> SSHHost {
        let hostname = options["hostname"]
        let port = options["port"].flatMap { Int($0) }
        let user = options["user"]
        let identityFile = options["identityfile"].map(expandTildeIfNeeded)
        let proxyJump = resolvedProxyJump(
            from: options["proxyjump"],
            optionMap: optionMap,
            depth: depth
        )
        let proxyCommand = resolvedProxyCommand(
            from: options["proxycommand"],
            alias: alias,
            optionMap: optionMap,
            hostname: hostname ?? alias,
            port: port,
            depth: depth
        )
        let forwardAgent: Bool?
        if let agentRaw = options["forwardagent"]?.lowercased() {
            forwardAgent = agentRaw == "yes" || agentRaw == "true"
        } else {
            forwardAgent = nil
        }

        return SSHHost(
            alias: alias,
            hostname: hostname,
            port: port,
            user: user,
            identityFile: identityFile,
            proxyJump: proxyJump,
            proxyCommand: proxyCommand,
            forwardAgent: forwardAgent,
            additionalOptions: options
        )
    }

    private func resolvedProxyJump(
        from raw: String?,
        optionMap: [String: [String: String]],
        depth: Int
    ) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        guard depth < maxResolveDepth else { return nil }
        let hops = raw.split(separator: ",")
        let resolved = hops.map { hop -> String in
            let trimmed = hop.trimmingCharacters(in: .whitespacesAndNewlines)
            return resolveEndpoint(trimmed, optionMap: optionMap)
        }
        return resolved.joined(separator: ",")
    }

    private func resolveEndpoint(_ token: String, optionMap: [String: [String: String]]) -> String {
        if token.contains("@") || token.contains(":") {
            return token
        }
        let key = token.lowercased()
        guard let options = optionMap[key] else { return token }
        let hostName = options["hostname"] ?? token
        var result = ""
        if let user = options["user"] {
            result += "\(user)@"
        }
        result += hostName
        if let portString = options["port"], let port = Int(portString) {
            result += ":\(port)"
        }
        return result
    }

    private func resolvedProxyCommand(
        from raw: String?,
        alias: String,
        optionMap: [String: [String: String]],
        hostname: String,
        port: Int?,
        depth: Int
    ) -> String? {
        guard var command = raw, !command.isEmpty else { return nil }
        guard depth < maxResolveDepth else { return nil }
        command = command.replacingOccurrences(of: "%h", with: hostname)
        let portString = port.map(String.init) ?? "22"
        command = command.replacingOccurrences(of: "%p", with: portString)
        if let rewritten = rewriteProxyCommand(command, optionMap: optionMap, depth: depth) {
            return rewritten
        }
        return command
    }

    private func rewriteProxyCommand(
        _ command: String,
        optionMap: [String: [String: String]],
        depth: Int
    ) -> String? {
        guard let tokens = shellSplit(command), !tokens.isEmpty else { return nil }
        let sshCommand = tokens[0]
        guard sshCommand.hasSuffix("ssh") || sshCommand == "ssh" else { return nil }
        guard let lastToken = tokens.last else { return nil }
        guard let aliasOptions = optionMap[lastToken.lowercased()] else { return nil }
        guard let wIndex = tokens.firstIndex(of: "-W"), wIndex + 1 < tokens.count else { return nil }
        let destination = tokens[wIndex + 1]

        let aliasHost = makeHost(
            alias: lastToken,
            options: aliasOptions,
            optionMap: optionMap,
            depth: depth + 1
        )

        var rewritten: [String] = [sshCommand]
        rewritten += nestedSSHDefaults
        rewritten += sshTokens(for: aliasHost)
        var index = 1
        while index < tokens.count - 1 {
            if index == wIndex {
                rewritten.append("-W")
                rewritten.append(destination)
                index += 2
                continue
            }
            rewritten.append(tokens[index])
            index += 1
        }

        let targetHost = aliasHost.hostname ?? lastToken
        rewritten.append(targetHost)

        return rewritten.map(shellEscape).joined(separator: " ")
    }

    private func sshTokens(for host: SSHHost) -> [String] {
        var tokens: [String] = []
        if let user = host.user, !user.isEmpty {
            tokens += ["-l", user]
        }
        if let port = host.port {
            tokens += ["-p", String(port)]
        }
        if let identity = host.identityFile, !identity.isEmpty {
            tokens += ["-i", identity]
        }
        if let proxyJump = host.proxyJump, !proxyJump.isEmpty {
            tokens += ["-J", proxyJump]
        }
        if let proxyCommand = host.proxyCommand, !proxyCommand.isEmpty {
            tokens += ["-o", "ProxyCommand=\(proxyCommand)"]
        }
        if let forwardAgent = host.forwardAgent {
            tokens += ["-o", "ForwardAgent=\(forwardAgent ? "yes" : "no")"]
        }
        return tokens
    }

    private func shellSplit(_ command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false

        for char in command {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" && !inSingle {
                escaped = true
                continue
            }
            if char == "'" && !inDouble {
                inSingle.toggle()
                continue
            }
            if char == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }
            if char.isWhitespace && !inSingle && !inDouble {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(char)
        }

        if escaped || inSingle || inDouble {
            return nil
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func shellEscape(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" }) else {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func containsWildcards(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    private func patternMatches(_ pattern: String, alias: String) -> Bool {
        pattern.withCString { p in
            alias.withCString { a in
                fnmatch(p, a, FNM_CASEFOLD) == 0
            }
        }
    }

    private func expandTildeIfNeeded(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = Self.resolvedHomeDirectory().path
        let suffix = path.dropFirst(1)
        return home + suffix
    }
}
