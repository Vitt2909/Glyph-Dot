import Foundation
import GlyphCore

/// Uma ferramenta anunciada por um servidor MCP.
public struct MCPToolInfo: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
}

public enum MCPError: Error, Equatable, CustomStringConvertible {
    case timeout(String)
    case closed(String)
    case rpc(code: Int, message: String)
    case badResponse(String)

    public var description: String {
        switch self {
        case let .timeout(m): return "MCP: sem resposta (\(m))"
        case let .closed(m): return "MCP: servidor encerrou (\(m))"
        case let .rpc(c, m): return "MCP: erro \(c): \(m)"
        case let .badResponse(m): return "MCP: resposta inválida (\(m))"
        }
    }
}

/// Cliente MCP por stdio (JSON-RPC 2.0, uma mensagem por linha).
///
/// O Glyph é só cliente: não oferece `sampling`, `roots` nem `elicitation`.
/// Pedidos do servidor para o cliente recebem "método não encontrado".
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"

    public let name: String
    let command: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    private var proc: LineProcess?
    private var nextID = 0

    public init(name: String, command: [String], environment: [String: String], timeout: TimeInterval = 60) {
        self.name = name
        self.command = command
        self.environment = environment
        self.timeout = timeout
    }

    private func ensureStarted() async throws -> LineProcess {
        if let proc, await proc.isRunning { return proc }
        let p = try LineProcess.start(command, environment: environment)
        proc = p
        do {
            _ = try await rawRequest(p, method: "initialize", params: .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("glyphd"), "version": .string(GlyphInfo.version)]),
            ]))
            try await p.send(Self.encode(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])))
        } catch {
            await p.stop()
            proc = nil
            throw error
        }
        return p
    }

    private static func encode(_ v: JSONValue) -> String {
        (try? v.data()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private func rawRequest(_ p: LineProcess, method: String, params: JSONValue) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        try await p.send(Self.encode(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                              "method": .string(method), "params": params])))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw MCPError.timeout(method) }
            guard let line = await p.readLine(timeout: left) else {
                if await p.isRunning { throw MCPError.timeout(method) }
                throw MCPError.closed(method)
            }
            guard let msg = try? JSONValue.parse(Data(line.utf8)) else { continue } // log solto no stdout: ignora
            if msg["method"] != nil {
                // Pedido do servidor (tem id): recusa. Notificação: ignora.
                if let rid = msg["id"], rid != .null {
                    try await p.send(Self.encode(.object([
                        "jsonrpc": .string("2.0"), "id": rid,
                        "error": .object(["code": .number(-32601), "message": .string("o Glyph não oferece este método")]),
                    ])))
                }
                continue
            }
            guard msg["id"]?.numberValue == Double(id) else { continue }
            if let err = msg["error"] {
                throw MCPError.rpc(code: Int(err["code"]?.numberValue ?? 0), message: err["message"]?.stringValue ?? "?")
            }
            guard let result = msg["result"] else { throw MCPError.badResponse("sem result") }
            return result
        }
    }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let p = try await ensureStarted()
        do {
            return try await rawRequest(p, method: method, params: params)
        } catch let e as MCPError {
            if case .timeout = e {
                // Um servidor travado não fica preso ao glyphd.
                await p.stop()
                proc = nil
            }
            throw e
        }
    }

    public func listTools() async throws -> [MCPToolInfo] {
        var out: [MCPToolInfo] = []
        var cursor: String?
        for _ in 0..<20 {
            let params: JSONValue = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            let r = try await request("tools/list", params)
            for t in r["tools"]?.arrayValue ?? [] {
                guard let n = t["name"]?.stringValue, !n.isEmpty else { continue }
                out.append(MCPToolInfo(name: n, description: t["description"]?.stringValue ?? "",
                                       inputSchema: t["inputSchema"] ?? .object(["type": .string("object")])))
            }
            guard let next = r["nextCursor"]?.stringValue, !next.isEmpty else { break }
            cursor = next
        }
        return out
    }

    public func call(_ tool: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        let r = try await request("tools/call", .object(["name": .string(tool), "arguments": arguments]))
        return (Self.flatten(r), r["isError"] == .bool(true))
    }

    /// Junta o conteúdo em texto. Imagem, áudio e recurso viram marcadores.
    static func flatten(_ result: JSONValue) -> String {
        var parts: [String] = []
        for item in result["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "text": parts.append(item["text"]?.stringValue ?? "")
            case "image": parts.append("[imagem \(item["mimeType"]?.stringValue ?? "")]")
            case "audio": parts.append("[áudio \(item["mimeType"]?.stringValue ?? "")]")
            case "resource_link": parts.append("[recurso \(item["uri"]?.stringValue ?? "")]")
            case "resource":
                if let t = item["resource"]?["text"]?.stringValue { parts.append(t) }
                else { parts.append("[recurso \(item["resource"]?["uri"]?.stringValue ?? "")]") }
            default: parts.append("[conteúdo \(item["type"]?.stringValue ?? "?")]")
            }
        }
        if parts.isEmpty, let s = result["structuredContent"] { parts.append(s.description) }
        return parts.joined(separator: "\n")
    }

    public func stop() async {
        await proc?.stop()
        proc = nil
    }
}

/// Uma ferramenta MCP vista pelo Glyph.
///
/// Classe padrão: `external_effect` (irreversível: sempre pede). Só o usuário,
/// no `config.yaml`, pode declarar outra classe para uma ferramenta. As dicas
/// que o próprio servidor manda (`readOnlyHint` etc.) são ignoradas: vêm de
/// quem não é o usuário.
public struct MCPTool: Tool {
    public let server: String
    public let info: MCPToolInfo
    public let declaredClass: ActionClass?
    let client: MCPClient
    public let maxOutput: Int

    public init(server: String, info: MCPToolInfo, declaredClass: ActionClass?, client: MCPClient, maxOutput: Int = 20_000) {
        self.server = server
        self.info = info
        self.declaredClass = declaredClass
        self.client = client
        self.maxOutput = maxOutput
    }

    /// `mcp__<servidor>__<ferramenta>`, só com caracteres aceitos por todo provedor.
    public static func qualifiedName(server: String, tool: String) -> String {
        func clean(_ s: String) -> String {
            String(s.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" || $0 == "-" ? $0 : "_" })
        }
        return String(("mcp__" + clean(server) + "__" + clean(tool)).prefix(64))
    }

    public var spec: ToolSpec {
        var schema = info.inputSchema
        if schema["type"]?.stringValue != "object" { schema = .object(["type": .string("object"), "properties": .object([:])]) }
        let desc = String(info.description.prefix(1000))
        return ToolSpec(name: Self.qualifiedName(server: server, tool: info.name),
                        description: "[MCP \(server)] \(desc)", inputSchema: schema)
    }

    public var actionClass: ActionClass { declaredClass ?? .externalEffect }
    public func scope(_ input: JSONValue) -> String { "mcp:\(server)" }

    public func summarize(_ input: JSONValue) -> String {
        let args = input.description
        return "\(server).\(info.name) " + (args.count > 120 ? String(args.prefix(117)) + "…" : args)
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let args: JSONValue
        if case .object = input { args = input } else { args = .object([:]) }
        let r = try await client.call(info.name, arguments: args)
        var text = r.text
        if text.count > maxOutput { text = String(text.prefix(maxOutput)) + "\n[cortado]" }
        return ToolOutput(markUntrusted(text, source: "mcp:\(server)"), isError: r.isError, untrusted: true)
    }
}
