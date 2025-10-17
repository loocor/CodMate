import Foundation

protocol LLMClient {
    func generateTitleAndSummary(for text: String, model: String) async throws -> (title: String, summary: String)
}

struct OpenAIClient: LLMClient {
    let baseURL: String
    let apiKey: String

    struct ChatRequest: Codable {
        struct Message: Codable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let temperature: Double?
        let max_tokens: Int?
    }
    struct ChatResponse: Codable {
        struct Choice: Codable { struct Message: Codable { let content: String? }; let message: Message }
        let choices: [Choice]
    }

    func generateTitleAndSummary(for text: String, model: String) async throws -> (title: String, summary: String) {
        let prompt = """
        Please generate the following for the conversation below:
        1) A concise title (<= 30 characters) summarizing the topic.
        2) A 2–3 sentence summary of key points.
        Return JSON only, e.g.: {"title":"...","summary":"..."}
        Conversation:\n\n\(text.prefix(6000))
        """
        let req = ChatRequest(model: model, messages: [ .init(role: "system", content: "You are an experienced coding assistant who writes clear English titles and summaries."), .init(role: "user", content: prompt) ], temperature: 0.2, max_tokens: 400)
        let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(req)
        let (data, _) = try await URLSession.shared.data(for: request)
        let resp = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = resp.choices.first?.message.content ?? ""
        if let jsonStart = content.firstIndex(of: "{"), let jsonEnd = content.lastIndex(of: "}") {
            let json = String(content[jsonStart...jsonEnd])
            if let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] {
                return (parsed["title"] ?? "", parsed["summary"] ?? "")
            }
        }
        // fallback: simple line-based parse
        let lines = content.split(separator: "\n")
        let title = lines.first.map(String.init) ?? ""
        let summary = lines.dropFirst().joined(separator: " ")
        return (title, summary)
    }
}

