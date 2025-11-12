import Foundation

struct ShellCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ShellCommandError: Error {
    case commandFailed(executable: String, arguments: [String], stderr: String, exitCode: Int32)
}

struct ShellCommandRunner {
    private static func escapedArgument(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let specialCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"'\\$`"))
        if argument.rangeOfCharacter(from: specialCharacters) == nil {
            return argument
        }
        let escaped = argument.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private static func describeCommand(executable: String, arguments: [String]) -> String {
        let parts = [executable] + arguments
        return parts.map { escapedArgument($0) }.joined(separator: " ")
    }

    @discardableResult
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ShellCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
        }

        let commandDescription = describeCommand(executable: executable, arguments: arguments)
        print("[ShellCommandRunner] Running command: \(commandDescription)")
        if let currentDirectory {
            print("[ShellCommandRunner]   cwd: \(currentDirectory.path)")
        }
        if let environment, !environment.isEmpty {
            let envDescription = environment.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            print("[ShellCommandRunner]   env overrides: \(envDescription)")
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus

        if exitCode != 0 {
            throw ShellCommandError.commandFailed(
                executable: executable,
                arguments: arguments,
                stderr: stderr,
                exitCode: exitCode
            )
        }

        return ShellCommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}
