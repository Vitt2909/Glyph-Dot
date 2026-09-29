# Contribuindo com o Glyph

Obrigado por querer dar vida ao Glyph.

## Antes de começar

- Leia os princípios no `README.md`. Eles não são negociáveis.
- Mudanças na trava de irreversíveis ou na escada de confiança entram
  **só como proposta** em `docs/AUTONOMY.md` + ADR, para revisão humana.
- Nenhuma dependência nova sem ADR em `docs/adr/`.
- APIs privadas da Apple são proibidas.

## Ambiente

| Onde | O que roda |
|---|---|
| Linux ou macOS com Swift 6 | `swift build`, `swift test` (GlyphCore, GlyphDaemon, glyphd) |
| macOS 14+ com Xcode 16+ | Tudo acima + `GlyphBody` e o app (`Scripts/bundle-app.sh`) |

```sh
swift test                                   # testes do Core
swift run glyphd mock --fast                 # roteiro do cérebro falso
Scripts/bundle-app.sh && open build/Glyph.app   # só macOS
GLYPH_MOCK=1 build/Glyph.app/Contents/MacOS/Glyph
```

## Regras de código

- `GlyphCore` só importa Foundation e precisa passar em Linux.
- Se dá para testar em Linux, mora no Core. O corpo macOS só lê o mundo e desenha.
- Swift 6, concorrência estrita. Nada de `@unchecked Sendable` sem comentário explicando.
- Coordenadas: sempre o sistema global do AppKit (origem embaixo à esquerda).
  Conversões só em `WorldCoordinates`.
- Física e animação determinísticas: nada de `random()` sem semente.
- Commits pequenos, mensagem clara no imperativo.

## Por onde começar (`good first issue`)

- **Nova emoção ou pose**: um JSON em `Packs/default/clips/` (docs/ANIMATION.md).
- **Novo sticker** (ícone de memória, tarefa, ideia): traços em `Packs/default/stickers/`.
- **Manifesto de ferramenta MCP** declarando `actionClass` e `reversible` (M3).

Contribuições maiores: sensores, adaptadores de cérebro, traduções.

## Pull requests

1. Um assunto por PR.
2. `swift test` verde. Se mexeu no corpo, diga se compilou e testou no macOS.
3. Mudou algo visível? Um GIF curto no PR vale mais que um parágrafo.
4. Arte em `Packs/` é CC BY 4.0; código é Apache-2.0. Ao contribuir você
   concorda em licenciar sob essas licenças.

## Segurança

Falhas de segurança vão pelo canal privado descrito em `docs/SECURITY.md`,
nunca por issue pública.
