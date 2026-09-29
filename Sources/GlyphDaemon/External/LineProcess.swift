import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Um processo filho que conversa por linhas no stdin/stdout (servidor MCP,
/// agente externo). Roda num grupo próprio: parar mata a árvore inteira.
/// O stderr vai para `/dev/null` (ou para um arquivo, se pedido): nada do que
/// o filho escreve ali chega ao modelo.
actor LineProcess {
    nonisolated let pid: pid_t
    private let stdinFD: Int32
    private var lines: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var waiterID = 0
    private var finished = false
    private var stopped = false
    private var pump: Task<Void, Never>?

    /// Uma linha maior que isto é descartada (proteção de memória).
    static let maxLine = 4 << 20

    private init(pid: pid_t, stdinFD: Int32) {
        self.pid = pid
        self.stdinFD = stdinFD
    }

    static func start(_ argv: [String], environment: [String: String], stderrPath: String? = nil) throws -> LineProcess {
        guard let exe = argv.first, !exe.isEmpty else { throw ToolError.badInput("comando vazio") }
        // Escrever num filho que morreu não pode derrubar o glyphd.
        signal(SIGPIPE, SIG_IGN)
        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0 else { throw ToolError.failed("pipe falhou") }
        guard pipe(&outPipe) == 0 else {
            _ = close(inPipe[0]); _ = close(inPipe[1])
            throw ToolError.failed("pipe falhou")
        }
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        if let stderrPath {
            posix_spawn_file_actions_addopen(&actions, 2, stderrPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        for fd in inPipe + outPipe { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        // Caminho relativo: procura no PATH do ambiente dado (via /usr/bin/env).
        let full = exe.hasPrefix("/") ? argv : ["/usr/bin/env"] + argv
        let env = environment.map { "\($0.key)=\($0.value)" }
        var pid = pid_t()
        let rc = withCStrings(full) { cargv in
            withCStrings(env) { cenv in posix_spawn(&pid, full[0], &actions, &attr, cargv, cenv) }
        }
        _ = close(inPipe[0])
        _ = close(outPipe[1])
        guard rc == 0 else {
            _ = close(inPipe[1]); _ = close(outPipe[0])
            throw ToolError.failed("não consegui iniciar \(exe): \(String(cString: strerror(rc)))")
        }
        let proc = LineProcess(pid: pid, stdinFD: inPipe[1])
        let stream = readLines(fd: outPipe[0])
        Task { await proc.startPump(stream) }
        return proc
    }

    private func startPump(_ stream: AsyncStream<String>) {
        pump = Task { [weak self] in
            for await line in stream { await self?.push(line) }
            await self?.finish()
        }
    }

    /// Lê o stdout numa thread própria (leitura bloqueante), linha por linha.
    private static func readLines(fd: Int32) -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                var skipping = false
                while true {
                    let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { break }
                    buffer.append(contentsOf: chunk[0..<n])
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<nl]
                        buffer = Data(buffer[(nl + 1)...])
                        if skipping { skipping = false; continue }
                        let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !line.isEmpty { continuation.yield(line) }
                    }
                    if buffer.count > maxLine {
                        buffer.removeAll()
                        skipping = true
                    }
                }
                _ = close(fd)
                continuation.finish()
            }
            thread.start()
        }
    }

    private func push(_ line: String) {
        if let w = waiter {
            waiter = nil
            w.resume(returning: line)
        } else {
            lines.append(line)
            if lines.count > 1000 { lines.removeFirst(lines.count - 1000) }
        }
    }

    private func finish() {
        finished = true
        if let w = waiter {
            waiter = nil
            w.resume(returning: nil)
        }
    }

    private func expire(_ id: Int) {
        guard id == waiterID, let w = waiter else { return }
        waiter = nil
        w.resume(returning: nil)
    }

    var isRunning: Bool { !finished && !stopped }

    /// A próxima linha, ou `nil` se o processo terminou ou o tempo acabou.
    func readLine(timeout: TimeInterval) async -> String? {
        if !lines.isEmpty { return lines.removeFirst() }
        if finished || stopped { return nil }
        waiterID += 1
        let id = waiterID
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            waiter = c
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1e9))
                await self?.expire(id)
            }
        }
    }

    func send(_ line: String) throws {
        guard !stopped, !finished else { throw ToolError.failed("processo encerrado") }
        let data = Array((line.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { write(stdinFD, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw ToolError.failed("o processo parou de ler") }
            offset += n
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        _ = close(stdinFD)
        kill(-pid, SIGTERM)
        for _ in 0..<20 {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        kill(-pid, SIGKILL)
        // Colhe o filho sem travar o actor (sem zumbi).
        let child = pid
        Thread {
            var status: Int32 = 0
            _ = waitpid(child, &status, 0)
        }.start()
        finish()
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        ptrs.append(nil)
        defer { for p in ptrs { free(p) } }
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
