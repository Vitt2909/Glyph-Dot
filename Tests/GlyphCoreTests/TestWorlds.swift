import XCTest
@testable import GlyphCore

/// Mundos de teste. Tela 1440×900, Dock de 80 pt embaixo, barra de menu de 24.
enum TestWorlds {
    static let screen = ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, width: 1440, height: 900),
                                   visibleFrame: Rect(x: 0, y: 80, width: 1440, height: 796),
                                   menuBarHeight: 24)
    static let notched = ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982),
                                    visibleFrame: Rect(x: 0, y: 0, width: 1512, height: 944),
                                    menuBarHeight: 38, notch: Rect(x: 656, y: 944, width: 200, height: 38))

    static func win(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> WindowInfo {
        WindowInfo(id: id, pid: 100 + Int32(id), frame: Rect(x: x, y: y, width: w, height: h))
    }

    static func world(_ windows: [WindowInfo], screens: [ScreenInfo] = [screen]) -> World {
        World(WorldSnapshot(screens: screens, windows: windows))
    }
}

/// Roda a física por `seconds` com um controle fixo.
@discardableResult
func simulate(_ s: inout BodyState, in world: World, seconds: Double, control: Control = Control(),
              sim: PhysicsSimulator = PhysicsSimulator()) -> [PhysicsEvent] {
    var events: [PhysicsEvent] = []
    for _ in 0..<Int(seconds / sim.config.dt) { events += sim.step(&s, control, in: world) }
    return events
}

/// Planeja e segue um caminho até o fim. Devolve o estado final e se chegou.
func travel(_ s: inout BodyState, to goal: NavGoal, in world: World, maxSeconds: Double = 60,
            sim: PhysicsSimulator = PhysicsSimulator()) -> Bool {
    let graph = NavGraph(world: world, config: sim.config)
    // Assenta o corpo antes de planejar.
    while graph.segmentIndex(for: s) == nil, s.support == .air { _ = sim.step(&s, Control(), in: world) }
    guard let steps = graph.path(from: s, to: goal) else { return false }
    var follower = PathFollower(steps: steps)
    for _ in 0..<Int(maxSeconds / sim.config.dt) {
        let (c, status) = follower.control(for: s, world: world, config: sim.config)
        switch status {
        case .done: return true
        case .failed: return false
        case .running: _ = sim.step(&s, c, in: world)
        }
    }
    return false
}
