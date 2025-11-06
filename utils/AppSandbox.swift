import Foundation
import Security

enum AppSandbox {
    static var isEnabled: Bool {
        // Primary: query entitlement from our own signed task
        if let task = SecTaskCreateFromSelf(nil) {
            if let val = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool {
                return val
            }
        }
        // Fallback: environment probe (not always present on Developer ID builds)
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}

