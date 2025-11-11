import Foundation

enum RipgrepError: Error, LocalizedError {
    case executableMissing
    case failed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "ripgrep (rg) is not installed or missing from PATH."
        case let .failed(status, message):
            return "ripgrep exited with code \(status): \(message)"
        }
    }
}

struct RipgrepRunner {
    private static let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    static func run(
        arguments: [String],
        currentDirectory: URL? = nil
    ) async throws -> [String] {
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"]
        env["PATH"] = [defaultPath, existingPath]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ":")

        let process = Process()
        process.environment = env
        process.currentDirectoryURL = currentDirectory
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rg"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            if (error as NSError).code == ENOENT {
                throw RipgrepError.executableMissing
            }
            throw error
        }

        var lines: [String] = []
        do {
            for try await rawLine in stdout.fileHandleForReading.bytes.lines {
                if Task.isCancelled {
                    process.terminate()
                    throw CancellationError()
                }
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                }
            }
        } catch is CancellationError {
            process.terminate()
            throw CancellationError()
        }

        process.waitUntilExit()
        let status = process.terminationStatus

        guard status == 0 || status == 1 else {
            let errData = try? stderr.fileHandleForReading.readToEnd()
            let errString = errData.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "unknown error"
            throw RipgrepError.failed(status: status, message: errString)
        }

        return lines
    }
}
