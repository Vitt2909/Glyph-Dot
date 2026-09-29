import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Roda um processo num grupo próprio, para o timeout matar a árvore inteira
/// (o `sh -c "sleep 60"` e o `sleep` filho), não só o shell.
enum Spawn {
    struct Result: Sendable {
        var output: String
        var status: Int32
        var timedOut: Bool
    }

    static func run(_ argv: [String], environment: [String: String], timeout: TimeInterval,
                    maxBytes: Int = 1 << 20) async throws -> Result {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw ToolError.failed("pipe falhou") }
        let (readFD, writeFD) = (pipeFDs[0], pipeFDs[1])

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
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let env = environment.map { "\($0.key)=\($0.value)" }
        var pid = pid_t()
        let rc = withCStrings(argv) { cargv in
            withCStrings(env) { cenv in
                posix_spawn(&pid, argv[0], &actions, &attr, cargv, cenv)
            }
        }
        _ = close(writeFD)
        guard rc == 0 else {
            _ = close(readFD)
            throw ToolError.failed("não consegui iniciar \(argv[0]): \(String(cString: strerror(rc)))")
        }

        let flags = fcntl(readFD, F_GETFL, 0)
        _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var exited = false
        var timedOut = false

        func drain() {
            while true {
                let n = buf.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                if data.count < maxBytes { data.append(contentsOf: buf[0..<min(n, maxBytes - data.count)]) }
            }
        }

        while !exited {
            drain()
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { exited = true; break }
            if r < 0 { break }
            if Date() > deadline {
                timedOut = true
                kill(-pid, SIGTERM)
                try? await Task.sleep(nanoseconds: 300_000_000)
                kill(-pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
                exited = true
                break
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        drain()
        _ = close(readFD)
        // Mesmo depois do fim normal, filhos soltos no grupo morrem.
        kill(-pid, SIGKILL)

        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(output: String(decoding: data, as: UTF8.self), status: timedOut ? 124 : code, timedOut: timedOut)
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        ptrs.append(nil)
        defer { for p in ptrs { free(p) } }
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
