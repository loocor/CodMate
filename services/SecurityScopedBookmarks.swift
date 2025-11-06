import Foundation
import Security

/// Manages security-scoped bookmarks for user-selected directories when running in App Sandbox.
/// Stores bookmarks in UserDefaults and begins access for the app's lifetime.
@MainActor
final class SecurityScopedBookmarks {
    static let shared = SecurityScopedBookmarks()

    enum Key: String, CaseIterable {
        case sessionsRoot = "bookmark.sessionsRoot"
        case notesRoot = "bookmark.notesRoot"
        case projectsRoot = "bookmark.projectsRoot"
    }

    private let defaults: UserDefaults
    private var activeURLs: [Key: URL] = [:]
    private var activeDynamic: [String: URL] = [:] // keyed by canonical path

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns true when running under an App Sandbox container.
    var isSandboxed: Bool {
        // Primary: query entitlement from our own signed task
        if let task = SecTaskCreateFromSelf(nil) {
            if let val = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool {
                return val
            }
        }
        // Fallback: environment probe (not always present on Developer ID builds)
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    func save(url: URL, for key: Key) {
        guard isSandboxed else { return }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            defaults.set(data, forKey: key.rawValue)
            // Stop any previous access for this key, then start the new one
            stopAccess(for: key)
            _ = startAccess(for: key)
        } catch {
            // Silently ignore; UI surfaces I/O errors elsewhere
        }
    }

    /// Resolve and start access for a bookmark key. Returns the resolved URL if successful.
    @discardableResult
    func startAccess(for key: Key) -> URL? {
        guard isSandboxed else { return nil }
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                               options: [.withSecurityScope],
                               relativeTo: nil,
                               bookmarkDataIsStale: &isStale)
            if isStale {
                // Refresh the bookmark
                let fresh = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(fresh, forKey: key.rawValue)
            }
            if url.startAccessingSecurityScopedResource() {
                activeURLs[key] = url
                return url
            }
        } catch {
            return nil
        }
        return nil
    }

    func stopAccess(for key: Key) {
        guard let url = activeURLs.removeValue(forKey: key) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    /// On app launch, attempt to start access for all stored bookmarks.
    func restoreAndStartAccess() {
        guard isSandboxed else { return }
        for key in Key.allCases {
            _ = startAccess(for: key)
        }
    }

    // MARK: - Dynamic bookmarks (per repository root or arbitrary directory)

    private func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private var dynamicPrefix: String { "bookmark.dynamic." }
    private func dynamicKey(for url: URL) -> String { dynamicPrefix + canonicalPath(for: url) }

    func hasDynamicBookmark(for url: URL) -> Bool {
        let key = dynamicKey(for: url)
        return defaults.data(forKey: key) != nil
    }

    /// Save a dynamic security-scoped bookmark for an arbitrary directory.
    func saveDynamic(url: URL) {
        guard isSandboxed else { return }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            let key = dynamicKey(for: url)
            defaults.set(data, forKey: key)
            defaults.synchronize() // Force immediate write
            print("[SecurityScopedBookmarks] Saved dynamic bookmark for: \(url.path)")
            
            // Start access immediately after saving
            if url.startAccessingSecurityScopedResource() {
                activeDynamic[canonicalPath(for: url)] = url
                print("[SecurityScopedBookmarks] Started accessing: \(url.path)")
            } else {
                print("[SecurityScopedBookmarks] Failed to start accessing after save: \(url.path)")
            }
        } catch {
            print("[SecurityScopedBookmarks] Failed to save dynamic bookmark: \(error)")
        }
    }
    
    /// Restore and start access for all saved dynamic bookmarks on app launch
    func restoreAllDynamicBookmarks() {
        guard isSandboxed else { return }
        
        let dict = defaults.dictionaryRepresentation()
        let keys = dict.keys.filter { $0.hasPrefix(dynamicPrefix) }
        
        print("[SecurityScopedBookmarks] Restoring \(keys.count) dynamic bookmarks...")
        
        for key in keys {
            guard let data = defaults.data(forKey: key) else { continue }
            
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: data, 
                                 options: [.withSecurityScope], 
                                 relativeTo: nil, 
                                 bookmarkDataIsStale: &isStale)
                
                if isStale {
                    print("[SecurityScopedBookmarks] Refreshing stale bookmark for: \(url.path)")
                    let fresh = try url.bookmarkData(options: [.withSecurityScope], 
                                                     includingResourceValuesForKeys: nil, 
                                                     relativeTo: nil)
                    defaults.set(fresh, forKey: key)
                }
                
                if url.startAccessingSecurityScopedResource() {
                    activeDynamic[canonicalPath(for: url)] = url
                    print("[SecurityScopedBookmarks] Restored access to: \(url.path)")
                } else {
                    print("[SecurityScopedBookmarks] Failed to start access for: \(url.path)")
                }
            } catch {
                print("[SecurityScopedBookmarks] Failed to restore bookmark: \(error)")
            }
        }
    }

    /// Start access for an existing dynamic bookmark. Returns true if access is granted.
    @discardableResult
    func startAccessDynamic(for url: URL) -> Bool {
        guard isSandboxed else { return true }

        let canonical = canonicalPath(for: url)

        // If already accessing this directory, return success immediately
        if activeDynamic[canonical] != nil {
            print("[SecurityScopedBookmarks] Already accessing: \(url.path)")
            return true
        }

        let key = dynamicKey(for: url)
        guard let data = defaults.data(forKey: key) else {
            print("[SecurityScopedBookmarks] No bookmark found for: \(url.path)")
            return false
        }

        var stale = false
        do {
            let resolved = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                print("[SecurityScopedBookmarks] Refreshing stale bookmark for: \(resolved.path)")
                let fresh = try resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(fresh, forKey: key)
            }

            print("[SecurityScopedBookmarks] Starting access for: \(resolved.path)")
            if resolved.startAccessingSecurityScopedResource() {
                activeDynamic[canonicalPath(for: resolved)] = resolved
                print("[SecurityScopedBookmarks] Successfully started access for: \(resolved.path)")
                return true
            } else {
                print("[SecurityScopedBookmarks] Failed to start access for: \(resolved.path)")
            }
        } catch {
            print("[SecurityScopedBookmarks] Error resolving bookmark: \(error)")
            return false
        }
        return false
    }

    func stopAccessDynamic(for url: URL) {
        let key = canonicalPath(for: url)
        if let u = activeDynamic.removeValue(forKey: key) { u.stopAccessingSecurityScopedResource() }
    }

    // List all recorded dynamic repository bookmarks
    func listDynamic() -> [URL] {
        let dict = defaults.dictionaryRepresentation()
        let keys = dict.keys.filter { $0.hasPrefix(dynamicPrefix) }
        var urls: [URL] = []
        for k in keys.sorted() {
            if let data = defaults.data(forKey: k) {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    func removeDynamic(url: URL) {
        let key = dynamicKey(for: url)
        stopAccessDynamic(for: url)
        defaults.removeObject(forKey: key)
    }
}
