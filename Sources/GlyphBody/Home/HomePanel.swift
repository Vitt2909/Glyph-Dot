#if canImport(AppKit)
import AppKit
import SwiftUI
import GlyphCore

/// A casa: o único painel "tradicional". Só leitura dos arquivos da casa,
/// com atalhos para abrir no Finder e no editor. Editar é com o `glyphd` ou
/// à mão nos arquivos (que são legíveis de propósito).
@MainActor
public final class HomePanelController {
    private var window: NSWindow?
    let support: URL

    public init(support: URL = HomePanelController.defaultSupport) {
        self.support = support
    }

    public static var defaultSupport: URL {
        if let custom = ProcessInfo.processInfo.environment["GLYPH_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glyph", isDirectory: true)
    }

    public func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Casa do Glyph"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.contentView = NSHostingView(rootView: HomeView(casa: support.appendingPathComponent("casa")))
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HomeView: View {
    let casa: URL

    var body: some View {
        TabView {
            FilesTab(title: "Memória", dir: casa.appendingPathComponent("memoria"), casa: casa)
                .tabItem { Text("Memória") }
            TextTab(title: "Tarefas", text: Self.board(casa), file: casa.appendingPathComponent("quadro.json"))
                .tabItem { Text("Tarefas") }
            FilesTab(title: "Skills", dir: casa.appendingPathComponent("skills"), casa: casa)
                .tabItem { Text("Skills") }
            HistoryTab(rows: Self.historyRows(casa), file: casa.appendingPathComponent("historico.jsonl"))
                .tabItem { Text("Histórico") }
            TextTab(title: "Cérebro", text: Self.read(casa.appendingPathComponent("config.yaml")),
                    file: casa.appendingPathComponent("config.yaml"))
                .tabItem { Text("Cérebro") }
            TextTab(title: "Política", text: Self.read(casa.appendingPathComponent("policy.yaml"))
                        + "\n\n# Escada de confiança\n" + Self.read(casa.appendingPathComponent("confianca.json")),
                    file: casa.appendingPathComponent("policy.yaml"))
                .tabItem { Text("Política") }
        }
        .padding(12)
        .frame(minWidth: 520, minHeight: 360)
    }

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "(ainda não existe: \(url.lastPathComponent))"
    }

    static func board(_ casa: URL) -> String {
        guard let data = try? Data(contentsOf: casa.appendingPathComponent("quadro.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = obj["tasks"] as? [[String: Any]], !tasks.isEmpty else { return "quadro vazio" }
        return tasks.suffix(40).map { t in
            let status = t["status"] as? String ?? "?"
            let title = t["title"] as? String ?? "?"
            let note = (t["note"] as? String).map { "\n    \($0)" } ?? ""
            let attempts = (t["attempts"] as? [[String: Any]] ?? []).enumerated().map { i, a in
                "\n    \(i + 1). \((a["success"] as? Bool) == true ? "✓" : "✗") \(a["hypothesis"] as? String ?? "")"
            }.joined()
            return "[\(status)] \(title)\(attempts)\(note)"
        }.joined(separator: "\n\n")
    }

    /// Últimas entradas, da mais nova para a mais velha. Cada uma abre a
    /// explicação ("por que você fez isso?"), montada do que foi registrado.
    static func historyRows(_ casa: URL) -> [HistoryRow] {
        let text = (try? String(contentsOf: casa.appendingPathComponent("historico.jsonl"), encoding: .utf8)) ?? ""
        let rows = text.split(separator: "\n").suffix(60).enumerated().compactMap { i, line -> HistoryRow? in
            let data = Data(line.utf8)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let who = (obj["origin"] as? String) == "autonomous" ? "sozinho" : "pedido"
            let ts = (obj["ts"] as? String).map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? ""
            let title = "\(ts)  \(who)  \(obj["outcome"] as? String ?? "")  \(obj["summary"] as? String ?? "")"
            let why = (try? JSONDecoder().decode(WhyRecord.self, from: data)).map(Explanation.lines) ?? []
            return HistoryRow(id: "\(i)-\(obj["id"] as? String ?? "")", title: title, why: why)
        }
        return rows.reversed()
    }
}

struct HistoryRow: Identifiable {
    let id: String
    let title: String
    let why: [String]
}

struct HistoryTab: View {
    let rows: [HistoryRow]
    let file: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text("nada ainda").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(rows) { row in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(row.why.enumerated()), id: \.offset) { _, line in
                                Text(line).textSelection(.enabled)
                            }
                        }
                    } label: {
                        Text(row.title).font(.system(.body, design: .monospaced)).lineLimit(1)
                    }
                }
            }
            HStack {
                Button("Abrir arquivo") { NSWorkspace.shared.open(file) }
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
    }
}

struct TextTab: View {
    let title: String
    let text: String
    let file: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Abrir arquivo") { NSWorkspace.shared.open(file) }
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
    }
}

struct FilesTab: View {
    let title: String
    let dir: URL
    let casa: URL

    var files: [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if files.isEmpty {
                Text("vazio por enquanto").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(files, id: \.self) { f in
                    HStack {
                        Text(f.path.replacingOccurrences(of: dir.path + "/", with: ""))
                        Spacer()
                        Button("Abrir") { NSWorkspace.shared.open(f) }
                    }
                }
            }
            Button("Mostrar pasta no Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        }
    }
}
#endif
