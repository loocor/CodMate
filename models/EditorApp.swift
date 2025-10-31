import Foundation
import AppKit

enum EditorApp: String, CaseIterable, Identifiable {
    case vscode
    case cursor
    case zed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .zed: return "dev.zed.Zed"
        }
    }

    var cliCommand: String {
        switch self {
        case .vscode: return "code"
        case .cursor: return "cursor"
        case .zed: return "zed"
        }
    }

    /// Check if the editor is installed on the system
    var isInstalled: Bool {
        // Try to find the app via bundle identifier
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil {
            return true
        }

        // Fallback: check if CLI command is available in PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [cliCommand]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
