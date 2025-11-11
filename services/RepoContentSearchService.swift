import Foundation
#if canImport(Darwin)
import Darwin
#endif

actor RepoContentSearchService {
  enum SearchError: Error {
    case executableMissing
    case failed(String)
  }

  private var activeProcess: Process?

  func cancel() {
    activeProcess?.terminate()
    activeProcess = nil
  }

  func searchFilesContaining(
    _ term: String,
    in root: URL,
    limit: Int = 4000
  ) async throws -> Set<String> {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    precondition(limit > 0, "limit must be positive")
    activeProcess?.terminate()

    var env = ProcessInfo.processInfo.environment
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    let existingPath = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"]
    env["PATH"] = [defaultPath, existingPath]
      .compactMap { $0 }
      .joined(separator: ":")

    let process = Process()
    process.environment = env
    process.currentDirectoryURL = root
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "rg",
      "--files-with-matches",
      "--hidden",
      "--follow",
      "--no-messages",
      "--ignore-case",
      "--color",
      "never",
      "--fixed-strings",
      trimmed,
      "."
    ]

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
    } catch {
      if (error as NSError).code == ENOENT {
        throw SearchError.executableMissing
      }
      throw error
    }

    activeProcess = process
    var files: Set<String> = []
    var truncated = false

    do {
      for try await rawLine in stdout.fileHandleForReading.bytes.lines {
        if Task.isCancelled {
          process.terminate()
          throw CancellationError()
        }
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { continue }
        let normalized = line.hasPrefix("./") ? String(line.dropFirst(2)) : line
        files.insert(normalized)
        if files.count >= limit {
          truncated = true
          process.terminate()
          break
        }
      }
    } catch is CancellationError {
      process.terminate()
      throw CancellationError()
    }

    process.waitUntilExit()
    activeProcess = nil

    let status = process.terminationStatus
    if !truncated && status != 0 && status != 1 {
      let errData = try? stderr.fileHandleForReading.readToEnd()
      let message = errData.flatMap { String(data: $0, encoding: .utf8) } ?? "ripgrep exit code \(status)"
      throw SearchError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return files
  }
}
