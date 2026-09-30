import Foundation
import GlyphCore

/// Pastas que o modo ensaio pode organizar (`ferramentas.organizar.pastas`).
public struct RehearsalScope: Sendable, Equatable {
    public var folders: [String]

    public init(folders: [String]) { self.folders = folders.map(RehearsalStore.resolve) }

    public func allows(_ folder: String) -> Bool {
        let f = RehearsalStore.resolve(folder)
        return folders.contains(f)
    }
}

/// Ensaia a organização de uma pasta: monta o plano sem mexer em nada.
public struct RehearseTool: Tool {
    public let store: RehearsalStore
    public let scope: RehearsalScope

    public init(store: RehearsalStore, scope: RehearsalScope) {
        self.store = store
        self.scope = scope
    }

    public var spec: ToolSpec {
        ToolSpec(name: "ensaiar_organizacao",
                 description: "Prepara um plano para organizar uma pasta (\(scope.folders.map(Explanation.shortPath).joined(separator: ", "))) "
                    + "SEM mexer em nada: o que seria movido, renomeado e os casos que precisam de decisão. "
                    + "Devolve o id do plano. Para executar, use aplicar_plano com esse id.",
                 inputSchema: schema([("pasta", "Pasta a organizar", true)]))
    }

    public var actionClass: ActionClass { .read }
    public func summarize(_ input: JSONValue) -> String { "ensaiar: organizar \(input["pasta"]?.stringValue ?? "?")" }
    public func scope(_ input: JSONValue) -> String { Scope.normalize(RehearsalStore.resolve(input["pasta"]?.stringValue ?? "~")) }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        guard let folder = input["pasta"]?.stringValue, !folder.isEmpty else { throw ToolError.badInput("falta pasta") }
        guard scope.allows(folder) else {
            throw ToolError.forbidden("só organizo \(scope.folders.map(Explanation.shortPath).joined(separator: ", ")) (ferramentas.organizar.pastas)")
        }
        let plan = try store.prepare(folder: folder)
        // Nomes de arquivos são conteúdo observado: dado, não instrução.
        return ToolOutput("plano \(plan.id)\n" + markUntrusted(plan.preview().joined(separator: "\n"), source: "pasta"),
                          untrusted: true)
    }
}

/// Aplica um plano de ensaio aprovado. Reversível: o histórico guarda como
/// desfazer o plano inteiro.
public struct ApplyPlanTool: Tool {
    public let store: RehearsalStore

    public init(store: RehearsalStore) { self.store = store }

    public var spec: ToolSpec {
        ToolSpec(name: "aplicar_plano",
                 description: "Executa um plano de ensaio (mover e renomear dentro da pasta, nunca apagar nem sobrescrever). "
                    + "Casos sem decisão ficam como estão. Dá para desfazer o plano inteiro.",
                 inputSchema: schema([("plano", "id do plano (de ensaiar_organizacao)", true)]))
    }

    public var actionClass: ActionClass { .localWrite }

    public func summarize(_ input: JSONValue) -> String {
        let id = input["plano"]?.stringValue ?? "?"
        guard let plan = try? store.load(id) else { return "aplicar o plano \(id)" }
        return "\(plan.title): \(plan.summary)"
    }

    public func scope(_ input: JSONValue) -> String {
        let id = input["plano"]?.stringValue ?? ""
        return Scope.normalize((try? store.load(id))?.root ?? "?")
    }

    public func inverse(_ input: JSONValue) -> HistoryEntry.Inverse? {
        guard let id = input["plano"]?.stringValue else { return nil }
        return HistoryEntry.Inverse(tool: "desfazer_plano", input: .object(["plano": .string(id)]), summary: "desfazer o plano \(id)")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        guard let id = input["plano"]?.stringValue else { throw ToolError.badInput("falta plano") }
        do {
            let r = try await store.apply(id)
            return ToolOutput(([r.text] + r.skipped.prefix(10).map { "  - " + $0 }).joined(separator: "\n"))
        } catch let e as RehearsalStore.StoreError {
            throw ToolError.failed(e.description)
        }
    }
}

/// Desfaz um plano aplicado (volta tudo, em ordem inversa).
public struct UndoPlanTool: Tool {
    public let store: RehearsalStore

    public init(store: RehearsalStore) { self.store = store }

    public var spec: ToolSpec {
        ToolSpec(name: "desfazer_plano",
                 description: "Desfaz um plano de ensaio aplicado: devolve cada arquivo ao lugar e ao nome de antes.",
                 inputSchema: schema([("plano", "id do plano", true)]))
    }

    public var actionClass: ActionClass { .localWrite }
    public func summarize(_ input: JSONValue) -> String { "desfazer o plano \(input["plano"]?.stringValue ?? "?")" }

    public func scope(_ input: JSONValue) -> String {
        Scope.normalize((try? store.load(input["plano"]?.stringValue ?? ""))?.root ?? "?")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        guard let id = input["plano"]?.stringValue else { throw ToolError.badInput("falta plano") }
        do {
            let r = try store.undo(id)
            return ToolOutput(([r.text] + r.skipped.prefix(10).map { "  - " + $0 }).joined(separator: "\n"), isError: r.moved == 0 && !r.skipped.isEmpty)
        } catch let e as RehearsalStore.StoreError {
            throw ToolError.failed(e.description)
        }
    }
}
