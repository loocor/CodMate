import AppKit
import Foundation

/// Centralized authorization manager for security-scoped access.
/// Wraps SecurityScopedBookmarks and provides consistent prompts for common operations.
@MainActor
final class AuthorizationHub {
    static let shared = AuthorizationHub()

    enum Purpose: String {
        case gitReviewRepo = "Git Review"
        case cliConsoleCwd = "CLI Console Working Directory"
        case generalAccess  = "File Access"
    }

    private init() {}

    var sandboxOn: Bool { SecurityScopedBookmarks.shared.isSandboxed }

    /// Returns true if access can be started immediately without prompting (or sandbox is off).
    /// When true, this also starts the security-scoped access session.
    func canAccessNow(directory: URL) -> Bool {
        guard sandboxOn else { return true }
        return SecurityScopedBookmarks.shared.startAccessDynamic(for: directory)
    }

    /// Ensure access to a directory. If a dynamic bookmark exists, starts access and returns.
    /// Otherwise prompts user to authorize the directory (or a parent) via NSOpenPanel.
    ///
    /// - Parameters:
    ///   - directory: The target directory to access.
    ///   - purpose:   A short label for the prompt UI.
    ///   - message:   Optional message; a sensible default is shown when nil.
    func ensureDirectoryAccessOrPrompt(directory: URL, purpose: Purpose, message: String? = nil) {
        guard sandboxOn else { return } // Non-sandboxed builds don't need bookmarks
        
        // Try to start access with existing bookmark first
        if SecurityScopedBookmarks.shared.startAccessDynamic(for: directory) {
            print("[AuthorizationHub] Successfully started access for: \(directory.path)")
            return
        }
        
        print("[AuthorizationHub] No existing bookmark for: \(directory.path), prompting user...")
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        let defaultMsg = "Authorize this folder for \(purpose.rawValue)"
        panel.message = message ?? defaultMsg
        panel.prompt = "Authorize"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                print("[AuthorizationHub] User authorized: \(url.path)")
                SecurityScopedBookmarks.shared.saveDynamic(url: url)
                
                // Immediately start accessing the authorized directory
                let success = SecurityScopedBookmarks.shared.startAccessDynamic(for: url)
                print("[AuthorizationHub] Start access after authorization: \(success)")
                
                // Also try to start access for the originally requested directory
                // (in case user selected a parent directory)
                if url.path != directory.path {
                    let originalSuccess = SecurityScopedBookmarks.shared.startAccessDynamic(for: directory)
                    print("[AuthorizationHub] Start access for original directory: \(originalSuccess)")
                }
                
                NotificationCenter.default.post(name: .codMateRepoAuthorizationChanged, object: nil)
            } else {
                print("[AuthorizationHub] User cancelled authorization")
            }
        }
    }
    
    /// Request authorization and wait for result synchronously (blocks current thread)
    /// Use this when you need to ensure access before proceeding
    func ensureDirectoryAccessOrPromptSync(directory: URL, purpose: Purpose, message: String? = nil) -> Bool {
        guard sandboxOn else { return true }
        
        // Try existing bookmark first
        if SecurityScopedBookmarks.shared.startAccessDynamic(for: directory) {
            return true
        }
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        let defaultMsg = "Authorize this folder for \(purpose.rawValue)"
        panel.message = message ?? defaultMsg
        panel.prompt = "Authorize"
        
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return false
        }
        
        SecurityScopedBookmarks.shared.saveDynamic(url: url)
        let success = SecurityScopedBookmarks.shared.startAccessDynamic(for: url)
        
        // Also try original directory if different
        if url.path != directory.path {
            _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: directory)
        }
        
        NotificationCenter.default.post(name: .codMateRepoAuthorizationChanged, object: nil)
        return success
    }
}
