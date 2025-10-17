import AppKit
import Foundation

struct ProcessResult {
    let output: String
}

enum SessionActionError: LocalizedError {
    case executableNotFound(URL)
    case resumeFailed(output: String)
    case deletionFailed(URL)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(url):
            return "未找到可执行的 codex CLI：\(url.path)"
        case let .resumeFailed(output):
            return "恢复会话失败：\(output)"
        case let .deletionFailed(url):
            return "无法将文件移至废纸篓：\(url.path)"
        }
    }
}

struct SessionActions {
    private let fileManager: FileManager = .default

    func resolveExecutableURL(preferred: URL?) -> URL? {
        if let preferred, fileManager.isExecutableFile(atPath: preferred.path) { return preferred }
        // Try /opt/homebrew/bin, /usr/local/bin, PATH via /usr/bin/which
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex", "/bin/codex"]
        for path in candidates { if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) } }
        // which codex
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "codex"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if which.terminationStatus == 0, let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            if fileManager.isExecutableFile(atPath: str) { return URL(fileURLWithPath: str) }
        }
        return nil
    }

    func resume(session: SessionSummary, executableURL: URL) async throws -> ProcessResult {
        guard let exec = resolveExecutableURL(preferred: executableURL) else { throw SessionActionError.executableNotFound(executableURL) }

        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let process = Process()
                    process.executableURL = exec
                    process.arguments = ["resume", session.id]
                    // Prefer original session cwd if exists
                    if FileManager.default.fileExists(atPath: session.cwd) {
                        process.currentDirectoryURL = URL(fileURLWithPath: session.cwd, isDirectory: true)
                    } else {
                        process.currentDirectoryURL = session.fileURL.deletingLastPathComponent()
                    }

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    var env = ProcessInfo.processInfo.environment
                    let injectedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                    if let current = env["PATH"], !current.isEmpty {
                        env["PATH"] = injectedPATH + ":" + current
                    } else {
                        env["PATH"] = injectedPATH
                    }
                    process.environment = env

                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: ProcessResult(output: output))
                    } else {
                        continuation.resume(throwing: SessionActionError.resumeFailed(output: output))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func revealInFinder(session: SessionSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
    }

    func delete(summaries: [SessionSummary]) throws {
        for summary in summaries {
            var resulting: NSURL?
            do {
                try fileManager.trashItem(at: summary.fileURL, resultingItemURL: &resulting)
            } catch {
                throw SessionActionError.deletionFailed(summary.fileURL)
            }
        }
    }
}
