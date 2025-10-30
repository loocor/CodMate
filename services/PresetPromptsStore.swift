import AppKit
import Foundation

// Simple, opt-in preset prompts loader.
// Looks for per-project overrides first, then user-level config, then falls back to built-ins provided by caller.
// Thread-safe via actor; caches small reads by path+mtime.
actor PresetPromptsStore {
    struct Prompt: Hashable, Codable {
        var label: String
        var command: String
    }
    enum PromptLocation { case project, user, builtin }

    static let shared = PresetPromptsStore()

    private var cache: [String: (mtime: Date, items: [Prompt])] = [:]
    private var hiddenCache: [String: (mtime: Date, items: Set<String>)] = [:]

    func load(for workingDirectory: String?) -> [Prompt] {
        let projectURL: URL? = workingDirectory.map {
            URL(fileURLWithPath: $0)
                .appendingPathComponent(".codmate", isDirectory: true)
                .appendingPathComponent("prompts.json", isDirectory: false)
        }
        let userURL = userFileURL()
        let projectItems = projectURL.flatMap { read(url: $0) } ?? []
        let userItems = read(url: userURL) ?? []
        // Merge: project-level first, then user-level excluding duplicate commands
        var seen = Set<String>()
        var merged: [Prompt] = []
        for p in projectItems { if seen.insert(p.command).inserted { merged.append(p) } }
        for p in userItems { if seen.insert(p.command).inserted { merged.append(p) } }
        return merged
    }

    // MARK: - Focused loaders
    func loadProjectOnly(for workingDirectory: String?) -> [Prompt] {
        guard let workingDirectory else { return [] }
        let url = URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent(".codmate", isDirectory: true)
            .appendingPathComponent("prompts.json", isDirectory: false)
        return read(url: url) ?? []
    }

    func loadUserOnly() -> [Prompt] {
        let url = userFileURL()
        return read(url: url) ?? []
    }

    func projectFileExists(for workingDirectory: String?) -> Bool {
        guard let workingDirectory else { return false }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent(".codmate", isDirectory: true)
            .appendingPathComponent("prompts.json", isDirectory: false)
        return fm.fileExists(atPath: url.path)
    }

    func openOrCreateUserFile(withTemplate template: [Prompt]) {
        let url = userFileURL()
        ensureParentDir(url)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // Write simple template
            let arr: [[String: String]] = template.map { ["label": $0.label, "command": $0.command] }
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
                try? data.write(to: url)
            }
        }
        NSWorkspace.shared.open(url)
    }

    func openOrCreatePreferredFile(for workingDirectory: String?, withTemplate template: [Prompt]) {
        let fm = FileManager.default
        let projectURL = workingDirectory.map {
            URL(fileURLWithPath: $0)
                .appendingPathComponent(".codmate", isDirectory: true)
                .appendingPathComponent("prompts.json", isDirectory: false)
        }
        let userURL = userFileURL()
        let preferredURL: URL
        if let p = projectURL, fm.fileExists(atPath: p.path) { preferredURL = p } else { preferredURL = userURL }
        ensureParentDir(preferredURL)
        if !fm.fileExists(atPath: preferredURL.path) {
            let arr: [[String: String]] = template.map { ["label": $0.label, "command": $0.command] }
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
                try? data.write(to: preferredURL)
            }
        }
        NSWorkspace.shared.open(preferredURL)
    }

    /// Adds a prompt record to the most appropriate file (project-level preferred, else user-level).
    /// Returns the URL written on success.
    @discardableResult
    func add(prompt: Prompt, for workingDirectory: String?) -> URL? {
        // Prefer project-level file if we have a working directory
        let fm = FileManager.default
        let projectURL: URL? = workingDirectory.map {
            URL(fileURLWithPath: $0)
                .appendingPathComponent(".codmate", isDirectory: true)
                .appendingPathComponent("prompts.json", isDirectory: false)
        }
        let userURL = userFileURL()
        let targetURL: URL = {
            if let p = projectURL, fm.fileExists(atPath: p.path) { return p }
            return userURL
        }()
        ensureParentDir(targetURL)

        // Load existing array or start new
        var items = (read(url: targetURL) ?? [])
        // De-duplicate by command exact match (case-sensitive) or same label+command
        if items.contains(where: { $0.command == prompt.command }) == false {
            items.append(prompt)
        }
        // Write back
        let arr: [[String: String]] = items.map { ["label": $0.label, "command": $0.command] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) else {
            return nil
        }
        do {
            try data.write(to: targetURL)
            // Invalidate cache
            cache.removeValue(forKey: targetURL.path)
            return targetURL
        } catch {
            return nil
        }
    }

    @discardableResult
    func delete(prompt: Prompt, location: PromptLocation, workingDirectory: String?) -> Bool {
        if location == .builtin {
            return addHidden(command: prompt.command, for: workingDirectory) != nil
        }
        let fm = FileManager.default
        let targetURL: URL = {
            switch location {
            case .project:
                guard let cwd = workingDirectory else { return userFileURL() }
                return URL(fileURLWithPath: cwd)
                    .appendingPathComponent(".codmate", isDirectory: true)
                    .appendingPathComponent("prompts.json", isDirectory: false)
            case .user:
                return userFileURL()
            case .builtin:
                return userFileURL() // unreachable due to early return
            }
        }()
        guard fm.fileExists(atPath: targetURL.path) else { return false }
        guard var items = read(url: targetURL) else { return false }
        let before = items.count
        items.removeAll { $0.command == prompt.command }
        guard items.count != before else { return false }
        let arr: [[String: String]] = items.map { ["label": $0.label, "command": $0.command] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) else {
            return false
        }
        do {
            try data.write(to: targetURL)
            cache.removeValue(forKey: targetURL.path)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Hidden built-ins
    func loadHidden(for workingDirectory: String?) -> Set<String> {
        let fm = FileManager.default
        var urls: [URL] = []
        if let cwd = workingDirectory {
            urls.append(projectHiddenURL(for: cwd))
        }
        urls.append(userHiddenURL())
        var hidden = Set<String>()
        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date.distantPast
            if let cached = hiddenCache[url.path], cached.mtime == mtime {
                hidden.formUnion(cached.items)
                continue
            }
            if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                let set = Set(arr)
                hiddenCache[url.path] = (mtime, set)
                hidden.formUnion(set)
            }
        }
        return hidden
    }

    @discardableResult
    func addHidden(command: String, for workingDirectory: String?) -> URL? {
        let _ = FileManager.default
        // Prefer project-level hidden when project file exists; else user-level
        let preferredProject = projectFileExists(for: workingDirectory)
        let url = preferredProject ? projectHiddenURL(for: workingDirectory!) : userHiddenURL()
        ensureParentDir(url)
        var list: [String] = []
        if let data = try? Data(contentsOf: url), let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            list = arr
        }
        if !list.contains(command) { list.append(command) }
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) else { return nil }
        do {
            try data.write(to: url)
            hiddenCache.removeValue(forKey: url.path)
            return url
        } catch {
            return nil
        }
    }

    private func userHiddenURL() -> URL {
        userFileURL().deletingLastPathComponent().appendingPathComponent("prompts-hidden.json")
    }
    private func projectHiddenURL(for workingDirectory: String) -> URL {
        URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent(".codmate", isDirectory: true)
            .appendingPathComponent("prompts-hidden.json", isDirectory: false)
    }

    // MARK: - Private
    private func read(url: URL) -> [Prompt]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date.distantPast
        if let cached = cache[url.path], cached.mtime == mtime { return cached.items }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        var parsed: [Prompt] = []

        // Accept either [String] or [{label, command}] or [{title, text}]
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            for item in arr {
                if let s = item as? String {
                    parsed.append(Prompt(label: s, command: s))
                } else if let dict = item as? [String: Any] {
                    let label = (dict["label"] as? String)
                        ?? (dict["title"] as? String)
                        ?? (dict["name"] as? String)
                        ?? (dict["command"] as? String)
                        ?? (dict["text"] as? String)
                        ?? ""
                    let command = (dict["command"] as? String)
                        ?? (dict["text"] as? String)
                        ?? label
                    if !label.isEmpty {
                        parsed.append(Prompt(label: label, command: command))
                    }
                }
            }
        }

        cache[url.path] = (mtime, parsed)
        return parsed
    }

    private func userFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".codmate", isDirectory: true)
            .appendingPathComponent("prompts.json", isDirectory: false)
    }

    private func ensureParentDir(_ url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
