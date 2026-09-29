import Foundation

/// Conversão entre o sistema do `CGWindowList` e o do AppKit.
///
/// Único lugar do projeto que sabe que o `CGWindowList` usa origem no topo
/// esquerdo da tela principal com y para baixo. Todo o resto usa AppKit:
/// origem embaixo à esquerda, y para cima.
public enum WorldCoordinates {
    /// `primaryHeight`: altura da tela principal (a que contém a origem).
    public static func fromCG(_ r: Rect, primaryHeight: Double) -> Rect {
        Rect(x: r.x, y: primaryHeight - r.y - r.height, width: r.width, height: r.height)
    }

    public static func toCG(_ r: Rect, primaryHeight: Double) -> Rect {
        Rect(x: r.x, y: primaryHeight - r.y - r.height, width: r.width, height: r.height)
    }

    public static func fromCG(_ p: Vec2, primaryHeight: Double) -> Vec2 {
        Vec2(p.x, primaryHeight - p.y)
    }
}

/// Uma janela visível, em coordenadas do AppKit.
public struct WindowInfo: Sendable, Hashable, Codable {
    public var id: UInt32
    public var pid: Int32
    public var frame: Rect

    public init(id: UInt32, pid: Int32, frame: Rect) {
        self.id = id
        self.pid = pid
        self.frame = frame
    }
}

/// Uma tela. `notch` é a área física da notch, se houver.
public struct ScreenInfo: Sendable, Hashable, Codable {
    public var id: UInt32
    public var frame: Rect
    public var visibleFrame: Rect
    public var menuBarHeight: Double
    public var notch: Rect?

    public init(id: UInt32, frame: Rect, visibleFrame: Rect, menuBarHeight: Double = 24, notch: Rect? = nil) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.menuBarHeight = menuBarHeight
        self.notch = notch
    }

    /// Linha de baixo da barra de menu: o teto andável (pendurado).
    public var ceilingY: Double { frame.maxY - menuBarHeight }

    /// O chão: topo do Dock se ele estiver embaixo, senão a borda da tela.
    public var floorY: Double {
        visibleFrame.minY > frame.minY + 1 ? visibleFrame.minY : frame.minY
    }

    /// A casa: a notch, ou uma pílula centralizada no topo.
    public var home: Rect {
        if let notch { return notch }
        let w = 64.0
        return Rect(x: frame.midX - w / 2, y: ceilingY, width: w, height: menuBarHeight)
    }
}

/// O que o corpo leu do sistema num instante.
public struct WorldSnapshot: Sendable, Equatable, Codable {
    public var screens: [ScreenInfo]
    /// Janelas normais (camada 0), **da frente para trás**.
    public var windows: [WindowInfo]

    public init(screens: [ScreenInfo], windows: [WindowInfo] = []) {
        self.screens = screens
        self.windows = windows
    }
}

/// O que mudou entre dois snapshots, por janela.
public struct WorldDiff: Sendable, Equatable {
    public var removed: Set<UInt32> = []
    public var added: Set<UInt32> = []
    /// Janelas que mudaram de lugar ou tamanho: quadro antigo e novo.
    public var changed: [UInt32: (old: Rect, new: Rect)] = [:]
    public var screensChanged = false

    public init() {}

    public var isEmpty: Bool { removed.isEmpty && added.isEmpty && changed.isEmpty && !screensChanged }

    public static func == (a: WorldDiff, b: WorldDiff) -> Bool {
        a.removed == b.removed && a.added == b.added && a.screensChanged == b.screensChanged
            && a.changed.keys == b.changed.keys
            && a.changed.allSatisfy { k, v in b.changed[k].map { $0.old == v.old && $0.new == v.new } ?? false }
    }

    public static func between(_ old: WorldSnapshot, _ new: WorldSnapshot) -> WorldDiff {
        var d = WorldDiff()
        let o = Dictionary(old.windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let n = Dictionary(new.windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        d.removed = Set(o.keys).subtracting(n.keys)
        d.added = Set(n.keys).subtracting(o.keys)
        for (id, nf) in n {
            if let of = o[id], of != nf { d.changed[id] = (of, nf) }
        }
        d.screensChanged = old.screens != new.screens
        return d
    }

    /// Deslocamento que um corpo apoiado no topo da janela herda.
    /// Usa o canto superior esquerdo: arrastar move tudo; redimensionar pela
    /// borda direita ou de baixo não mexe em quem está em cima.
    public static func topLeftDelta(old: Rect, new: Rect) -> Vec2 {
        Vec2(new.minX - old.minX, new.maxY - old.maxY)
    }
}
