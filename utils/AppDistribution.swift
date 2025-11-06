import Foundation

/// Build/distribution flags and helpers.
enum AppDistribution {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif
}

