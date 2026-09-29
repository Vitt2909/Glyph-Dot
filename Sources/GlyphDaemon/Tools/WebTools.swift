import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GlyphCore

/// Pesquisa na web. Provedores: DuckDuckGo (sem chave), Brave (chave) ou
/// SearXNG (instância própria).
public struct WebSearchTool: Tool {
    public enum Provider: Sendable, Equatable {
        case duckduckgo
        case brave(apiKey: String)
        case searxng(URL)
    }

    public var provider: Provider
    public var transport: HTTPTransport
    public var maxResults: Int

    public init(provider: Provider = .duckduckgo, transport: HTTPTransport = URLSessionTransport(), maxResults: Int = 5) {
        self.provider = provider
        self.transport = transport
        self.maxResults = maxResults
    }

    public var spec: ToolSpec {
        ToolSpec(name: "web_search",
                 description: "Pesquisa na web e devolve títulos, links e trechos dos primeiros resultados.",
                 inputSchema: schema([("query", "O que pesquisar", true)]))
    }

    public var actionClass: ActionClass { .networkRead }
    public var place: ToolPlace { .browser }

    public func summarize(_ input: JSONValue) -> String { "pesquisar: " + (input["query"]?.stringValue ?? "") }

    public struct Result: Sendable, Equatable {
        public var title: String
        public var url: String
        public var snippet: String
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        guard let q = input["query"]?.stringValue, !q.isEmpty else { throw ToolError.badInput("falta query") }
        let results = try await search(q)
        guard !results.isEmpty else { return ToolOutput("nenhum resultado para \(q)", untrusted: true) }
        let text = results.prefix(maxResults).enumerated().map { i, r in
            "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
        }.joined(separator: "\n")
        return ToolOutput(markUntrusted(text, source: "web_search"), untrusted: true)
    }

    func search(_ q: String) async throws -> [Result] {
        var comps: URLComponents
        var req: URLRequest
        switch provider {
        case .duckduckgo:
            comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
            comps.queryItems = [URLQueryItem(name: "q", value: q)]
            req = URLRequest(url: comps.url!)
            req.setValue("Mozilla/5.0 (Macintosh) Glyph/0.1", forHTTPHeaderField: "user-agent")
        case let .brave(key):
            comps = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            comps.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "count", value: String(maxResults))]
            req = URLRequest(url: comps.url!)
            req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            req.setValue("application/json", forHTTPHeaderField: "accept")
        case let .searxng(base):
            comps = URLComponents(url: base.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "format", value: "json")]
            req = URLRequest(url: comps.url!)
        }
        req.timeoutInterval = 20
        let (status, data) = try await transport.send(req)
        guard (200..<300).contains(status) else { throw ToolError.failed("busca falhou (HTTP \(status))") }
        switch provider {
        case .duckduckgo: return Self.parseDuckDuckGo(String(decoding: data, as: UTF8.self))
        case .brave:
            let j = try JSONValue.parse(data)
            return (j["web"]?["results"]?.arrayValue ?? []).map {
                Result(title: HTMLText.strip($0["title"]?.stringValue ?? ""), url: $0["url"]?.stringValue ?? "",
                       snippet: HTMLText.strip($0["description"]?.stringValue ?? ""))
            }
        case .searxng:
            let j = try JSONValue.parse(data)
            return (j["results"]?.arrayValue ?? []).map {
                Result(title: $0["title"]?.stringValue ?? "", url: $0["url"]?.stringValue ?? "",
                       snippet: $0["content"]?.stringValue ?? "")
            }
        }
    }

    /// Lê a página HTML do DuckDuckGo (sem chave). Frágil por natureza: se o
    /// layout mudar, a busca volta vazia em vez de quebrar.
    static func parseDuckDuckGo(_ html: String) -> [Result] {
        var results: [Result] = []
        let blocks = html.components(separatedBy: "class=\"result__a\"").dropFirst()
        for block in blocks {
            guard let hrefRange = block.range(of: "href=\""),
                  let hrefEnd = block[hrefRange.upperBound...].firstIndex(of: "\""),
                  let titleStart = block[hrefEnd...].firstIndex(of: ">"),
                  let titleEnd = block[titleStart...].range(of: "</a>") else { continue }
            var url = String(block[hrefRange.upperBound..<hrefEnd])
            if let comps = URLComponents(string: url.hasPrefix("//") ? "https:" + url : url),
               let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
                url = uddg
            }
            let title = HTMLText.strip(String(block[block.index(after: titleStart)..<titleEnd.lowerBound]))
            var snippet = ""
            if let s = block.range(of: "class=\"result__snippet\""), let open = block[s.upperBound...].firstIndex(of: ">"),
               let close = block[open...].range(of: "</a>") {
                snippet = HTMLText.strip(String(block[block.index(after: open)..<close.lowerBound]))
            }
            results.append(Result(title: title, url: HTMLText.decodeEntities(url), snippet: snippet))
        }
        return results
    }
}

/// Lê uma página e devolve o texto. Só http(s) públicos.
public struct WebFetchTool: Tool {
    public var transport: HTTPTransport
    public var maxChars: Int

    public init(transport: HTTPTransport = URLSessionTransport(), maxChars: Int = 12_000) {
        self.transport = transport
        self.maxChars = maxChars
    }

    public var spec: ToolSpec {
        ToolSpec(name: "web_fetch", description: "Baixa uma página pública (http/https) e devolve o texto.",
                 inputSchema: schema([("url", "Endereço da página", true)]))
    }

    public var actionClass: ActionClass { .networkRead }
    public var place: ToolPlace { .browser }

    public func summarize(_ input: JSONValue) -> String { "ler: " + (input["url"]?.stringValue ?? "") }
    public func scope(_ input: JSONValue) -> String {
        input["url"]?.stringValue.flatMap { URL(string: $0)?.host } ?? "*"
    }

    /// Bloqueia endereços locais e privados: um texto malicioso numa página
    /// não pode fazer o Glyph sondar a rede da casa.
    public static func isPublic(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal") { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (0, _), (169, 254), (192, 168): return false
            case (172, 16...31), (100, 64...127): return false
            default: return true
            }
        }
        if host.contains(":") { return !(host.hasPrefix("[::1") || host == "::1" || host.hasPrefix("[fc") || host.hasPrefix("[fd") || host.hasPrefix("[fe80")) }
        return true
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        guard let s = input["url"]?.stringValue, let url = URL(string: s) else { throw ToolError.badInput("url inválida") }
        guard Self.isPublic(url) else { throw ToolError.forbidden("só páginas públicas (http/https)") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 (Macintosh) Glyph/0.1", forHTTPHeaderField: "user-agent")
        let (status, data) = try await transport.send(req)
        guard (200..<300).contains(status) else { throw ToolError.failed("HTTP \(status)") }
        var text = HTMLText.strip(String(decoding: data.prefix(2_000_000), as: UTF8.self))
        if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n[cortado]" }
        return ToolOutput(markUntrusted(text, source: url.absoluteString), untrusted: true)
    }
}

/// Abre um endereço ou app. Efeito externo: sempre pede.
public struct OpenTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "open", description: "Abre um endereço (https://…) ou um app pelo nome.",
                 inputSchema: schema([("target", "URL ou nome do app", true)]))
    }

    public var actionClass: ActionClass { .externalEffect }

    public func summarize(_ input: JSONValue) -> String { "abrir " + (input["target"]?.stringValue ?? "") }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        guard let target = input["target"]?.stringValue, !target.isEmpty else { throw ToolError.badInput("falta target") }
        let p = Process()
        #if os(macOS)
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = target.contains("://") ? [target] : ["-a", target]
        #else
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        p.arguments = [target]
        #endif
        try p.run()
        p.waitUntilExit()
        return ToolOutput(p.terminationStatus == 0 ? "aberto: \(target)" : "não consegui abrir \(target)",
                          isError: p.terminationStatus != 0)
    }
}

/// HTML → texto simples.
public enum HTMLText {
    public static func strip(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<(br|p|div|li|h[1-6]|tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*\n\\s*", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }
}
