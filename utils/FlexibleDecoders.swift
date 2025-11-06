import Foundation

enum FlexibleDecoders {
    /// JSONDecoder that accepts ISO-8601 timestamps with or without fractional seconds.
    /// Falls back to UNIX epoch seconds/milliseconds if a numeric string is provided.
    static func iso8601Flexible() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            if let d = FlexibleDecoders.iso8601WithFractional.date(from: raw)
                ?? FlexibleDecoders.iso8601Standard.date(from: raw)
            {
                return d
            }
            // Fallbacks: numeric seconds or milliseconds since epoch represented as string
            if let number = Double(raw) {
                // Heuristic: treat very large numbers as milliseconds
                if number > 10_000_000_000 { // ~Sat Nov 20 2286 in seconds; anything larger is likely ms
                    return Date(timeIntervalSince1970: number / 1000.0)
                } else {
                    return Date(timeIntervalSince1970: number)
                }
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(raw)"
            )
        }
        return decoder
    }

    // MARK: - Private formatters
    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Standard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
