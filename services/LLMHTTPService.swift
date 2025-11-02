import Foundation

// MARK: - Minimal HTTP transport for Providers (OpenAI‑compatible / Anthropic)
// Small baseline: text generation only, auto‑select provider from registry.

actor LLMHTTPService {
    enum PreferredEngine { case auto, codex, claudeCode }

    struct Options: Sendable {
        var preferred: PreferredEngine = .auto
        var model: String? = nil
        var timeout: TimeInterval = 25
        var systemPrompt: String? = nil
        var maxTokens: Int = 300
        var temperature: Double = 0.2
        // Optional hard selection of a registry provider id. If set, we will
        // use that provider's connector (prefer codex, else claudeCode).
        var providerId: String? = nil
    }

    struct Result: Sendable { let text: String; let providerId: String; let model: String?; let elapsedMs: Int; let statusCode: Int }

    private let providers = ProvidersRegistryService()

    func generateText(prompt: String, options: Options = Options()) async throws -> Result {
        let start = Date()
        let reg = await providers.load()

        guard let sel = selectConnector(reg: reg, preferred: options.preferred, providerId: options.providerId) else {
            throw HTTPError.noActiveProvider
        }

        // Determine target API family and resolve model id robustly
        let providerClass = (sel.provider.class ?? "openai-compatible").lowercased()
        let candidates = candidateModels(reg: reg, selection: sel, preferred: options.model)
        var lastErr: Error? = nil
        if providerClass == "anthropic" {
            for m in candidates {
                do {
                    let (code, text) = try await callAnthropic(baseURL: sel.baseURL, headers: sel.headers, model: m, prompt: prompt, options: options)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    return Result(text: text, providerId: sel.provider.id, model: m, elapsedMs: ms, statusCode: code)
                } catch let error as HTTPError {
                    if case .http(let sc, _) = error, sc == 404 || sc == 403 || sc == 401 {
                        lastErr = error; continue
                    } else {
                        lastErr = error; break
                    }
                } catch {
                    lastErr = error; break
                }
            }
        } else {
            // Default to OpenAI‑compatible
            let wire = (sel.connector.wireAPI ?? "chat").lowercased()
            for m in candidates {
                do {
                    let (code, text): (Int, String)
                    if wire == "responses" {
                        (code, text) = try await callOpenAIResponses(baseURL: sel.baseURL, headers: sel.headers, model: m, prompt: prompt, options: options)
                    } else {
                        (code, text) = try await callOpenAIChat(baseURL: sel.baseURL, headers: sel.headers, model: m, system: options.systemPrompt, prompt: prompt, options: options)
                    }
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    return Result(text: text, providerId: sel.provider.id, model: m, elapsedMs: ms, statusCode: code)
                } catch let error as HTTPError {
                    if case .http(let sc, _) = error, sc == 404 || sc == 403 || sc == 401 {
                        lastErr = error; continue
                    } else {
                        lastErr = error; break
                    }
                } catch {
                    lastErr = error; break
                }
            }
        }
        throw lastErr ?? HTTPError.badResponse("model resolution failed")
    }

    // Resolve model id from (in order): caller override → bindings.defaultModel → provider.recommended → connector.modelAliases["default"] → first catalog model
    private func resolveModel(
        reg: ProvidersRegistryService.Registry,
        selection sel: (provider: ProvidersRegistryService.Provider, connector: ProvidersRegistryService.Connector, baseURL: String, headers: [String:String], consumerKey: String),
        preferred: String?
    ) -> String? {
        if let p = preferred, !p.isEmpty { return p }
        if let bind = reg.bindings.defaultModel?[sel.consumerKey], !bind.isEmpty { return bind }
        if let rec = sel.provider.recommended?.defaultModelFor?[sel.consumerKey], !rec.isEmpty { return rec }
        if let def = sel.connector.modelAliases?["default"], !def.isEmpty { return def }
        if let first = sel.provider.catalog?.models?.first?.vendorModelId, !first.isEmpty { return first }
        return nil
    }

    private func candidateModels(
        reg: ProvidersRegistryService.Registry,
        selection sel: (provider: ProvidersRegistryService.Provider, connector: ProvidersRegistryService.Connector, baseURL: String, headers: [String:String], consumerKey: String),
        preferred: String?
    ) -> [String?] {
        var out: [String] = []
        let push: (String?) -> Void = { v in if let v = v, !v.isEmpty, !out.contains(v) { out.append(v) } }
        push(preferred)
        push(reg.bindings.defaultModel?[sel.consumerKey])
        push(sel.provider.recommended?.defaultModelFor?[sel.consumerKey])
        push(sel.connector.modelAliases?["default"])
        if let first = sel.provider.catalog?.models?.first?.vendorModelId { push(first) }
        // Provide a very last‑resort fallback per family (won't be hit if any above exist)
        return out.isEmpty ? [nil] : out.map { Optional($0) }
    }

    // MARK: - Selection
    private func selectConnector(
        reg: ProvidersRegistryService.Registry,
        preferred: PreferredEngine,
        providerId: String?
    ) -> (provider: ProvidersRegistryService.Provider, connector: ProvidersRegistryService.Connector, baseURL: String, headers: [String:String], consumerKey: String)? {
        func resolve(_ consumer: ProvidersRegistryService.Consumer, scopedProvider: ProvidersRegistryService.Provider? = nil) -> (ProvidersRegistryService.Provider, ProvidersRegistryService.Connector, String, [String:String], String)? {
            let key = consumer.rawValue
            let p: ProvidersRegistryService.Provider?
            if let scoped = scopedProvider { p = (scoped.connectors[key] != nil) ? scoped : nil }
            else if let ap = reg.bindings.activeProvider?[key], let match = reg.providers.first(where: { $0.id == ap }) { p = match }
            else { p = reg.providers.first(where: { $0.connectors[key] != nil }) }
            guard let provider = p, let connector = provider.connectors[key] else { return nil }
            guard let base = connector.baseURL, !base.isEmpty else { return nil }
            var headers: [String:String] = [:]
            // Start with explicit headers
            if let h = connector.httpHeaders { for (k,v) in h { headers[k] = v } }
            // Fill envHttpHeaders from env
            if let eh = connector.envHttpHeaders { for (k, envKey) in eh { if let val = ProcessInfo.processInfo.environment[envKey], !val.isEmpty { headers[k] = val } } }
            // If Authorization missing but envKey looks like a key, use Bearer
            if headers["Authorization"] == nil, let k = connector.envKey, k.lowercased().contains("sk-") { headers["Authorization"] = "Bearer \(k)" }
            return (provider, connector, base, headers, key)
        }

        // If providerId is specified, pick its connector (prefer codex, else claudeCode)
        if let pid = providerId, let p = reg.providers.first(where: { $0.id == pid }) {
            return resolve(.codex, scopedProvider: p) ?? resolve(.claudeCode, scopedProvider: p)
        }
        switch preferred {
        case .codex:
            return resolve(.codex) ?? resolve(.claudeCode)
        case .claudeCode:
            return resolve(.claudeCode) ?? resolve(.codex)
        case .auto:
            return resolve(.codex) ?? resolve(.claudeCode)
        }
    }

    // MARK: - OpenAI compatible
    private func callOpenAIChat(baseURL: String, headers: [String:String], model: String?, system: String?, prompt: String, options: Options) async throws -> (Int, String) {
        let url = openAIEndpoint(baseURL: baseURL, path: "chat/completions")
        var msgs: [[String:Any]] = []
        if let sys = system, !sys.isEmpty { msgs.append(["role":"system","content": sys]) }
        msgs.append(["role":"user","content": prompt])
        let body: [String: Any] = [
            "model": model ?? "gpt-4.1-mini",
            "messages": msgs,
            "temperature": options.temperature,
            "max_tokens": options.maxTokens
        ]
        let (code, json) = try await postJSON(url: url, headers: addJSONHeaders(headers), body: body, timeout: options.timeout)
        if let choices = json["choices"] as? [[String:Any]],
           let first = choices.first,
           let message = first["message"] as? [String:Any],
           let content = message["content"] as? String {
            return (code, content)
        }
        // Fallback for providers that return `choices[].text`
        if let choices = json["choices"] as? [[String:Any]], let first = choices.first, let text = first["text"] as? String {
            return (code, text)
        }
        throw HTTPError.badResponse("openai.chat: missing choices")
    }

    private func callOpenAIResponses(baseURL: String, headers: [String:String], model: String?, prompt: String, options: Options) async throws -> (Int, String) {
        let url = openAIEndpoint(baseURL: baseURL, path: "responses")
        let body: [String: Any] = [
            "model": model ?? "gpt-4.1-mini",
            "input": [[
                "role": "user",
                "content": [["type":"text","text": prompt]]
            ]],
            "temperature": options.temperature,
            "max_output_tokens": options.maxTokens
        ]
        let (code, json) = try await postJSON(url: url, headers: addJSONHeaders(headers), body: body, timeout: options.timeout)
        if let s = json["output_text"] as? String { return (code, s) }
        if let out = json["output"] as? [[String:Any]], let first = out.first, let type = first["type"] as? String, type == "output_text", let text = first["text"] as? String { return (code, text) }
        if let content = json["content"] as? [[String:Any]], let first = content.first, let text = first["text"] as? String { return (code, text) }
        throw HTTPError.badResponse("openai.responses: missing output_text/content")
    }

    // MARK: - Anthropic
    private func callAnthropic(baseURL: String, headers: [String:String], model: String?, prompt: String, options: Options) async throws -> (Int, String) {
        let url = anthropicEndpoint(baseURL: baseURL, path: "messages")
        var hdr = addJSONHeaders(headers)
        if hdr["anthropic-version"] == nil { hdr["anthropic-version"] = "2023-06-01" }
        let body: [String: Any] = [
            "model": model ?? "claude-3-5-sonnet-20241022",
            "max_tokens": options.maxTokens,
            "messages": [["role":"user","content": [["type":"text","text": prompt]]]]
        ]
        let (code, json) = try await postJSON(url: url, headers: hdr, body: body, timeout: options.timeout)
        if let content = json["content"] as? [[String:Any]] {
            for item in content {
                if (item["type"] as? String) == "text", let text = item["text"] as? String { return (code, text) }
            }
        }
        throw HTTPError.badResponse("anthropic.messages: missing content text")
    }

    // MARK: - HTTP helpers
    private func postJSON(url: URL, headers: [String:String], body: [String:Any], timeout: TimeInterval) async throws -> (Int, [String:Any]) {
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = timeout
        for (k,v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HTTPError.badResponse("no http response") }
        let code = http.statusCode
        if code / 100 != 2 { throw HTTPError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] ?? [:]
        return (code, json)
    }

    // Build OpenAI-compatible endpoints robustly against base URLs with or without trailing /v1
    private func openAIEndpoint(baseURL: String, path: String) -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove trailing slash
        if base.hasSuffix("/") { base.removeLast() }
        // If base already ends with /v1, don't add another /v1
        if base.lowercased().hasSuffix("/v1") {
            return URL(string: base + "/" + path)!
        } else {
            return URL(string: base + "/v1/" + path)!
        }
    }

    // Build Anthropic endpoints robustly against bases that may already include /v1
    private func anthropicEndpoint(baseURL: String, path: String) -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        if base.lowercased().hasSuffix("/v1") {
            return URL(string: base + "/" + path)!
        } else {
            return URL(string: base + "/v1/" + path)!
        }
    }

    private func addJSONHeaders(_ h: [String:String]) -> [String:String] {
        var out = h
        if out["Content-Type"] == nil { out["Content-Type"] = "application/json" }
        if out["Accept"] == nil { out["Accept"] = "application/json" }
        return out
    }

    enum HTTPError: LocalizedError { case noActiveProvider; case http(Int, String); case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .noActiveProvider: return "No active provider configured"
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(400))"
            case .badResponse(let s): return "Bad response: \(s)"
            }
        }
    }
}
