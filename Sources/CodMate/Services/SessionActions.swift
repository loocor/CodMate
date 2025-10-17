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

    func resume(session: SessionSummary, executableURL: URL) async throws -> ProcessResult {
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw SessionActionError.executableNotFound(executableURL)
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let process = Process()
                    process.executableURL = executableURL
                    process.arguments = ["resume", session.id]
                    process.currentDirectoryURL = session.fileURL.deletingLastPathComponent()

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe

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
