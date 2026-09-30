import Foundation
import GlyphCore

/// "Faça isso para o cliente seguinte": o cérebro chama uma rotina aprovada.
/// A primeira vez com novos parâmetros só ensaia (mostra os passos). Rotina
/// com passo irreversível não roda por aqui: cada passo desses precisa do
/// próprio cartão (use /rotina no campo de chamada).
public struct RoutineTool: Tool {
    public let store: RoutineStore
    public let shell: ShellTool

    public init(store: RoutineStore, shell: ShellTool) {
        self.store = store
        self.shell = shell
    }

    public var spec: ToolSpec {
        let names = store.list().filter(\.approved).map { r in
            r.name + (r.parameters.isEmpty ? "" : " (" + r.parameters.keys.sorted().joined(separator: ", ") + ")")
        }
        return ToolSpec(name: "rotina",
                        description: "Roda uma rotina que o usuário ensinou e aprovou"
                            + (names.isEmpty ? " (nenhuma ainda)" : ": " + names.joined(separator: "; ")) + ". "
                            + "Com parâmetros novos, a primeira chamada só ensaia; chame de novo para executar.",
                        inputSchema: schema([("nome", "nome da rotina", true),
                                             ("parametros", "ex.: cliente=beta projeto=x", false)]))
    }

    public var actionClass: ActionClass { .localWrite }

    func parse(_ input: JSONValue) -> (Routine?, [String: String]) {
        let r = input["nome"]?.stringValue.flatMap(store.load)
        let values = RoutineStore.parseValues((input["parametros"]?.stringValue ?? "").split(separator: " ").map(String.init))
        return (r, values)
    }

    public func classify(_ input: JSONValue) -> ActionClass {
        let (r, values) = parse(input)
        guard let r else { return .read }
        // Ainda não ensaiado: só mostra.
        guard r.wasRehearsed(values), let steps = r.instantiate(values) else { return .read }
        return steps.map(\.actionClass).reduce(ActionClass.read) { CommandClassifier.max($0, $1) }
    }

    public func scope(_ input: JSONValue) -> String {
        let (r, values) = parse(input)
        return r?.instantiate(values)?.first.map { Scope.normalize(ShellTool.expand($0.cwd)) } ?? "*"
    }

    public func summarize(_ input: JSONValue) -> String {
        let (r, values) = parse(input)
        guard let r else { return "rotina \(input["nome"]?.stringValue ?? "?")" }
        let v = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "rotina \(r.name) \(v): \(r.steps.count) passos" + (r.wasRehearsed(values) ? "" : " (ensaio)")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let (r, values) = parse(input)
        guard let r else { throw ToolError.badInput("rotina desconhecida") }
        guard r.approved else { throw ToolError.forbidden("\(r.name) ainda é rascunho: o usuário precisa aprovar") }
        if !r.wasRehearsed(values) {
            do {
                let steps = try store.rehearse(r.name, values: values)
                let lines = steps.map { "- `\($0.command)` em \($0.cwd) · \($0.actionClass.rawValue)\($0.forbidden ? " (proibido)" : "")" }
                return ToolOutput("ensaio (nada foi executado):\n" + lines.joined(separator: "\n") + "\nchame de novo para executar.")
            } catch {
                throw ToolError.badInput("\(error)")
            }
        }
        guard r.instantiate(values)?.contains(where: \.isIrreversible) == false else {
            throw ToolError.forbidden("a rotina tem passo irreversível: rode com /rotina \(r.name) no campo de chamada")
        }
        do {
            // O portão já aprovou esta chamada na classe mais arriscada dela.
            let result = try await store.run(r.name, values: values, decide: { _ in .actSilently }, approve: { _, _ in false },
                                             exec: { s in try await shell.run(.object(["command": .string(s.command),
                                                                                      "cwd": .string(ShellTool.expand(s.cwd))])) })
            return ToolOutput(result.text, isError: result.stoppedAt != nil)
        } catch let e as RoutineStore.StoreError {
            throw ToolError.failed(e.description)
        }
    }
}
