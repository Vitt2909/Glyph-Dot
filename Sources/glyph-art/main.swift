import Foundation
import GlyphCore

// glyph-art — gera a arte do projeto a partir do próprio motor.
//
//   swift run glyph-art                # escreve em docs/art, Packs/default/stickers e Examples/pack-exemplo/previa
//   swift run glyph-art <pasta-docs>   # outra pasta de saída
//
// Tudo é determinístico: mesma versão do código → mesmos arquivos.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let pack = root.appendingPathComponent("Packs/default", isDirectory: true)
let out = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : root.appendingPathComponent("docs/art", isDirectory: true)

let (clips, clipErrors) = ClipLibrary.load(pack: pack)
let (stickers, stickerErrors) = Sticker.load(pack: pack)
for e in clipErrors + stickerErrors { FileHandle.standardError.write(Data("aviso: \(e)\n".utf8)) }
guard !clips.clips.isEmpty else {
    FileHandle.standardError.write(Data("erro: rode na raiz do repositório (Packs/default não encontrado)\n".utf8))
    exit(1)
}

let fm = FileManager.default
try fm.createDirectory(at: out.appendingPathComponent("clips"), withIntermediateDirectories: true)

func write(_ svg: String, _ url: URL) throws {
    try svg.write(to: url, atomically: true, encoding: .utf8)
    print("ok \(url.path.replacingOccurrences(of: root.path + "/", with: ""))")
}

let paper = "#f4f1ea"
let animator = DotAnimator()
let metrics = SkeletonMetrics()

/// Um quadro de um clipe, com o Dot no modo do clipe.
func frame(clip: Clip, t: Double, at p: Vec2, facing: Double = 1, dot: DotMode? = nil,
           target: Vec2? = nil, eyes: EyesDrawing? = nil, planned: Int = 8) -> GlyphDrawing {
    let pose = clip.sample(at: t)
    let sk = ForwardKinematics.solve(pose, metrics: metrics, facing: facing)
    let mode = dot ?? clip.dot?.mode ?? .steady
    let d = animator.draw(mode: mode, speed: clip.dot?.speed ?? 1, time: t, since: t,
                          head: sk.headCenter, target: target, planned: planned)
    return GlyphDrawing(position: p, skeleton: sk, dot: d, eyes: eyes, boilFrame: Int(t * 24))
}

// MARK: - Prévia de cada clipe (animada)

func clipPreview(_ clip: Clip) -> String {
    let id = clip.id
    let c = SVGRenderer.Canvas(width: 120, height: 96, scale: 1)
    let length = clip.loops ? clip.duration : clip.duration + 0.6
    let n = max(Int((max(length, 0.5) * 12).rounded(.up)), 1)
    var base = Vec2(60, 18)
    var scenery = ""
    if id.hasPrefix("hang") {
        base = Vec2(60, 90 - metrics.height)
        scenery = ##"<path d="M8 6H112" stroke="#c9c4b8" stroke-width="3" stroke-linecap="round"/>"##
    } else if id == "climb" {
        base = Vec2(60, 30)
        scenery = ##"<path d="M71 8V88" stroke="#c9c4b8" stroke-width="3" stroke-linecap="round"/>"##
    } else if id == "sleep" {
        base = Vec2(64, 18)
    }
    if !id.hasPrefix("hang") {
        scenery += ##"<path d="M10 \##(SVGRenderer.num(96 - 18 + 1.5))H110" stroke="#c9c4b8" stroke-width="3" stroke-linecap="round"/>"##
    }
    let frames = (0..<n).map { i -> StickerShapes in
        let t = Double(i) / 12
        return StickerShapes.build(frame(clip: clip, t: t, at: base, target: Vec2(50, 10)))
    }
    // Mesmo desenho, 1,5× maior: reescala o canvas e o cenário juntos.
    let zc = SVGRenderer.Canvas(width: c.width, height: c.height, scale: 1.5)
    let zs = ##"<g transform="scale(1.5)">\##(scenery)</g>"##
    return SVGRenderer.animate(frames, fps: 12, zc, background: paper, scenery: zs, title: "Glyph — \(id)")
}

for id in clips.clips.keys.sorted() {
    try write(clipPreview(clips[id]!), out.appendingPathComponent("clips/\(id).svg"))
}


// MARK: - Galeria de estados (estática)

struct State {
    var label: String
    var clip: String
    var t: Double
    var dot: DotMode?
    var eyes: EyesDrawing?
    var bubble: String?
    var sticker: String?
    var scenery: String = ""
    var hang = false
    var target: Vec2?
}

let states: [State] = [
    State(label: "repouso", clip: "idle", t: 0.4, dot: .steady),
    State(label: "observando", clip: "look", t: 0.2, dot: .glance, eyes: EyesDrawing(look: Vec2(1, 0.3)), target: Vec2(40, 30)),
    State(label: "pensando", clip: "think", t: 0.7, dot: .orbit),
    State(label: "trabalhando", clip: "work", t: 0.4, dot: .trail, target: Vec2(46, 8)),
    State(label: "esperando você", clip: "await", t: 0.3, dot: .steady, eyes: EyesDrawing(), sticker: "cartao"),
    State(label: "perigo", clip: "alert", t: 0.2, dot: .alert, eyes: EyesDrawing()),
    State(label: "erro", clip: "error", t: 1.05, dot: .shrink, eyes: EyesDrawing(look: Vec2(-1, 0), style: .squint), bubble: "hm."),
    State(label: "dormindo", clip: "sleep", t: 0.5, dot: .fade),
    State(label: "carregado", clip: "carried", t: 0.2, dot: .steady),
    State(label: "acenando", clip: "wave", t: 0.42, dot: .pulse, eyes: EyesDrawing(look: Vec2(0, 0.4))),
    State(label: "pendurado", clip: "hang", t: 0.3, dot: .steady, hang: true),
    State(label: "chamando ajuda", clip: "idle", t: 1.2, dot: .split, eyes: EyesDrawing(look: Vec2(1, 0.4))),
]

do {
    let cols = 4, cw = 120.0, ch = 118.0
    let rows = (states.count + cols - 1) / cols
    let c = SVGRenderer.Canvas(width: Double(cols) * cw, height: Double(rows) * ch, scale: 1)
    var body = ""
    for (i, s) in states.enumerated() {
        let col = Double(i % cols), row = Double(rows - 1 - i / cols)
        let ox = col * cw, oy = row * ch
        let groundY = oy + 30
        var p = Vec2(ox + cw / 2, groundY)
        if s.hang {
            let ceilY = oy + ch - 20
            p = Vec2(ox + cw / 2, ceilY - metrics.height)
            let (x0, y0) = (ox + 24, c.height - ceilY)
            body += ##"<path d="M\##(SVGRenderer.num(x0)) \##(SVGRenderer.num(y0))H\##(SVGRenderer.num(ox + cw - 24))" stroke="#c9c4b8" stroke-width="2.5" stroke-linecap="round"/>"##
        } else {
            body += ##"<path d="M\##(SVGRenderer.num(ox + 22)) \##(SVGRenderer.num(c.height - groundY + 1.5))H\##(SVGRenderer.num(ox + cw - 22))" stroke="#c9c4b8" stroke-width="2.5" stroke-linecap="round"/>"##
        }
        let clip = clips[s.clip]!
        var d = frame(clip: clip, t: s.t, at: p, dot: s.dot, target: s.target, eyes: s.eyes)
        if s.label == "esperando você" { d.dot.opacity = 1 }
        body += SVGRenderer.group(StickerShapes.build(d), c)
        if let b = s.bubble {
            body += SVGRenderer.bubble(b, anchor: p + d.skeleton.headCenter + Vec2(12, d.skeleton.headRadius + 6), c)
        }
        if let st = s.sticker, let sticker = stickers[st] {
            let hand = p + Vec2(max(d.skeleton.handL.x, d.skeleton.handR.x) + 9, (d.skeleton.handL.y + d.skeleton.handR.y) / 2 + 4)
            body += SVGRenderer.group(sticker.shapes(at: hand, scale: 0.75), c)
        }
        let (lx, ly) = (ox + cw / 2, c.height - oy - 9)
        body += ##"<text x="\##(SVGRenderer.num(lx))" y="\##(SVGRenderer.num(ly))" text-anchor="middle" font-family="ui-rounded, 'SF Pro Rounded', 'Nunito', system-ui, sans-serif" font-size="9.5" font-weight="600" fill="#5c574e">\##(s.label)</text>"##
    }
    let zoom = 1.6
    let page = SVGRenderer.Canvas(width: c.width * zoom, height: c.height * zoom)
    try write(SVGRenderer.document(page, body: ##"<g transform="scale(\##(zoom))">\##(body)</g>"##, background: paper,
                                   title: "Glyph — estados do Dot"),
              out.appendingPathComponent("estados.svg"))
}

// MARK: - Stickers

do {
    let ids = stickers.keys.sorted()
    let cols = 7, cell = 64.0
    let rows = (ids.count + cols - 1) / cols
    let c = SVGRenderer.Canvas(width: Double(cols) * cell, height: Double(rows) * (cell + 16), scale: 1)
    var body = ""
    for (i, id) in ids.enumerated() {
        let col = Double(i % cols), row = Double(rows - 1 - i / cols)
        let center = Vec2(col * cell + cell / 2, row * (cell + 16) + 16 + cell / 2)
        body += SVGRenderer.group(stickers[id]!.shapes(at: center, scale: 1.4), c)
        body += ##"<text x="\##(SVGRenderer.num(center.x))" y="\##(SVGRenderer.num(c.height - row * (cell + 16) - 6))" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#5c574e">\##(id)</text>"##
        // Arquivo individual, junto do JSON no pack.
        let one = SVGRenderer.Canvas(width: 48, height: 48, scale: 1)
        try write(SVGRenderer.document(one, body: SVGRenderer.group(stickers[id]!.shapes(at: Vec2(24, 24), scale: 1.4), one),
                                       title: "sticker \(id)"),
                  pack.appendingPathComponent("stickers/\(id).svg"))
    }
    try write(SVGRenderer.document(c, body: body, background: paper, title: "Glyph — stickers"),
              out.appendingPathComponent("stickers.svg"))
}

// MARK: - Logo e ícone

do {
    let wave = clips["wave"]!
    // Logo: o Glyph acenando + nome.
    let c = SVGRenderer.Canvas(width: 300, height: 110, scale: 1)
    let fc = SVGRenderer.Canvas(width: c.width / 1.7, height: c.height / 1.7, scale: 1.7)
    let d = frame(clip: wave, t: 0.42, at: Vec2(30, 6), dot: .steady, eyes: EyesDrawing(look: Vec2(0.6, 0.3)))
    var body = SVGRenderer.group(StickerShapes.build(d), fc)
    body += ##"<text x="100" y="78" font-family="ui-rounded, 'SF Pro Rounded', 'Nunito', system-ui, sans-serif" font-size="58" font-weight="800" letter-spacing="-1" fill="#111" stroke="#fff" stroke-width="7" paint-order="stroke" filter="url(#sticker-shadow)">glyph</text>"##
    try write(SVGRenderer.document(c, body: body, title: "Glyph"), out.appendingPathComponent("logo.svg"))

    // Ícone do app: adesivo grande num quadrado arredondado.
    let ic = SVGRenderer.Canvas(width: 1024, height: 1024, scale: 1)
    // Centraliza o Glyph (~46 pt de altura com o braço erguido) no quadrado.
    let big = SVGRenderer.Canvas(origin: Vec2(-45.5, -21.5), width: 1024 / 11.5, height: 1024 / 11.5, scale: 11.5)
    let g = frame(clip: wave, t: 0.42, at: .zero, dot: .steady, eyes: EyesDrawing(look: Vec2(0.4, 0.2)))
    let bg = ##"<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fffdf7"/><stop offset="1" stop-color="#efe8da"/></linearGradient></defs><rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)" stroke="#e2dccf" stroke-width="4"/>"##
    let iconBody = bg + SVGRenderer.group(StickerShapes.build(g), big)
    try write(SVGRenderer.document(ic, body: iconBody, title: "Glyph"), out.appendingPathComponent("icon.svg"))
}

// MARK: - Cena do README: o motor de verdade, gravado a 12 fps

do {
    // Uma "tela" pequena, desenhada 1,5× maior.
    let W = 480.0, H = 230.0, zoom = 1.5
    let screen = ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, width: W, height: H),
                            visibleFrame: Rect(x: 0, y: 26, width: W, height: H - 26 - 16), menuBarHeight: 16)
    let a = WindowInfo(id: 1, pid: 1, frame: Rect(x: 28, y: 64, width: 172, height: 100))
    let b = WindowInfo(id: 2, pid: 2, frame: Rect(x: 262, y: 44, width: 186, height: 92))
    var engine = GlyphEngine(world: WorldSnapshot(screens: [screen], windows: [a, b]), clips: clips, start: Vec2(112, 226))
    engine.needs.curiosity = 0
    engine.needs.sociability = 0

    let fps = 12.0, total = 10.0
    let cursorAt = 6.0, cursorPos = Vec2(420, 196)
    var frames: [StickerShapes] = []
    var waved = false
    for i in 0..<Int(total * fps) {
        let t = Double(i) / fps
        if abs(t - 1.75) < 1e-6 {
            engine.receive(.bodyGoto(BodyGoto(target: .window(pid: 2, frame: b.frame))))
        }
        if t >= cursorAt { engine.setCursor(cursorPos) }
        if t >= cursorAt + 0.6, !waved {
            waved = true
            engine.receive(.bodyEmote(BodyEmote(clip: "wave", dot: .pulse)))
        }
        engine.advance(by: 1 / fps)
        frames.append(engine.drawing.map { StickerShapes.build($0) } ?? StickerShapes())
    }

    let c = SVGRenderer.Canvas(width: W, height: H, scale: zoom)
    func px(_ v: Double) -> String { SVGRenderer.num(v * zoom) }
    var scenery = ""
    // Barra de menu com a casa (pílula no centro).
    scenery += ##"<rect x="0" y="0" width="\##(px(W))" height="\##(px(16))" fill="#e9e5dc"/><rect x="\##(px(W / 2 - 24))" y="\##(px(2.5))" width="\##(px(48))" height="\##(px(11))" rx="\##(px(5.5))" fill="#111"/>"##
    scenery += SVGRenderer.window(a.frame, c, title: "Terminal")
    scenery += SVGRenderer.window(b.frame, c, title: "Notas")
    // Dock.
    let colors = ["#9ec5fe", "#ffd166", "#b5e48c", "#f4a261", "#cdb4db", "#90dbf4"]
    let dockW = 212.0, dockX = (W - dockW) / 2
    scenery += ##"<rect x="\##(px(dockX))" y="\##(px(H - 24))" width="\##(px(dockW))" height="\##(px(22))" rx="\##(px(7))" fill="#e2ddd2" stroke="#d3cdc0"/>"##
    for (k, color) in colors.enumerated() {
        scenery += ##"<rect x="\##(px(dockX + 9 + Double(k) * 33.5))" y="\##(px(H - 21))" width="\##(px(16))" height="\##(px(16))" rx="\##(px(4.5))" fill="\##(color)"/>"##
    }
    // Cursor, que aparece no meio da cena para ele acenar.
    let (cx, cy) = (cursorPos.x * zoom, (H - cursorPos.y) * zoom)
    let arrow = "M0 0L0 17L4.5 13L7.5 20L10.5 18.7L7.5 12L13 12Z"
    let key = SVGRenderer.num(cursorAt / total)
    scenery += ##"<g transform="translate(\##(SVGRenderer.num(cx)) \##(SVGRenderer.num(cy)))" opacity="0"><animate attributeName="opacity" dur="\##(SVGRenderer.num(total))s" repeatCount="indefinite" calcMode="discrete" keyTimes="0;\##(key)" values="0;1"/><path d="\##(arrow)" fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></g>"##

    try write(SVGRenderer.animate(frames, fps: fps, c, background: paper, scenery: scenery,
                                  title: "Glyph andando pelas janelas"),
              out.appendingPathComponent("hero.svg"))
}

// MARK: - Multi-Glyph: o time

do {
    let W = 420.0, H = 150.0, zoom = 1.5
    let screen = ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, width: W, height: H),
                            visibleFrame: Rect(x: 0, y: 20, width: W, height: H - 20 - 14), menuBarHeight: 14)
    var engine = GlyphEngine(world: WorldSnapshot(screens: [screen]), clips: clips, stickers: stickers, start: Vec2(W / 2, 22))
    engine.needs.curiosity = 0
    engine.needs.sociability = 0
    engine.needs.energy = 1
    let fps = 12.0, total = 9.0
    struct Line { var at: Double; var text: String; var who: String? }
    let script: [Line] = [
        Line(at: 3.4, text: "terminou?", who: nil),
        Line(at: 4.2, text: "sim.", who: "builder"),
        Line(at: 5.0, text: "não.", who: "auditor"),
        Line(at: 6.4, text: "aprovado.", who: "auditor"),
    ]
    var frames: [StickerShapes] = []
    var bubbles: [(text: String, anchor: Vec2, start: Double, end: Double)] = []
    var said = Set<Int>()
    for i in 0..<Int(total * fps) {
        let t = Double(i) / fps
        if abs(t - 0.5) < 1e-6 { engine.receive(.agentSpawn(AgentSpawn(agentId: "builder-1", role: .builder))) }
        if abs(t - 1.25) < 1e-6 { engine.receive(.agentSpawn(AgentSpawn(agentId: "auditor-2", role: .auditor))) }
        if abs(t - 7.5) < 1e-6 {
            engine.receive(.agentDespawn(AgentDespawn(agentId: "builder-1")))
            engine.receive(.agentDespawn(AgentDespawn(agentId: "auditor-2")))
        }
        for (k, line) in script.enumerated() where t >= line.at && !said.contains(k) {
            said.insert(k)
            let who = line.who.flatMap { key in engine.companions.first { $0.id.hasPrefix(key) } }
            let base = who?.body.position ?? engine.body.position
            bubbles.append((line.text, base + Vec2(0, SkeletonMetrics().height + 10), line.at, line.at + 1.4))
        }
        engine.advance(by: 1 / fps)
        var merged = StickerShapes()
        for d in engine.drawings where d.opacity > 0.05 {
            let s = StickerShapes.build(d)
            merged.strokes += s.strokes; merged.fills += s.fills; merged.discs += s.discs
        }
        frames.append(merged)
    }
    let c = SVGRenderer.Canvas(width: W, height: H, scale: zoom)
    var scenery = ##"<path d="M\##(SVGRenderer.num(20 * zoom)) \##(SVGRenderer.num((H - 20) * zoom + 1.5))H\##(SVGRenderer.num((W - 20) * zoom))" stroke="#c9c4b8" stroke-width="3" stroke-linecap="round"/>"##
    var overlay = ""
    for b in bubbles {
        let k0 = SVGRenderer.num(b.start / total), k1 = SVGRenderer.num(min(b.end / total, 1))
        overlay += ##"<g opacity="0"><animate attributeName="opacity" dur="\##(SVGRenderer.num(total))s" repeatCount="indefinite" calcMode="discrete" keyTimes="0;\##(k0);\##(k1)" values="0;1;0"/>\##(SVGRenderer.bubble(b.text, anchor: b.anchor, c))</g>"##
    }
    scenery += ""
    var svg = SVGRenderer.animate(frames, fps: fps, c, background: paper, scenery: scenery, title: "Glyph chamando o time: Builder e Auditor")
    svg = svg.replacingOccurrences(of: "</svg>", with: overlay + "</svg>")
    try write(svg, out.appendingPathComponent("equipe.svg"))
}

// MARK: - Pack de exemplo da comunidade

do {
    let dir = root.appendingPathComponent("Examples/pack-exemplo", isDirectory: true)
    let p = PackLoader.loadPack(dir, requireManifest: true)
    for e in p.errors { FileHandle.standardError.write(Data("aviso: \(e)\n".utf8)) }
    let previa = dir.appendingPathComponent("previa", isDirectory: true)
    try fm.createDirectory(at: previa, withIntermediateDirectories: true)
    for id in p.clips.clips.keys.sorted() {
        try write(clipPreview(p.clips[id]!), previa.appendingPathComponent("\(id).svg"))
    }
    for id in p.stickers.keys.sorted() {
        let one = SVGRenderer.Canvas(width: 48, height: 48, scale: 1)
        try write(SVGRenderer.document(one, body: SVGRenderer.group(p.stickers[id]!.shapes(at: Vec2(24, 24), scale: 1.4), one),
                                       background: paper, title: "sticker \(id)"),
                  previa.appendingPathComponent("\(id).svg"))
    }
}
