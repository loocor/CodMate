import Foundation

/// Generates LLM-powered titles and summaries for sessions
final class SessionSummarizer: Sendable {

    /// Generate a title and 100-character summary for a session using LLM
    func generate(
        for session: SessionSummary,
        prefs: SessionPreferencesStore
    ) async throws -> (title: String, summary: String) {
        // Read the session file content
        let content = try String(contentsOf: session.fileURL, encoding: .utf8)

        // Extract key information for the prompt
        let instructions = session.instructions ?? "No instructions provided"
        let model = session.model ?? "unknown"
        let cwd = session.cwd

        // Build the prompt
        let prompt = """
            Analyze this coding session and provide:
            1. A concise title (max 50 characters)
            2. A brief summary (max 100 characters)

            Session details:
            - Working directory: \(cwd)
            - Model: \(model)
            - Instructions: \(instructions)
            - Duration: \(session.readableDuration)
            - Events: \(session.eventCount)

            Session content (first 2000 characters):
            \(content.prefix(2000))

            Respond in JSON format:
            {
              "title": "Brief title here",
              "summary": "Brief summary here"
            }
            """

        // Make API request
        let (title, summary) = try await makeOpenAIRequest(
            prompt: prompt,
            baseURL: prefs.llmBaseURL,
            apiKey: prefs.llmAPIKey,
            model: prefs.llmModel
        )

        return (title, summary)
    }

    private func makeOpenAIRequest(
        prompt: String,
        baseURL: String,
        apiKey: String,
        model: String
    ) async throws -> (String, String) {
        guard !apiKey.isEmpty else {
            throw SummarizerError.missingAPIKey
        }

        // Construct the API URL
        let urlString =
            baseURL.hasSuffix("/")
            ? "\(baseURL)v1/chat/completions"
            : "\(baseURL)/v1/chat/completions"

        guard let url = URL(string: urlString) else {
            throw SummarizerError.invalidURL(urlString)
        }

        // Build request body
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": prompt,
                ]
            ],
            "temperature": 0.7,
            "max_tokens": 200,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        // Execute request
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummarizerError.apiError(
                statusCode: httpResponse.statusCode, message: errorMessage)
        }

        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw SummarizerError.invalidResponse
        }

        // Parse the JSON response from the LLM
        return try parseResponse(content)
    }

    private func parseResponse(_ content: String) throws -> (String, String) {
        // Try to parse as JSON
        guard let data = content.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = json["title"] as? String,
            let summary = json["summary"] as? String
        else {
            // Fallback: try to extract from markdown-style response
            return parseFallback(content)
        }

        return (
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func parseFallback(_ content: String) -> (String, String) {
        // Simple fallback: look for lines with "title:" and "summary:"
        let lines = content.components(separatedBy: .newlines)
        var title = ""
        var summary = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("title:") {
                title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("summary:") {
                summary = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            }
        }

        // If we couldn't parse anything, use the first line as title
        if title.isEmpty {
            title = lines.first?.trimmingCharacters(in: .whitespaces) ?? "Session"
        }
        if summary.isEmpty {
            summary = content.prefix(100).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (title, summary)
    }
}

enum SummarizerError: LocalizedError {
    case missingAPIKey
    case invalidURL(String)
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is required for generating summaries. Please configure it in Settings."
        case .invalidURL(let url):
            return "Invalid API URL: \(url)"
        case .invalidResponse:
            return "Invalid response from LLM API"
        case .apiError(let statusCode, let message):
            return "API error (status \(statusCode)): \(message)"
        }
    }
}
