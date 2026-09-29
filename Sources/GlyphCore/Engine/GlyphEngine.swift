import Foundation

/// O que o motor pede ao corpo (além de desenhar).
public enum EngineEvent: Sendable, Equatable {
    /// Mandar ao cérebro.
    case send(Message)
    /// Duplo clique: abrir a casa (o único painel tradicional).
    case openHome
    /// Clique no Glyph segurando o diário: abrir o arquivo.
    case openFile(String)
}

/// O motor da criatura: junta mundo, física, navegação, comportamento e
/// animação. Roda inteiro no Core, sem AppKit, e é determinístico dado o
/// mesmo `seed` e as mesmas entradas.
///
/// O corpo macOS só alimenta o motor (mundo, cursor, mouse, mensagens do
/// cérebro), chama `advance(by:)` a cada quadro e desenha `drawing`.
public struct GlyphEngine: Sendable {
    public struct Config: Sendable {
        public var physics = PhysicsConfig()
        public var style = StickerStyle.default
        public var seed: UInt64 = 0x6C79_7068
        /// Com que frequência a intenção é reavaliada.
        public var thinkInterval = 0.25
        public init() {}
    }

    // Entradas e dependências
    public let config: Config
    public let clips: ClipLibrary
    public let stickers: [String: Sticker]
    private var held: (sticker: Sticker, until: Double)?
    private let sim: PhysicsSimulator
    private let metrics = SkeletonMetrics()
    private let dotAnimator = DotAnimator()
    private var rng: SplitMix64

    // Mundo
    public private(set) var world: World
    private var graph: NavGraph?

    // Corpo
    public private(set) var body: BodyState
    public private(set) var locomotion: Locomotion = .fall
    public private(set) var time = 0.0
    private var accumulator = 0.0

    // Cabeça (comportamento)
    public var needs = Needs()
    private var picker = UtilityPicker()
    public var intent: BodyIntent { picker.current }
    private var nextThink = 0.0
    private var idleSince = 0.0

    // Navegação
    private var goal: NavGoal?
    private var follower: PathFollower?
    private var replanAt = 0.0
    private var pendingJump: (control: Control, at: Double)?
    private var failures = 0

    // Cursor e mouse
    private var cursor = CursorTracker()
    private var reactor = CursorReactor()
    private var cursorReaction: CursorReaction = .none
    private var press: (point: Vec2, time: Double, offset: Vec2)?
    private var lastClick = -10.0
    private var justDropped = false

    // Pedidos do cérebro
    private var brainTarget: (goal: NavGoal, point: Vec2, until: Double)?
    private var brainDot: (mode: DotMode, speed: Double, since: Double, until: Double)?
    private var approval: (why: String, until: Double)?
    private var budgetDots = 0
    private var pendingDiary: String?
    private var fullscreen = false

    // Animação
    private var baseClip = "idle"
    private var baseClipStart = 0.0
    private var oneShot: (id: String, start: Double)?
    private var spring = SquashSpring()
    private var landedAt = -10.0
    private var poseFrame = -1
    private var cachedPose = Pose.rest
    private var headAngle = 0.0
    private var lookTarget: Vec2?
    private var dotModeSince = 0.0
    private var lastDotMode: DotMode = .steady
    private var lastBounds: Rect?
    private var bubble: (text: String, until: Double)?
    private var sleepStart: Double?
    private var homeState: HomeState = .outside

    enum HomeState: Equatable {
        case outside
        case entering(since: Double)
        case inside
        case leaving(since: Double)
    }

    private var events: [EngineEvent] = []

    public init(world snapshot: WorldSnapshot, clips: ClipLibrary, stickers: [String: Sticker] = [:],
                config: Config = Config(), start: Vec2? = nil) {
        self.config = config
        self.clips = clips
        self.stickers = stickers
        self.sim = PhysicsSimulator(config: config.physics, metrics: BodyMetrics())
        self.rng = SplitMix64(seed: config.seed)
        self.world = World(snapshot)
        let screen = snapshot.screens.first
        let p = start ?? Vec2(screen?.frame.midX ?? 200, (screen?.floorY ?? 0) + 120)
        self.body = BodyState(position: p)
    }

    // MARK: - Entradas

    public mutating func setWorld(_ snapshot: WorldSnapshot) {
        guard snapshot != world.snapshot else { return }
        let diff = WorldDiff.between(world.snapshot, snapshot)
        let before = body
        sim.apply(diff, to: &body)
        world = World(snapshot)
        // A própria janela cresceu por cima dele (maximizar): ele não é
        // levado junto para o topo novo. Fica onde está, "engolido", e foge.
        if case let .ground(.window(id)) = before.support, diff.changed[id] != nil,
           world.segment(.window(id), x: body.position.x, nearY: body.position.y) == nil,
           let f = world.frames[id], f.insetBy(dx: 1, dy: 1).contains(before.position) {
            body.position = before.position
        }
        graph = nil
        if follower != nil { replanAt = time }
        if !diff.added.isEmpty || !diff.removed.isEmpty { needs.noticeEvent(novelty: 0.05) }
        if case let .ground(.window(id)) = body.support, diff.removed.contains(id) {
            // A plataforma sumiu: ele vai cair. Olha para cima, surpreso.
            lookTarget = body.position + Vec2(0, 200)
        }
    }

    public mutating func setCursor(_ p: Vec2) {
        cursor.add(p, at: time)
        if press != nil, body.support == .carried, let pr = press {
            body.position = p + pr.offset
        }
    }

    public mutating func setFullscreen(_ on: Bool) {
        fullscreen = on
    }

    public mutating func mouseDown(at p: Vec2) {
        guard let b = hitbox, b.contains(p) else { return }
        press = (p, time, body.position - p)
    }

    public mutating func mouseDragged(to p: Vec2) {
        setCursor(p)
        guard let pr = press else { return }
        if body.support != .carried, p.distance(to: pr.point) > 4 {
            body.support = .carried
            body.velocity = .zero
            follower = nil
            oneShot = nil
            sleepStart = nil
        }
        if body.support == .carried { body.position = p + pr.offset }
    }

    public mutating func mouseUp(at p: Vec2) {
        guard press != nil else { return }
        press = nil
        if body.support == .carried {
            sim.release(&body, throwVelocity: cursor.velocity)
            justDropped = true
            return
        }
        if time - lastClick < 0.35 {
            events.append(.openHome)
            lastClick = -10
            return
        }
        lastClick = time
        click()
    }

    private mutating func click() {
        if let diary = pendingDiary {
            pendingDiary = nil
            held = nil
            events.append(.openFile(diary))
            return
        }
        if case .sleep = intent {
            // Acorda.
            needs.energy = max(needs.energy, 0.5)
            picker.force(.idle)
            sleepStart = nil
            oneShot = ("stand-up", time)
        }
        say(statusLine)
        events.append(.send(.inputSummon(InputSummon(source: .click))))
    }

    private var statusLine: String {
        if let a = approval { return a.why }
        switch intent {
        case .sleep: return "zzz… oi."
        case .work: return "trabalhando."
        case .flee: return "opa!"
        case .observe: return "olhando."
        case .wander: return "passeando."
        case .home: return "indo pra casa."
        default: return needs.energy < 0.25 ? "com sono." : "oi."
        }
    }

    /// Mensagem já validada vinda do cérebro.
    public mutating func receive(_ message: Message) {
        switch message {
        case let .bubbleSay(b):
            say(b.displayText, duration: b.durationSec)
        case let .bodyEmote(e):
            if clips[e.clip] != nil { oneShot = (e.clip, time) }
            if let mode = e.dot ?? clips[e.clip]?.dot?.mode {
                brainDot = (mode, clips[e.clip]?.dot?.speed ?? 1, time, time + 8)
            }
            if let id = e.sticker, let s = stickers[id] { held = (s, time + 4) }
        case let .bodyGoto(g):
            switch g.target {
            case .home:
                if let s = world.screen(containing: body.position) {
                    // Fica em casa até outro pedido ou até ser chamado.
                    brainTarget = (.home(screen: s.id), s.home.center, time + 600)
                }
            case let .point(p):
                brainTarget = (.point(p), p, time + 30)
            case let .window(_, frame):
                let p = Vec2(frame.midX, frame.maxY)
                brainTarget = (.point(p), p, time + 30)
            }
        case let .approvalRequest(r):
            approval = (BubbleSay(text: r.why).displayText, time + r.timeoutSec)
            say(BubbleSay(text: r.why).displayText, duration: min(r.timeoutSec, 30))
        case let .taskUpdate(t):
            budgetDots = min(t.budgetRemaining ?? 0, 12)
        case let .diaryReady(d):
            // Volta de manhã segurando o diário; clicar abre.
            pendingDiary = d.path
            if let s = stickers["diario"] { held = (s, time + 12 * 3600) }
            say("diário pronto.", duration: 6)
        case .agentSpawn, .agentDespawn, .hello,
             .worldUpdate, .inputSummon, .inputBrake, .approvalResponse:
            break
        }
    }

    /// O usuário respondeu a um pedido (o corpo manda `approval.response`).
    public mutating func approvalAnswered() {
        approval = nil
        bubble = nil
    }

    public mutating func drainEvents() -> [EngineEvent] {
        defer { events.removeAll() }
        return events
    }

    private mutating func say(_ text: String, duration: Double = BubbleSay.defaultDuration) {
        bubble = (BubbleSay(text: text).displayText, time + duration)
    }

    // MARK: - Tempo

    /// Avança o tempo; a física roda em passos fixos de `config.physics.dt`.
    public mutating func advance(by dt: Double) {
        accumulator += min(max(dt, 0), 0.25)
        let step = config.physics.dt
        while accumulator >= step {
            accumulator -= step
            tick(step)
        }
    }

    private mutating func tick(_ dt: Double) {
        time += dt
        if let b = bubble, time > b.until { bubble = nil }
        if let a = approval, time > a.until { approval = nil } // sem resposta: o cérebro nega
        if let t = brainTarget, time > t.until { brainTarget = nil }
        if let d = brainDot, time > d.until { brainDot = nil }
        if let h = held, time > h.until { held = nil }

        let moving = abs(body.velocity.x) > 5 || !body.support.isGrounded
        let near = cursor.position.map { $0.distance(to: body.position) < 200 } ?? false
        needs.update(dt: dt, moving: moving, sleeping: intent == .sleep && sleepStart != nil, cursorNear: near)
        spring.step(dt)

        if time >= nextThink {
            nextThink = time + config.thinkInterval
            think()
        }
        if let bounds = lastBounds {
            cursorReaction = reactor.react(cursor: cursor, body: body.position + Vec2(0, metrics.height / 2),
                                           hitbox: bounds, time: time)
            switch cursorReaction {
            case .wave where oneShot == nil && intent != .sleep:
                oneShot = ("wave", time)
            case .recoil where oneShot == nil && body.support.isGrounded && intent != .sleep:
                oneShot = ("recoil", time)
            default: break
            }
        }

        updateHome()

        // Antecipação: agacha 0,1 s antes de pular. Enquanto isso o seguidor
        // de caminho não é consultado (senão veria "pulou e continua no chão").
        var control: Control
        if let pj = pendingJump {
            if time >= pj.at {
                control = pj.control
                pendingJump = nil
                spring.kick(2.2)
            } else {
                control = Control()
            }
        } else {
            control = drive()
            if control.jump != nil, body.support.isGrounded {
                pendingJump = (control, time + 0.1)
                spring.set(0.85)
                control = Control()
            }
        }

        let evs = sim.step(&body, control, in: world)
        for e in evs {
            switch e {
            case let .landed(impact, _):
                if impact > 150 {
                    spring.kick(-min(impact, 1400) * 0.0035)
                    landedAt = time
                }
                if justDropped {
                    justDropped = false
                    oneShot = ("stand-up", time)
                    lookTarget = cursor.position
                }
            case .lostSupport:
                replanAt = time
            default: break
            }
        }
        updateLocomotion(control)
    }

    // MARK: - Comportamento

    private mutating func think() {
        var options: [UtilityPicker.Option] = [
            .init(.idle, 0.3),
        ]
        if body.coveredBy != nil { options.append(.init(.flee, 1.0, forced: true)) }
        if fullscreen { options.append(.init(.home, 0.99, forced: true)) }
        if let t = brainTarget {
            if case .home = t.goal {
                options.append(.init(.home, 0.95, forced: true))
            } else {
                options.append(.init(.approach(t.point), 0.9, forced: true))
            }
        }
        if approval != nil { options.append(.init(.awaitApproval, 0.92, forced: true)) }

        let tired = pow(1 - needs.energy, 2) * 1.3
        if intent == .sleep {
            options.append(.init(.sleep, needs.energy < 0.9 ? 0.8 : 0.1))
        } else if tired > 0.3 {
            options.append(.init(.sleep, tired))
        }

        if let p = cursor.position, p.distance(to: body.position) < 400 {
            options.append(.init(.observe(p), 0.15 + needs.sociability * 0.6))
        }
        let boredom = min((time - idleSince) / 40, 0.4) * needs.energy
        if case let .wander(x) = intent {
            options.append(.init(.wander(to: x), 0.45))
        } else {
            options.append(.init(.wander(to: 0), 0.15 + boredom + needs.curiosity * 0.2))
        }

        let before = intent
        let (now, changed) = picker.pick(options, dt: config.thinkInterval)
        if changed { begin(now, from: before) }

        // Não dá para dormir pendurado.
        if case .ceiling = body.support, homeState == .outside, intent == .idle || intent == .sleep {
            picker.force(.wander(to: 0))
            begin(intent, from: before)
        }
    }

    private mutating func begin(_ now: BodyIntent, from before: BodyIntent) {
        if case .sleep = before, sleepStart != nil {
            sleepStart = nil
            oneShot = ("stand-up", time)
        }
        switch now {
        case .idle, .observe, .awaitApproval, .sleep:
            idleSince = time
            setGoal(nil)
        case .wander:
            let x = pickWanderPoint()
            picker.force(.wander(to: x.x))
            setGoal(.point(x))
        case let .approach(p), let .work(p):
            setGoal(.point(p))
        case .home:
            if let s = world.screen(containing: body.position) { setGoal(.home(screen: s.id)) }
        case .flee:
            setGoal(nil)
        }
        if now == .sleep {
            sleepStart = nil // começa quando ele parar
        }
    }

    private mutating func pickWanderPoint() -> Vec2 {
        let segs = world.standable.filter { $0.length > 60 }
        guard !segs.isEmpty else { return body.position }
        let total = segs.reduce(0) { $0 + $1.length }
        var r = rng.nextUnit() * total
        for s in segs {
            if r <= s.length { return Vec2(s.clampX(s.x0 + r, inset: 20), s.y) }
            r -= s.length
        }
        return Vec2(segs[0].midX, segs[0].y)
    }

    private mutating func setGoal(_ g: NavGoal?) {
        goal = g
        failures = 0
        follower = nil
        replanAt = time
    }

    /// Decide o controle deste passo.
    private mutating func drive() -> Control {
        if body.support == .carried || homeState == .inside { return Control() }
        if case .entering = homeState { return Control() }

        // Fuga tem prioridade sobre qualquer caminho.
        if let coverID = body.coveredBy, case let .ground(kind) = body.support,
           let id = kind.windowID, let cover = world.frames[coverID] {
            var c = Control()
            let half = metrics.width / 2
            var options = [cover.minX - half - 2, cover.maxX + half + 2]
            if let raw = world.rawTops[id], coverID != id { options += [raw.x0 - 4, raw.x1 + 4] }
            let target = options.min { abs($0 - body.position.x) < abs($1 - body.position.x) }!
            c.moveX = target < body.position.x ? -1 : 1
            c.flee = true
            return c
        }

        guard let goal else {
            if case .wall = body.support { var c = Control(); c.release = true; return c }
            return Control()
        }

        if follower == nil || time >= replanAt {
            guard body.support.isGrounded || isHanging else { return airControl() }
            if graph == nil { graph = NavGraph(world: world, config: config.physics) }
            if let steps = graph!.path(from: body, to: goal) {
                follower = PathFollower(steps: steps)
                replanAt = .infinity
            } else {
                // Sem caminho: desiste e fica por aqui.
                self.goal = nil
                follower = nil
                if brainTarget != nil { brainTarget = nil; say("hm.") }
                return Control()
            }
        }
        guard var f = follower else { return Control() }
        let (c, status) = f.control(for: body, world: world, config: config.physics)
        follower = f
        switch status {
        case .running:
            return c
        case .done:
            arrived()
            return Control()
        case .failed:
            follower = nil
            failures += 1
            if failures >= 4 {
                // Tentou e não deu: desiste em vez de ficar pulando para sempre.
                failures = 0
                self.goal = nil
                if brainTarget != nil { brainTarget = nil; say("hm.") }
                picker.force(.idle)
                return Control()
            }
            replanAt = time + 0.2
            return Control()
        }
    }

    private var isHanging: Bool {
        if case .ceiling = body.support { return true }
        return false
    }

    private func airControl() -> Control { Control() }

    private mutating func arrived() {
        follower = nil
        failures = 0
        let g = goal
        goal = nil
        switch intent {
        case .wander:
            idleSince = time
            picker.force(.idle)
        case let .approach(p):
            lookTarget = p
            brainTarget = nil
            picker.force(.idle)
        case .home:
            if case .home = g { homeState = .entering(since: time) }
        default:
            break
        }
    }

    private mutating func updateHome() {
        switch homeState {
        case .outside:
            break
        case let .entering(since):
            if time - since > 0.45 { homeState = .inside }
        case .inside:
            if intent != .home { homeState = .leaving(since: time) }
        case let .leaving(since):
            if time - since > 0.45 { homeState = .outside }
        }
    }

    // MARK: - Animação

    private mutating func updateLocomotion(_ c: Control) {
        let new: Locomotion
        switch body.support {
        case .carried: new = .carried
        case .wall: new = .climb
        case .ceiling: new = .hang
        case .air: new = body.velocity.y > 0 ? .jump : .fall
        case .ground:
            if time - landedAt < 0.3 { new = .land }
            else if abs(body.velocity.x) < 5 { new = .stand }
            else if abs(body.velocity.x) <= config.physics.walkSpeed + 10 { new = .walk }
            else { new = .run }
        }
        if new != locomotion {
            locomotion = new
            if new != .stand { oneShot = oneShot.flatMap { $0.id == "stand-up" ? $0 : nil } }
        }
        if new == .stand, case .sleep = intent, sleepStart == nil, oneShot == nil {
            sleepStart = time
        }
    }

    private func clipFor(_ loco: Locomotion) -> String {
        if pendingJump != nil { return "crouch" }
        switch loco {
        case .walk: return "walk"
        case .run: return "run"
        case .jump: return "jump"
        case .fall: return "fall"
        case .land: return "land"
        case .climb: return "climb"
        case .hang: return abs(body.velocity.x) > 1 ? "hang-move" : "hang"
        case .carried: return "carried"
        case .stand:
            if let s = sleepStart {
                let t = time - s
                return t < 1.6 ? "yawn" : (t < 2.1 ? "sit" : "sleep")
            }
            if approval != nil { return "await" }
            if case .observe = intent { return "look" }
            return "idle"
        }
    }

    /// Modo do Dot agora.
    private var dotMode: (DotMode, Double) {
        if let d = brainDot { return (d.mode, d.speed) }
        if body.coveredBy != nil { return (.alert, 1) }
        if approval != nil { return (.blink, 1) }
        if sleepStart != nil { return (.fade, 1) }
        if let t = brainTarget, case .point = t.goal { return (.trail, 1) }
        if case .observe = intent { return (.glance, 1) }
        return (.steady, 1)
    }

    /// Quadros por segundo que o corpo deve pedir ao display link.
    /// Parado, a pose muda a 12 fps; dormindo, menos; em casa, nada.
    public var desiredFPS: Double {
        if homeState == .inside { return 0 }
        if sleepStart != nil { return 6 }
        if locomotion != .stand || oneShot != nil || pendingJump != nil || homeState != .outside || abs(spring.value - 1) > 0.01 {
            return 60
        }
        return config.style.poseFPS
    }

    public var isHidden: Bool { homeState == .inside }

    /// Caixa do último quadro desenhado, em coordenadas globais.
    public var hitbox: Rect? { homeState == .inside ? nil : lastBounds }

    /// O quadro atual, ou `nil` se ele estiver dentro de casa.
    public var drawing: GlyphDrawing? {
        mutating get { makeDrawing() }
    }

    private mutating func makeDrawing() -> GlyphDrawing? {
        if homeState == .inside {
            lastBounds = nil
            return nil
        }

        // Clipe base e clipe de uma vez só.
        let base = clipFor(locomotion)
        if base != baseClip {
            baseClip = base
            baseClipStart = time
        }
        if let o = oneShot, let c = clips[o.id], !c.loops, time - o.start > c.duration + 0.05 { oneShot = nil }
        if let o = oneShot, clips[o.id]?.loops == true, time - o.start > 3 { oneShot = nil }

        // Pose "em dois": só recalcula quando muda o quadro de 12 fps.
        let frame = Int(time * config.style.poseFPS)
        if frame != poseFrame {
            poseFrame = frame
            var pose: Pose
            if let o = oneShot, let c = clips[o.id], locomotion == .stand || locomotion == .land {
                pose = c.sample(at: time - o.start)
            } else {
                pose = clips[baseClip]?.sample(at: time - baseClipStart) ?? .rest
            }
            if locomotion == .stand && sleepStart == nil { pose = pose.adding(Procedural.breath(time: time)) }
            cachedPose = pose
        }

        var pose = cachedPose
        pose[.stretch] = pose[.stretch] * spring.value

        // Olhar: a cabeça segue antes do corpo.
        var look: Vec2? = lookTarget
        if case let .look(p) = cursorReaction { look = p }
        if case let .observe(p) = intent { look = p }
        if case let .approach(p) = intent, follower == nil { look = p }
        var facing = body.facing
        if let l = look, locomotion == .stand {
            let dir = l - (body.position + Vec2(0, metrics.height))
            if abs(dir.x) > 20 { facing = dir.x > 0 ? 1 : -1 }
            let want = Procedural.lookAngle(toward: dir, facing: facing)
            headAngle += (want - headAngle) * 0.35
        } else {
            headAngle *= 0.7
        }
        pose[.head] = pose[.head] + headAngle
        if locomotion == .stand, abs(body.velocity.x) < 1 { body.facing = facing }

        let sk = ForwardKinematics.solve(pose, metrics: metrics, facing: facing)

        // Dot.
        let (mode, speed) = dotMode
        if mode != lastDotMode {
            lastDotMode = mode
            dotModeSince = time
        }
        var target: Vec2?
        if let t = brainTarget?.point { target = t - body.position }
        else if let l = look { target = l - body.position }
        let planned = follower.map { $0.steps.count } ?? 4
        let dot = dotAnimator.draw(mode: mode, speed: speed, time: time, since: time - dotModeSince,
                                   head: sk.headCenter, target: target, planned: planned)

        // Olhos só quando expressam.
        var eyes: EyesDrawing?
        let expressive = look != nil || approval != nil || oneShot?.id == "error" || body.coveredBy != nil
        if expressive, sleepStart == nil, locomotion != .carried {
            var lookDir = Vec2.zero
            if let l = look {
                let d = (l - (body.position + sk.headCenter)).normalized
                lookDir = Vec2(d.x * facing, d.y)
            }
            let style: EyesDrawing.Style = oneShot?.id == "error" ? .squint : (isBlinking ? .blink : .open)
            eyes = EyesDrawing(look: lookDir, style: style)
        }

        var opacity = 1.0
        switch homeState {
        case let .entering(since): opacity = max(0, 1 - (time - since) / 0.45)
        case let .leaving(since): opacity = min(1, (time - since) / 0.45)
        default: break
        }
        if sleepStart != nil { opacity = 0.85 }

        var holding = held?.sticker
        if approval != nil, locomotion == .stand { holding = stickers["cartao"] ?? holding }
        let d = GlyphDrawing(position: body.position, skeleton: sk, dot: dot, eyes: eyes,
                             boilFrame: Int(time * 24), bubble: bubble?.text, budgetDots: budgetDots,
                             opacity: opacity, held: holding)
        lastBounds = d.bounds
        return d
    }

    private var isBlinking: Bool {
        // Pisca por 0,12 s a cada ~4 s, de forma determinística.
        let period = 4.0
        return time.truncatingRemainder(dividingBy: period) > period - 0.12
    }
}
