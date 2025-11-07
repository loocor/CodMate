import Foundation

/// Unified CLI environment configuration for embedded terminals and external shells
enum CLIEnvironment {
    /// Standard PATH components that include common CLI tool locations
    /// - Includes: ~/.local/bin (claude), /opt/homebrew/bin (codex on M1),
    ///   /usr/local/bin (codex on Intel), and standard system paths
    static let standardPathComponents = [
        "$HOME/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]

    /// Build an injected PATH string that prepends standard paths to existing PATH
    /// - Parameter additionalPaths: Optional array of additional paths to prepend
    /// - Returns: A PATH string ready to be exported or used in shell commands
    static func buildInjectedPATH(additionalPaths: [String] = []) -> String {
        let allComponents = additionalPaths + standardPathComponents
        return allComponents.joined(separator: ":") + ":${PATH}"
    }

    /// Build an injected PATH string without preserving existing PATH
    /// Useful for ProcessInfo environment where PATH is merged differently
    /// - Parameter additionalPaths: Optional array of additional paths to prepend
    /// - Returns: A PATH string without ${PATH} suffix
    static func buildBasePATH(additionalPaths: [String] = []) -> String {
        let allComponents = additionalPaths + standardPathComponents
        return allComponents.joined(separator: ":")
    }

    /// Standard locale environment variables for zh_CN UTF-8
    static let standardLocaleEnv: [String: String] = [
        "LANG": "zh_CN.UTF-8",
        "LC_ALL": "zh_CN.UTF-8",
        "LC_CTYPE": "zh_CN.UTF-8"
    ]

    /// Standard terminal environment
    static let standardTermEnv: [String: String] = [
        "TERM": "xterm-256color"
    ]

    /// Build export lines for shell scripts
    /// - Parameters:
    ///   - includeLocale: Include locale environment variables
    ///   - includeTerm: Include TERM environment variable
    ///   - additional: Additional environment variables to export
    /// - Returns: Array of export statements
    static func buildExportLines(
        includeLocale: Bool = true,
        includeTerm: Bool = true,
        additional: [String: String] = [:]
    ) -> [String] {
        var lines: [String] = []

        if includeLocale {
            for (key, value) in standardLocaleEnv {
                lines.append("export \(key)=\(value)")
            }
        }

        if includeTerm {
            for (key, value) in standardTermEnv {
                lines.append("export \(key)=\(value)")
            }
        }

        for (key, value) in additional {
            lines.append("export \(key)=\(value)")
        }

        return lines
    }
}
