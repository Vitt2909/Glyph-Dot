import Foundation
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import GlyphCore

/// Erros de socket com o `errno` legível.
public struct SocketError: Error, CustomStringConvertible, Equatable {
    public var operation: String
    public var code: Int32

    public init(_ operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    public var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

/// Credenciais do processo do outro lado do socket.
public struct PeerCredentials: Sendable, Equatable {
    public var uid: UInt32
    public var pid: Int32?
    /// `audit_token_t` bruto (macOS), para conferir a assinatura do app.
    public var auditToken: [UInt8]?

    public init(uid: UInt32, pid: Int32? = nil, auditToken: [UInt8]? = nil) {
        self.uid = uid
        self.pid = pid
        self.auditToken = auditToken
    }
}

enum Posix {
    static var streamType: Int32 {
        #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError("caminho do socket longo demais", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    static func peerCredentials(_ fd: Int32) -> PeerCredentials? {
        #if canImport(Glibc)
        // `struct ucred` só aparece com _GNU_SOURCE; o layout é fixo: pid, uid, gid.
        struct UCred { var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0 }
        var cred = UCred()
        var len = socklen_t(MemoryLayout<UCred>.size)
        let soPeerCred: Int32 = 17 // SO_PEERCRED
        guard getsockopt(fd, SOL_SOCKET, soPeerCred, &cred, &len) == 0 else { return nil }
        return PeerCredentials(uid: cred.uid, pid: cred.pid)
        #else
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        var pid = pid_t()
        var plen = socklen_t(MemoryLayout<pid_t>.size)
        // SOL_LOCAL = 0, LOCAL_PEERPID = 2, LOCAL_PEERTOKEN = 6 (sys/un.h)
        let hasPID = getsockopt(fd, 0, 2, &pid, &plen) == 0
        var token = [UInt8](repeating: 0, count: 32)
        var tlen = socklen_t(32)
        let hasToken = token.withUnsafeMutableBytes { getsockopt(fd, 0, 6, $0.baseAddress, &tlen) } == 0
        return PeerCredentials(uid: uid, pid: hasPID ? pid : nil, auditToken: hasToken ? token : nil)
        #endif
    }

    static func closeFD(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }

    static func connectFD(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        #if canImport(Glibc)
        return Glibc.connect(fd, addr, len)
        #else
        return Darwin.connect(fd, addr, len)
        #endif
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func setNoSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func write(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                #if canImport(Glibc)
                return Glibc.send(fd, raw.baseAddress! + offset, data.count - offset, Int32(MSG_NOSIGNAL))
                #else
                return Darwin.send(fd, raw.baseAddress! + offset, data.count - offset, 0)
                #endif
            }
            if n > 0 { offset += n; continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                usleep(1000)
                continue
            }
            return false
        }
        return true
    }
}

/// Uma conexão com framing de JSON por linha.
///
/// `@unchecked Sendable`: todo o estado mutável é acessado só na fila serial
/// `queue` (leitura pelo `DispatchSource`, escrita e fechamento via `queue.async`).
public final class LineConnection: @unchecked Sendable {
    public let peer: PeerCredentials?
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = LineBuffer()
    private var closed = false
    private let codec = LineCodec()

    /// Chamado na fila da conexão para cada linha (ou erro de framing).
    public var onLine: (@Sendable (Result<Envelope, Error>) -> Void)?
    public var onClose: (@Sendable () -> Void)?
    /// Se definido, recebe as linhas cruas (sem decodificar como `Envelope`).
    public var onRawLine: (@Sendable (Data) -> Void)?

    init(fd: Int32, peer: PeerCredentials?, label: String) {
        self.fd = fd
        self.peer = peer
        self.queue = DispatchQueue(label: "glyph.ipc.\(label)")
        Posix.setNonBlocking(fd)
        Posix.setNoSigPipe(fd)
    }

    public func start() {
        queue.async { [self] in
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            // A conexão se mantém viva enquanto o socket estiver aberto; o ciclo
            // é desfeito em `closeNow()`.
            src.setEventHandler { self.readAvailable() }
            src.setCancelHandler { [fd] in Posix.closeFD(fd) }
            source = src
            src.resume()
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 {
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            closeNow()
            return
        }
        for line in buffer.append(Data(chunk[0..<n])) {
            switch line {
            case let .success(data):
                if let raw = onRawLine { raw(data); continue }
                onLine?(Result { try codec.decode(data) })
            case let .failure(e):
                onLine?(.failure(e))
            }
        }
    }

    public func send(_ envelope: Envelope) {
        guard let data = try? codec.encode(envelope) else { return }
        queue.async { [self] in
            guard !closed else { return }
            if !Posix.write(fd, data) { closeNow() }
        }
    }

    public func close() {
        queue.async { [self] in closeNow() }
    }

    /// Bytes crus (para testes de robustez do framing).
    func sendRaw(_ data: Data) {
        queue.async { [self] in _ = Posix.write(fd, data) }
    }

    private func closeNow() {
        guard !closed else { return }
        closed = true
        source?.setEventHandler(handler: nil)
        source?.cancel()
        source = nil
        onClose?()
        onLine = nil
        onClose = nil
        onRawLine = nil
    }
}

/// Servidor em socket Unix. O arquivo do socket fica com permissão 0600.
public final class UnixSocketServer: @unchecked Sendable {
    public let path: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "glyph.ipc.accept")
    private var source: DispatchSourceRead?
    private var counter = 0

    /// Nova conexão aceita (já com as credenciais do par).
    public var onConnection: (@Sendable (LineConnection) -> Void)?

    public init(path: String) {
        self.path = path
    }

    public func start() throws {
        // Remove um socket velho de uma execução anterior.
        unlink(path)
        fd = socket(AF_UNIX, Posix.streamType, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        var addr = try Posix.makeAddress(path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let old = umask(0o177)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        umask(old)
        guard ok == 0 else { let e = SocketError("bind \(path)"); Posix.closeFD(fd); throw e }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw SocketError("listen") }
        Posix.setNonBlocking(fd)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        source = src
        src.resume()
    }

    private func acceptPending() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            counter += 1
            let conn = LineConnection(fd: client, peer: Posix.peerCredentials(client), label: "c\(counter)")
            onConnection?(conn)
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { Posix.closeFD(fd) }
        fd = -1
        unlink(path)
    }
}

public enum UnixSocketClient {
    /// Conecta ao socket. A conexão começa parada: configure `onLine` e chame `start()`.
    public static func connect(path: String) throws -> LineConnection {
        let fd = socket(AF_UNIX, Posix.streamType, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        var addr = try Posix.makeAddress(path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Posix.connectFD(fd, $0, size) }
        }
        guard ok == 0 else { let e = SocketError("connect \(path)"); Posix.closeFD(fd); throw e }
        return LineConnection(fd: fd, peer: Posix.peerCredentials(fd), label: "client")
    }
}

/// UID efetivo do processo atual.
public var currentUID: UInt32 { UInt32(geteuid()) }
