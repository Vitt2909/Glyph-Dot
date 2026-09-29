import Foundation
import GlyphCore
import GlyphIPC

/// Monta cérebro, ferramentas e opções a partir da configuração.
public enum Runtime {
    public enum Setup: Error, CustomStringConvertible {
        case unknownProvider(String)
        public var description: String {
            switch self {
            case let .unknownProvider(p): return "provedor desconhecido: \(p) (use anthropic, openai, ollama, externo ou offline)"
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
        case "externo", "external", "agente":
            guard let cmd = c.comando, !cmd.isEmpty else {
                throw Setup.unknownProvider("externo sem comando (defina cerebro.principal.comando)")
            }
            return ExternalAgentBrain(name: c.nome ?? (cmd[0] as NSString).lastPathComponent, command: expandCommand(cmd),
                                      environment: ShellTool.cleanEnvironment(), timeout: c.timeout ?? 300)
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

    /// Conecta nos servidores MCP e lista as ferramentas. Servidor que falha
    /// não derruba os outros: vira uma linha em `errors`.
    public static func mcpTools(_ cfg: DaemonConfig, environment: [String: String] = ProcessInfo.processInfo.environment)
        async -> (tools: [MCPTool], clients: [MCPClient], errors: [String]) {
        var tools: [MCPTool] = []
        var clients: [MCPClient] = []
        var errors: [String] = []
        var names = Set<String>()
        for server in cfg.mcp ?? [] where server.ativo != false {
            guard !server.comando.isEmpty else {
                errors.append("\(server.nome): sem comando")
                continue
            }
            guard names.insert(server.nome).inserted else {
                errors.append("\(server.nome): nome repetido")
                continue
            }
            var env = ShellTool.cleanEnvironment()
            for (k, v) in server.env ?? [:] {
                if v.hasPrefix("$") {
                    if let value = environment[String(v.dropFirst())] { env[k] = value }
                } else {
                    env[k] = v
                }
            }
            let client = MCPClient(name: server.nome, command: expandCommand(server.comando),
                                   environment: env, timeout: server.timeout ?? 60)
            do {
                let infos = try await client.listTools()
                clients.append(client)
                for info in infos {
                    tools.append(MCPTool(server: server.nome, info: info, declaredClass: server.classes?[info.name], client: client))
                }
            } catch {
                errors.append("\(server.nome): \(error)")
                await client.stop()
            }
        }
        return (tools, clients, errors)
    }

    /// Só `~` vira a pasta do usuário; nomes como `python3` ficam para o PATH.
    static func expandCommand(_ argv: [String]) -> [String] {
        argv.map { $0 == "~" || $0.hasPrefix("~/") ? ShellTool.expand($0) : $0 }
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
