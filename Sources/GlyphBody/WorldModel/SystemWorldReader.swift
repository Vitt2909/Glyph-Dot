#if canImport(AppKit)
import AppKit
import CoreGraphics
import GlyphCore

/// Lê telas e janelas do sistema e monta um `WorldSnapshot`.
///
/// Não pede nenhuma permissão: os limites das janelas vêm do `CGWindowList`
/// sem gravação de tela, e não lemos títulos.
@MainActor
public struct SystemWorldReader {
    /// Janelas menores que isto não viram plataforma.
    public var minWindowSize = CGSize(width: 60, height: 40)
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    public func read() -> (snapshot: WorldSnapshot, fullscreen: Bool) {
        let screens = NSScreen.screens.map(screenInfo)
        // O CGWindowList usa origem no topo esquerdo da tela principal.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let windows = readWindows(primaryHeight: primaryHeight)
        let fullscreen = windows.first.map { front in
            screens.contains { s in abs(front.frame.width - s.frame.width) < 1 && abs(front.frame.height - s.frame.height) < 1
                && abs(front.frame.minX - s.frame.minX) < 1 && abs(front.frame.minY - s.frame.minY) < 1 }
        } ?? false
        return (WorldSnapshot(screens: screens, windows: windows), fullscreen)
    }

    private func screenInfo(_ s: NSScreen) -> ScreenInfo {
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let frame = Rect(s.frame)
        let visible = Rect(s.visibleFrame)
        var menuBar = s.frame.maxY - s.visibleFrame.maxY
        if menuBar < 1 { menuBar = NSStatusBar.system.thickness }

        var notch: Rect?
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            // A notch fica sempre centralizada; só a largura importa.
            let w = r.minX - l.maxX
            if w > 0 {
                let h = s.safeAreaInsets.top
                notch = Rect(x: frame.midX - w / 2, y: frame.maxY - h, width: w, height: h)
                menuBar = max(menuBar, h)
            }
        }
        return ScreenInfo(id: id, frame: frame, visibleFrame: visible, menuBarHeight: menuBar, notch: notch)
    }

    private func readWindows(primaryHeight: Double) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [WindowInfo] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.05 { continue }
            guard bounds.width >= minWindowSize.width, bounds.height >= minWindowSize.height else { continue }
            let frame = WorldCoordinates.fromCG(Rect(bounds), primaryHeight: primaryHeight)
            out.append(WindowInfo(id: number, pid: pid, frame: frame))
        }
        return out // já vem da frente para trás
    }
}
#endif
