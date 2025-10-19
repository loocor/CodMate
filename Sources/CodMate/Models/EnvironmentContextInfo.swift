import Foundation

struct EnvironmentContextInfo: Equatable {
    struct Entry: Identifiable, Equatable {
        let key: String
        let value: String

        var id: String { key }
    }

    let timestamp: Date
    let entries: [Entry]
    let rawText: String?

    var hasContent: Bool {
        !entries.isEmpty || (rawText?.isEmpty == false)
    }
}
