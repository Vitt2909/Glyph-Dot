import Foundation
import GlyphCore
import GlyphDaemon

// glyphd — o cérebro do Glyph.
//
// No M0 só existem os modos de inspeção. O loop de autonomia, o socket e o
// LaunchAgent chegam no M2 (docs/ARCHITECTURE.md).

let usage = """
uso: glyphd <comando>

comandos:
  version          mostra a versão
  paths            mostra onde fica a casa
  mock [--fast] [--loop]
                   imprime o roteiro do cérebro falso (JSON por linha)
  validate         lê JSON por linha da entrada e valida como mensagens do cérebro
"""

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch command {
case "version", "--version", "-v":
    print("glyphd \(GlyphInfo.version) (protocolo v\(GlyphProtocol.version))")

case "paths":
    let p = GlyphPaths.standard()
    print("suporte: \(p.support.path)")
    print("socket:  \(p.socket.path)")
    print("casa:    \(p.casa.path)")

case "mock":
    do {
        if args.contains("--fast") {
            for line in try MockStream().allLines() { print(line, terminator: "") }
        } else {
            try MockStream(loops: args.contains("--loop")).run { FileHandle.standardOutput.write(Data($0.utf8)) }
        }
    } catch {
        fail("erro: \(error)")
    }

case "validate":
    let codec = LineCodec()
    var failures = 0
    var lineNo = 0
    while let line = readLine() {
        lineNo += 1
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        do {
            let env = try codec.decode(line)
            let sender: Peer = Message.Kind(rawValue: env.type)?.allowedSenders.contains(.brain) == true ? .brain : .body
            try ProtocolValidator.validate(env, from: sender)
            print("ok \(lineNo): \(env.type)")
        } catch {
            failures += 1
            print("ERRO \(lineNo): \(error)")
        }
    }
    exit(failures == 0 ? 0 : 1)

case "help", "--help", "-h":
    print(usage)

default:
    fail("comando desconhecido: \(command)\n\n\(usage)")
}
