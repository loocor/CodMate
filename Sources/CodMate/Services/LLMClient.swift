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
        请为下面的对话生成：
        1）一个不超过 30 个中文字符的标题，简洁概括主题；
        2）一段 2-3 句的要点摘要（中文）。
        仅以 JSON 返回，例如：{"title":"...","summary":"..."}
        对话：\n\n\(text.prefix(6000))
        """
        let req = ChatRequest(model: model, messages: [ .init(role: "system", content: "你是一名资深代码助理，擅长概括"), .init(role: "user", content: prompt) ], temperature: 0.2, max_tokens: 400)
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
        // fallback：简单分行解析
        let lines = content.split(separator: "\n")
        let title = lines.first.map(String.init) ?? ""
        let summary = lines.dropFirst().joined(separator: " ")
        return (title, summary)
    }
}

