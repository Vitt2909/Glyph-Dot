import Foundation
import GlyphCore
#if canImport(Security)
import Security
#endif

/// `casa/config.yaml`. Chaves de API nunca ficam aqui: vão no Keychain.
public struct DaemonConfig: Decodable, Sendable, Equatable {
    public struct BrainConfig: Decodable, Sendable, Equatable {
        /// `anthropic`, `openai`, `ollama` ou `offline`.
        public var provider: String
        public var model: String?
        public var effort: String?
        public var host: String?
        public var base_url: String?
        /// Fallback de recusa da Anthropic (padrão: ligado).
        public var fallbacks: Bool?
        /// `provider: externo`: nome e comando do agente (protocolo glyph-brain/1).
        public var nome: String?
        public var comando: [String]?
        /// Segundos de espera por resposta do agente externo.
        public var timeout: Double?

        public init(provider: String, model: String? = nil) {
            self.provider = provider
            self.model = model
        }
    }

    public struct Cerebro: Decodable, Sendable, Equatable {
        public var principal: BrainConfig?
        public var triagem: BrainConfig?

        public init(principal: BrainConfig? = nil, triagem: BrainConfig? = nil) {
            self.principal = principal
            self.triagem = triagem
        }
    }

    public struct Shell: Decodable, Sendable, Equatable {
        public var pastas: [String]?
        public var timeout: Double?
        public var sandbox: Bool?
    }

    public struct Web: Decodable, Sendable, Equatable {
        /// `duckduckgo`, `brave` ou `searxng`.
        public var busca: String?
        public var searxng: String?
    }

    public struct Organizar: Decodable, Sendable, Equatable {
        /// Pastas que o modo ensaio pode organizar.
        public var pastas: [String]?
    }

    public struct Ferramentas: Decodable, Sendable, Equatable {
        public var shell: Shell?
        public var web: Web?
        public var organizar: Organizar?
    }

    public struct Sensores: Decodable, Sendable, Equatable {
        /// Aceitar eventos do hook do terminal (`Scripts/glyph-shell.zsh`).
        public var terminal: Bool?
        /// Repositórios marcados: autonomia age neles; git observado.
        public var repos: [String]?
        public var git_intervalo: Double?
    }

    public struct Corpo: Decodable, Sendable, Equatable {
        /// Team ID do Developer ID que assina o app.
        public var equipe: String?
        /// cdhashes pareados com `glyphd pair`.
        public var pareados: [String]?
    }

    public var cerebro: Cerebro?
    public var ferramentas: Ferramentas?
    public var sensores: Sensores?
    public var turno_noturno: TurnoNoturno?
    public var equipe: Equipe?

    public struct Equipe: Decodable, Sendable, Equatable {
        /// Builder + Auditor nas tarefas; Pesquisador/Designer nos chamados.
        public var ativa: Bool?
        /// Cérebro por papel (builder, researcher, designer, auditor). Padrão: o principal.
        public var cerebros: [String: DaemonConfig.BrainConfig]?
    }

    public struct TurnoNoturno: Decodable, Sendable, Equatable {
        /// Impede o sono ocioso durante tarefa noturna, só na tomada. Opt-in.
        public var manter_acordado: Bool?
    }
    public var corpo: Corpo?
    public var mcp: [MCPServer]?
    public var agentes_externos: AgentesExternos?

    /// Um servidor MCP por stdio (M6).
    public struct MCPServer: Decodable, Sendable, Equatable {
        public var nome: String
        public var comando: [String]
        /// Variáveis para o servidor. `$NOME` copia do ambiente do glyphd
        /// (assim a chave não precisa ficar escrita aqui).
        public var env: [String: String]?
        /// Classe por ferramenta. Sem declaração: `external_effect` (sempre pede).
        public var classes: [String: ActionClass]?
        public var timeout: Double?
        /// `false` desliga sem apagar a configuração.
        public var ativo: Bool?
    }

    public struct AgentesExternos: Decodable, Sendable, Equatable {
        /// Agentes que falam o Glyph Protocol no socket podem animar o corpo
        /// (gesto, fala, ir até um ponto). Nunca pedem aprovação nem agem.
        public var corpo: Bool?
    }

    public init() {}

    public static func load(_ url: URL) throws -> DaemonConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return DaemonConfig() }
        let text = try String(contentsOf: url, encoding: .utf8)
        if try MiniYAML.parse(text) == .null { return DaemonConfig() }
        return try MiniYAML.decode(DaemonConfig.self, from: text)
    }

    public static let template = """
    # Configuração do glyphd. Chaves de API NÃO vão aqui:
    #   glyphd chave anthropic   (guarda no Keychain)
    # ou variáveis de ambiente ANTHROPIC_API_KEY / OPENAI_API_KEY / BRAVE_API_KEY.

    cerebro:
      # Planos e respostas. anthropic | openai | ollama | offline
      principal:
        provider: anthropic
        model: claude-opus-5-5
        effort: medium
      # Triagem barata e privada (M3). Deixe comentado se não usar o Ollama.
      # triagem:
      #   provider: ollama
      #   model: qwen3:8b

    ferramentas:
      shell:
        # Pastas onde o shell pode rodar. Nada fora delas.
        pastas: [~/dev]
        timeout: 60
        sandbox: true
      web:
        busca: duckduckgo   # duckduckgo | brave | searxng
        # searxng: http://127.0.0.1:8888
      organizar:
        # Pastas que o modo ensaio pode organizar (mostra o plano antes).
        pastas: [~/Downloads]

    sensores:
      # Eventos do terminal (instale Scripts/glyph-shell.zsh no ~/.zshrc).
      terminal: true
      # Repositórios onde o Glyph pode agir sozinho (dentro da escada de confiança).
      repos: []
      git_intervalo: 20

    equipe:
      # Multi-Glyph: Builder faz, Auditor confere (com veto); Pesquisador e Designer nos chamados.
      ativa: true
      # cerebros:
      #   auditor: { provider: anthropic, model: claude-opus-5-5, effort: high }

    turno_noturno:
      # Mantém o Mac acordado só enquanto houver tarefa noturna e só na tomada.
      manter_acordado: false

    corpo:
      # Team ID do Developer ID que assina o Glyph.app (vazio = usar pareamento).
      equipe: ""
      pareados: []

    # Servidores MCP (stdio). Toda ferramenta sem classe declarada é
    # external_effect: o Glyph pede antes de cada uso.
    # mcp:
    #   - nome: arquivos
    #     comando: [npx, -y, "@modelcontextprotocol/server-filesystem", ~/Documentos]
    #     classes:
    #       read_text_file: read
    #       list_directory: read

    agentes_externos:
      # Agentes que falam o Glyph Protocol no socket podem animar o corpo.
      # Nunca pedem aprovação nem executam nada. Desligado por padrão.
      corpo: false
    """
}

/// Chaves de API: Keychain no macOS, variáveis de ambiente em qualquer lugar.
public enum SecretStore {
    public static let service = "dev.glyph.glyphd"

    static let envNames = ["anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY", "brave": "BRAVE_API_KEY"]

    public static func get(_ provider: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let name = envNames[provider], let v = environment[name], !v.isEmpty { return v }
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: provider, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        #endif
        return nil
    }

    /// Guarda no Keychain (só macOS).
    public static func set(_ provider: String, _ key: String) throws {
        #if canImport(Security)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: provider]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw ToolError.failed("Keychain: erro \(status)") }
        #else
        throw ToolError.failed("Keychain só existe no macOS; use a variável de ambiente")
        #endif
    }
}

/// Tira segredos de qualquer texto antes de ir para o log.
public struct Redactor: Sendable {
    public var secrets: [String]

    public init(secrets: [String] = []) {
        self.secrets = secrets.filter { $0.count >= 8 }
    }

    static let patterns = [
        #"sk-ant-[A-Za-z0-9_\-]{8,}"#,
        #"sk-[A-Za-z0-9_\-]{16,}"#,
        #"(?i)bearer\s+[A-Za-z0-9._\-]{12,}"#,
        #"(?i)(x-api-key|api[_-]?key|token|password|senha)(["':=\s]+)[^\s"',}]{6,}"#,
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,
    ]

    public func redact(_ s: String) -> String {
        var out = s
        for secret in secrets { out = out.replacingOccurrences(of: secret, with: "[segredo]") }
        for p in Self.patterns {
            if p.contains("(x-api-key") {
                out = out.replacingOccurrences(of: p, with: "$1$2[segredo]", options: .regularExpression)
            } else {
                out = out.replacingOccurrences(of: p, with: "[segredo]", options: .regularExpression)
            }
        }
        return out
    }
}

/// Log do glyphd com redação. Um arquivo por dia em `…/Glyph/logs/`.
public final class DaemonLog: @unchecked Sendable {
    private let lock = NSLock()
    private let dir: URL?
    public var redactor: Redactor
    public var echo: Bool

    public init(dir: URL?, redactor: Redactor = Redactor(), echo: Bool = true) {
        self.dir = dir
        self.redactor = redactor
        self.echo = echo
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    public func log(_ message: String) {
        let line = "\(ISO8601.format(Date())) \(redactor.redact(message))\n"
        lock.lock(); defer { lock.unlock() }
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        guard let dir else { return }
        let day = String(ISO8601.format(Date()).prefix(10))
        let url = dir.appendingPathComponent("glyphd-\(day).log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
