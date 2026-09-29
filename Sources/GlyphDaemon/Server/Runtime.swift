import Foundation
import GlyphCore
import GlyphIPC

/// Monta cérebro, ferramentas e opções a partir da configuração.
public enum Runtime {
    public enum Setup: Error, CustomStringConvertible {
        case unknownProvider(String)
        public var description: String {
            switch self {
            case let .unknownProvider(p): return "provedor desconhecido: \(p) (use anthropic, openai, ollama ou offline)"
            }
        }
    }

    public static func brain(_ cfg: DaemonConfig.BrainConfig?, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> any Brain {
        let c = cfg ?? DaemonConfig.BrainConfig(provider: "anthropic")
        switch c.provider.lowercased() {
        case "anthropic", "claude":
            return AnthropicBrain(apiKey: SecretStore.get("anthropic", environment: environment) ?? "",
                                  model: c.model ?? AnthropicBrain.defaultModel,
                                  effort: c.effort ?? "medium",
                                  fallbacks: c.fallbacks ?? true,
                                  baseURL: c.base_url.flatMap(URL.init(string:)) ?? URL(string: "https://api.anthropic.com")!)
        case "openai":
            guard let model = c.model else { throw Setup.unknownProvider("openai sem model (defina cerebro.principal.model)") }
            return OpenAIBrain(apiKey: SecretStore.get("openai", environment: environment) ?? "", model: model,
                               baseURL: c.base_url.flatMap(URL.init(string:)) ?? URL(string: "https://api.openai.com")!)
        case "ollama":
            return OllamaBrain(model: c.model ?? OllamaBrain.defaultModel,
                               host: c.host.flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:11434")!)
        case "offline", "mock":
            return OfflineBrain()
        default:
            throw Setup.unknownProvider(c.provider)
        }
    }

    public static func tools(_ cfg: DaemonConfig, environment: [String: String] = ProcessInfo.processInfo.environment) -> ToolRegistry {
        let shellCfg = cfg.ferramentas?.shell
        let roots = shellCfg?.pastas ?? ["~/dev"]
        var reg = ToolRegistry()
        reg.add(ShellTool(config: .init(allowedRoots: roots, timeout: shellCfg?.timeout ?? 60,
                                        useSandboxExec: shellCfg?.sandbox ?? true)))
        let web = cfg.ferramentas?.web
        let provider: WebSearchTool.Provider
        switch web?.busca?.lowercased() {
        case "brave":
            provider = SecretStore.get("brave", environment: environment).map { .brave(apiKey: $0) } ?? .duckduckgo
        case "searxng":
            provider = web?.searxng.flatMap(URL.init(string:)).map { .searxng($0) } ?? .duckduckgo
        default:
            provider = .duckduckgo
        }
        reg.add(WebSearchTool(provider: provider))
        reg.add(WebFetchTool())
        reg.add(OpenTool())
        return reg
    }

    public static func verifier(_ cfg: DaemonConfig) -> PeerVerifier {
        PeerVerifier(teamID: cfg.corpo?.equipe.flatMap { $0.isEmpty ? nil : $0 },
                     pairedCDHashes: Set(cfg.corpo?.pareados ?? []))
    }

    /// Chaves conhecidas, para o log nunca mostrá-las.
    public static func knownSecrets(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        ["anthropic", "openai", "brave"].compactMap { SecretStore.get($0, environment: environment) }
    }
}

/// Cérebro sem rede, para `provider: offline`: responde ao que dá sem
/// modelo (hora, "oi") e diz como configurar um cérebro de verdade.
public struct OfflineBrain: Brain {
    public init() {}
    public var id: String { "offline" }

    public func respond(system: String, turns: [ChatTurn], tools: [ToolSpec]) async throws -> BrainReply {
        guard case let .user(text)? = turns.last(where: { if case .user = $0 { return true }; return false }) else {
            return BrainReply(text: "hm.")
        }
        let q = text.lowercased()
        if q.contains("hora") {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return BrainReply(text: "agora são \(f.string(from: Date())).")
        }
        if q.hasPrefix("oi") || q.hasPrefix("olá") { return BrainReply(text: "oi!") }
        return BrainReply(text: "sem cérebro: rode glyphd chave.")
    }
}
