import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GlyphCore
@testable import GlyphDaemon

/// Transporte HTTP falso: responde com o que o teste mandar e guarda os pedidos.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (URLRequest) -> (Int, Data)
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping (URLRequest) -> (Int, Data)) { self.handler = handler }

    convenience init(status: Int = 200, json: String) {
        self.init { _ in (status, Data(json.utf8)) }
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        record(request)
        return handler(request)
    }

    private func record(_ r: URLRequest) {
        lock.lock(); requests.append(r); lock.unlock()
    }

    var lastBody: JSONValue? {
        lock.lock(); defer { lock.unlock() }
        return requests.last?.httpBody.flatMap { try? JSONValue.parse($0) }
    }
}

/// Ferramenta falsa com classe configurável.
struct FakeTool: Tool {
    var name: String
    var cls: ActionClass
    var output: String
    var untrusted = false
    var toolPlace: ToolPlace = .none
    let calls = Counter()

    var spec: ToolSpec { ToolSpec(name: name, description: "falsa", inputSchema: .object(["type": .string("object")])) }
    var actionClass: ActionClass { cls }
    var place: ToolPlace { toolPlace }

    func run(_ input: JSONValue) async throws -> ToolOutput {
        calls.increment()
        return ToolOutput(output, untrusted: untrusted)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

func toolUse(_ name: String, _ input: [String: JSONValue] = [:], id: String = "t1", text: String = "") -> BrainReply {
    BrainReply(text: text, toolCalls: [ToolCall(id: id, name: name, input: .object(input))], stop: .toolUse)
}

let duckHTML = """
<div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.bcb.gov.br%2Fcotacoes&amp;rut=x">Cotação do <b>dólar</b> hoje</a>
<a class="result__snippet" href="x">Dólar comercial: <b>R$ 5,42</b> na venda.</a></div>
<div class="result"><a rel="nofollow" class="result__a" href="https://example.com/2">Outro</a>
<a class="result__snippet" href="y">segundo trecho</a></div>
"""
