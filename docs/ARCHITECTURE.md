# Arquitetura

O Glyph é dividido em três peças.

| Peça | O que é | Regra |
|---|---|---|
| **Corpo** (`Glyph.app`) | Overlay transparente que desenha a criatura, lê o "mundo" (janelas, Dock, notch) e o cursor | **Nunca executa nada.** Só desenha e repassa percepções |
| **Cérebro** (`glyphd`) | Daemon com o loop de autonomia, ferramentas, memória e política | Único processo que age, sempre via política |
| **Protocolo** | JSON por linha num socket local (docs/PROTOCOL.md) | Qualquer agente pode ser o cérebro |

```
┌──────────────────────────── Glyph.app (corpo) ────────────────────────────┐
│  Overlay (NSPanel por tela)  │  World Model  │  Física  │  Renderer sticker │
│  Cursor/Input                │  (plataformas)│  (Core)  │  (Core Animation) │
└───────────────▲───────────────────────────────────────────────┬───────────┘
                │ body.* / bubble.* / approval.request          │ world.* / input.* / approval.response
                │                                               ▼
┌─────────────────────────────── glyphd (cérebro) ──────────────────────────┐
│ Sensores → Intenções → Pontuação → Política/Confiança → Executor → Histórico│
└───────────────────────────────────────────────────────────────────────────┘
```

- O `glyphd` funciona sem o corpo (modo headless).
- O corpo funciona sem o `glyphd` (modo mock, `GLYPH_MOCK=1`, ou criatura "muda").

## Pacotes (SwiftPM, Swift 6, macOS 14+)

| Alvo | Plataforma | Dependências | Conteúdo |
|---|---|---|---|
| `GlyphCore` | macOS + **Linux** | Foundation | Protocolo, geometria, física, pathfinding, comportamento, animação (pose, clipe, esqueleto, line boil), motor da criatura |
| `GlyphIPC` | macOS + Linux | Core | Socket Unix de linhas, credenciais do par, assinatura do corpo |
| `GlyphDaemon` | macOS + Linux | Core, IPC | Cérebros (inclusive agente externo), ferramentas (inclusive MCP), política, autonomia, objetivos, time, mala |
| `glyphd` | macOS + Linux | Core, Daemon | Executável do cérebro |
| `GlyphBody` | macOS | Core, AppKit, QuartzCore | Overlay, leitura do mundo, renderer, input, casa |
| `GlyphApp` (produto `Glyph`) | macOS | Body | `main.swift` do app |

Os alvos macOS só são declarados no `Package.swift` quando `os(macOS)`, então
`swift build` e `swift test` funcionam em Linux sem nenhum `#if` espalhado.

O app é montado por `Scripts/bundle-app.sh` a partir do executável do
SwiftPM, com `Apps/Glyph/Info.plist` e `Apps/Glyph/Glyph.entitlements`. Não há
projeto Xcode (ADR 0002).

## Onde fica cada decisão

A regra de ouro: **se dá para testar em Linux, mora no Core**. O corpo macOS é
fino: lê o mundo, entrega ao Core, recebe um `GlyphDrawing` e converte em
`CAShapeLayer`s.

```
NSScreen / CGWindowList / NSEvent        (GlyphBody, macOS)
            │  WorldSnapshot, CursorSample
            ▼
      GlyphEngine.step(dt)               (GlyphCore, testado em Linux)
   World → Física → Navegação → Comportamento → Animação
            │  GlyphDrawing
            ▼
   StickerShapes → CAShapeLayer          (GlyphBody)
```

## Coordenadas

Todo o Core usa o sistema global do AppKit: origem no canto inferior
esquerdo da tela principal, y para cima. O `CGWindowList` usa origem no topo
esquerdo; a conversão acontece num único lugar, `WorldCoordinates`.

## A casa

```
~/Library/Application Support/Glyph/
├── glyphd.sock
└── casa/
    ├── memoria/          # fatos em .md, um arquivo por assunto
    ├── skills/           # skills ativas + _rascunhos/
    ├── diario/           # AAAA-MM-DD.md
    ├── journal/          # checkpoints para desfazer
    ├── glyph.sqlite      # tarefas, intenções, histórico, confiança
    ├── packs/            # packs da comunidade (docs/PACKS.md)
    ├── worktrees/        # uma pasta por tarefa, ramo glyph/*
    ├── config.yaml
    ├── goals.yaml
    ├── policy.yaml
    ├── confianca.json
    ├── historico.jsonl
    └── quadro.json
```

`glyphd paths` mostra os caminhos. `GLYPH_HOME` muda a raiz.

## Estado por marco

Veja o `README.md` e o `RELATORIO.md` para o que já existe.
