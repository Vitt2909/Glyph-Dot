import Foundation
import GlyphCore

/// Guarda os planos de ensaio (`casa/ensaios/<id>.json`), aplica e desfaz.
///
/// Aplicar grava um manifesto em `casa/journal/ensaio-<id>.json` a cada
/// arquivo movido (se o processo cair no meio, o que já foi feito continua
/// desfazível). Desfazer volta o plano inteiro, em ordem inversa. Nunca
/// apaga, nunca sobrescreve, nunca sai da pasta do plano.
public struct RehearsalStore: Sendable {
    public let paths: GlyphPaths

    public init(paths: GlyphPaths) { self.paths = paths }

    /// Um movimento feito (caminhos absolutos).
    public struct Moved: Sendable, Codable, Equatable {
        public var from: String
        public var to: String
    }

    public struct Manifest: Sendable, Codable, Equatable {
        public var plan: String
        public var root: String
        public var moved: [Moved]
        /// Pastas que o plano criou (para remover no desfazer, se vazias).
        public var createdDirs: [String]
    }

    public struct ApplyResult: Sendable, Equatable {
        public var moved: Int
        public var skipped: [String]
        public var text: String
    }

    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case notAllowed(String)
        case wrongState(String)

        public var description: String {
            switch self {
            case let .notFound(m): return "não achei o plano \(m)"
            case let .notAllowed(m): return "fora do permitido: \(m)"
            case let .wrongState(m): return m
            }
        }
    }

    // MARK: - Planos

    func url(_ id: String) -> URL { paths.ensaios.appendingPathComponent("\(id).json") }
    func manifestURL(_ id: String) -> URL { paths.journal.appendingPathComponent("ensaio-\(id).json") }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    public func load(_ id: String) throws -> RehearsalPlan {
        guard Self.validID(id), let data = try? Data(contentsOf: url(id)) else { throw StoreError.notFound(id) }
        return try JSONDecoder.glyph.decode(RehearsalPlan.self, from: data)
    }

    public func save(_ plan: RehearsalPlan) throws {
        try FileManager.default.createDirectory(at: paths.ensaios, withIntermediateDirectories: true)
        try JSONEncoder.glyph.encode(plan).write(to: url(plan.id), options: .atomic)
    }

    public func list() -> [RehearsalPlan] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.ensaios, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.glyph.decode(RehearsalPlan.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created < $1.created }
    }

    /// Lê a pasta (um nível, sem conteúdo dos arquivos) e monta o plano.
    public func prepare(folder: String, now: Date = Date()) throws -> RehearsalPlan {
        let root = Self.resolve(folder)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { throw StoreError.notFound(folder) }
        let names = try fm.contentsOfDirectory(atPath: root)
        var entries: [FileEntry] = []
        for n in names {
            let p = (root as NSString).appendingPathComponent(n)
            let a = try? fm.attributesOfItem(atPath: p)
            let type = a?[.type] as? FileAttributeType
            entries.append(FileEntry(name: n, isDirectory: type == .typeDirectory,
                                     size: (a?[.size] as? NSNumber)?.int64Value ?? 0,
                                     modified: a?[.modificationDate] as? Date ?? .distantPast))
        }
        // O que já existe nas pastas de destino, para não sobrescrever.
        var existing: Set<String> = []
        for (folder, _) in FileOrganizer.categories {
            let dir = (root as NSString).appendingPathComponent(folder)
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { existing.insert("\(folder)/\(n)") }
        }
        let id = "e" + String(ISO8601.format(now).filter(\.isNumber).prefix(14)) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        let plan = FileOrganizer.plan(id: id, root: root, entries: entries, existing: existing, now: now)
        try save(plan)
        return plan
    }

    public func decide(_ id: String, decision: String, choice: PlanDecision.Choice) throws -> RehearsalPlan {
        var plan = try load(id)
        guard plan.status == .proposed else { throw StoreError.wrongState("o plano \(id) já foi \(plan.status.rawValue)") }
        guard let i = plan.decisions.firstIndex(where: { $0.id == decision }) else { throw StoreError.notFound("\(id)/\(decision)") }
        guard plan.decisions[i].options.contains(choice) else {
            throw StoreError.wrongState("\(decision) aceita: \(plan.decisions[i].options.map(\.rawValue).joined(separator: ", "))")
        }
        plan.decisions[i].choice = choice
        try save(plan)
        return plan
    }

    // MARK: - Aplicar e desfazer

    /// Aplica os passos reversíveis. Irreversíveis (se algum plano os tiver)
    /// não são cobertos pela aprovação do plano: `approveIrreversible` pede um
    /// cartão para cada um, na hora.
    public func apply(_ id: String, approveIrreversible: (PlanStep) async -> Bool = { _ in false }) async throws -> ApplyResult {
        var plan = try load(id)
        guard plan.status == .proposed else { throw StoreError.wrongState("o plano \(id) já foi \(plan.status.rawValue)") }
        let fm = FileManager.default
        let root = Self.resolve(plan.root)
        var manifest = Manifest(plan: id, root: root, moved: [], createdDirs: [])
        var skipped: [String] = []
        let keepBoth = Set(plan.decisions.filter { $0.choice == .keepBoth }.map(\.id))

        for step in plan.effectiveSteps() {
            if step.actionClass.isReversible == false, !(await approveIrreversible(step)) {
                skipped.append("\(step.from): irreversível, não aprovado")
                continue
            }
            guard FileOrganizer.isSafeRelative(step.from), FileOrganizer.isSafeRelative(step.to) else {
                skipped.append("\(step.from): caminho recusado")
                continue
            }
            let src = (root as NSString).appendingPathComponent(step.from)
            var dst = (root as NSString).appendingPathComponent(step.to)
            guard fm.fileExists(atPath: src) || Self.isSymlink(src) else {
                skipped.append("\(step.from): não existe mais")
                continue
            }
            let dir = (dst as NSString).deletingLastPathComponent
            if Self.isSymlink(dir) {
                skipped.append("\(step.from): destino é link simbólico")
                continue
            }
            guard Self.resolve(dir).hasPrefix(root + "/") || Self.resolve(dir) == root else {
                skipped.append("\(step.from): destino fora da pasta")
                continue
            }
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: false)
                manifest.createdDirs.append(dir)
            }
            if fm.fileExists(atPath: dst) || Self.isSymlink(dst) {
                guard keepBoth.contains(step.id) else {
                    skipped.append("\(step.from): \(step.to) apareceu depois do ensaio")
                    continue
                }
                dst = Self.freeOnDisk(dst)
            }
            do {
                try fm.moveItem(atPath: src, toPath: dst)
            } catch {
                skipped.append("\(step.from): \(error.localizedDescription)")
                continue
            }
            manifest.moved.append(Moved(from: src, to: dst))
            try writeManifest(manifest)
        }
        try writeManifest(manifest)
        plan.status = .applied
        try save(plan)
        let text = "\(plan.title): movi \(manifest.moved.count)" + (skipped.isEmpty ? "." : "; deixei \(skipped.count) como estava.")
        return ApplyResult(moved: manifest.moved.count, skipped: skipped, text: text)
    }

    /// Desfaz o plano inteiro, do último movimento ao primeiro.
    public func undo(_ id: String) throws -> ApplyResult {
        var plan = try load(id)
        guard plan.status == .applied else { throw StoreError.wrongState("o plano \(id) está \(plan.status.rawValue)") }
        guard let data = try? Data(contentsOf: manifestURL(id)),
              let manifest = try? JSONDecoder.glyph.decode(Manifest.self, from: data) else { throw StoreError.notFound("manifesto de \(id)") }
        let fm = FileManager.default
        var back = 0
        var skipped: [String] = []
        for m in manifest.moved.reversed() {
            guard m.from.hasPrefix(manifest.root + "/"), m.to.hasPrefix(manifest.root + "/") else {
                skipped.append("\(m.to): fora da pasta")
                continue
            }
            guard fm.fileExists(atPath: m.to) || Self.isSymlink(m.to) else {
                skipped.append("\((m.to as NSString).lastPathComponent): não está mais em \(Self.relative(m.to, manifest.root))")
                continue
            }
            guard !fm.fileExists(atPath: m.from) else {
                skipped.append("\((m.from as NSString).lastPathComponent): já existe outro no lugar original")
                continue
            }
            do {
                try fm.moveItem(atPath: m.to, toPath: m.from)
                back += 1
            } catch {
                skipped.append("\(m.to): \(error.localizedDescription)")
            }
        }
        for dir in manifest.createdDirs.reversed() where ((try? fm.contentsOfDirectory(atPath: dir)) ?? ["x"]).isEmpty {
            try? fm.removeItem(atPath: dir) // só pasta vazia que o próprio plano criou
        }
        plan.status = .undone
        try save(plan)
        let text = "\(plan.title): desfeito (\(back) de volta)" + (skipped.isEmpty ? "." : "; \(skipped.count) não deu.")
        return ApplyResult(moved: back, skipped: skipped, text: text)
    }

    func writeManifest(_ m: Manifest) throws {
        try FileManager.default.createDirectory(at: paths.journal, withIntermediateDirectories: true)
        try JSONEncoder.glyph.encode(m).write(to: manifestURL(m.plan), options: .atomic)
    }

    static func resolve(_ path: String) -> String {
        let p = path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
        return URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func relative(_ path: String, _ root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    static func freeOnDisk(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { "\(dir)/\($0)".lowercased() })
        return FileOrganizer.freeName(path, taken: names.union([path.lowercased()]))
    }
}
