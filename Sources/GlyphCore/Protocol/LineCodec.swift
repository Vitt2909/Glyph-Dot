import Foundation

/// JSON por linha: cada envelope é um objeto JSON sem quebras seguido de `\n`.
public struct LineCodec: Sendable {
    public init() {}

    public func encode(_ envelope: Envelope) throws -> Data {
        var data = try makeEncoder().encode(envelope)
        data.append(0x0A)
        return data
    }

    public func encodeString(_ envelope: Envelope) throws -> String {
        String(decoding: try encode(envelope), as: UTF8.self)
    }

    /// Decodifica uma linha (com ou sem `\n` final).
    public func decode(_ line: Data) throws -> Envelope {
        guard line.count <= GlyphProtocol.maxLineBytes else { throw ProtocolError.lineTooLong(line.count) }
        var trimmed = line
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        return try makeDecoder().decode(Envelope.self, from: trimmed)
    }

    public func decode(_ line: String) throws -> Envelope {
        try decode(Data(line.utf8))
    }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.format(date))
        }
        return e
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISO8601.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "data ISO 8601 inválida: \(s)")
            }
            return date
        }
        return d
    }
}

/// Datas ISO 8601 em UTC. Aceita frações de segundo na leitura.
public enum ISO8601 {
    public static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    public static func parse(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle()) { return d }
        return try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// Acumula bytes de um stream e devolve linhas completas.
public struct LineBuffer: Sendable {
    private var pending = Data()
    public let maxLineBytes: Int

    public init(maxLineBytes: Int = GlyphProtocol.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// Adiciona bytes e devolve as linhas completas (sem `\n`).
    /// Uma linha maior que o limite é descartada e reportada como erro.
    public mutating func append(_ data: Data) -> [Result<Data, ProtocolError>] {
        pending.append(data)
        var out: [Result<Data, ProtocolError>] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            pending = Data(pending[pending.index(after: nl)...])
            if line.count > maxLineBytes {
                out.append(.failure(.lineTooLong(line.count)))
            } else if !line.isEmpty {
                out.append(.success(Data(line)))
            }
        }
        if pending.count > maxLineBytes {
            out.append(.failure(.lineTooLong(pending.count)))
            pending.removeAll()
        }
        return out
    }
}
