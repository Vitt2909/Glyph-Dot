# Relatório — M0 Fundação

Branch: `feat/m0-fundacao`.

## Feito

- `Package.swift` (tools 6.0, modo Swift 6, macOS 14+). Alvos macOS só
  declarados em `os(macOS)`, então `swift build`/`swift test` rodam em Linux.
- **GlyphCore** (só Foundation):
  - Glyph Protocol v0 completo: envelope plano, as 12 mensagens, codec JSON
    por linha, `LineBuffer` com limite de 1 MiB, datas ISO 8601.
  - `ProtocolValidator`: versão, remetente por tipo (`approval.request` só do
    cérebro, `approval.response` só do corpo), `hello` com papel real,
    `financial` rejeitada, limites de progresso/timeout/duração.
  - `MockBrain`: roteiro determinístico que passa pelos estados do Dot e
    responde a clique e aprovação.
  - Geometria (`Vec2`, `Rect`), esqueleto procedural com cinemática direta,
    `Pose`, `StickerStyle`, `LineBoil` determinístico, `StickerShapes`
    (geometria final do adesivo, com boil) e `GlyphDrawing`.
- **GlyphDaemon / glyphd**: `version`, `paths`, `mock [--fast] [--loop]`,
  `validate` (lê JSON por linha e valida).
- **GlyphBody** (macOS): `OverlayPanel` por tela, `HitTestToggler`,
  `GlyphView` com `CAShapeLayer`s no estilo adesivo, bolha, app delegate que
  mostra o Glyph parado sobre o Dock e usa o `MockBrain` com `GLYPH_MOCK=1`.
- `Apps/Glyph/Info.plist` (LSUIElement), entitlements vazios,
  `Scripts/bundle-app.sh`.
- CI: `linux-core.yml` (container `swift:6.1-noble`), `macos-build.yml`
  (macos-15, monta o app), `release.yml` (tag `v*` → release rascunho).
- Docs: README, ARCHITECTURE, PROTOCOL, AUTONOMY (especificação), SECURITY,
  ANIMATION, 4 ADRs, CONTRIBUTING, CODE_OF_CONDUCT (Contributor Covenant 2.1),
  LICENSE (Apache-2.0), LICENSE-ASSETS (CC BY 4.0).

## Aceite

| Critério | Estado |
|---|---|
| `swift test` verde em Linux | ✅ 34 testes, Swift 6.1.3, Ubuntu 24.04 |
| App abre e mostra um Glyph parado | ⚠️ **Não compilado.** Sem macOS neste ambiente; código revisado à mão. O job `macos-build` do CI é a primeira compilação real |

## Não compilado (precisa de macOS)

Tudo em `Sources/GlyphBody/` e `Sources/GlyphApp/`. Pontos para olhar se o
CI do macOS falhar:

- `OverlayPanel` define um `init(screen:)` sem `init?(coder:)`.
- Conversões implícitas `Double` ↔ `CGFloat` (SE-0307) em `GlyphView`.
- Closures de `Timer` e `NotificationCenter` usam `MainActor.assumeIsolated`.

## Decisões tomadas sozinho

1. **Sem projeto Xcode** (ADR 0002): app montado por script a partir do SwiftPM.
2. **Sem dependências** (ADR 0004): `glyphd` faz parse de argumentos à mão.
3. **App sem App Sandbox** (ADR 0003, *proposta*): precisa de revisão.
4. **Envelope plano**: campos do conteúdo no mesmo nível de `v/id/type/ts`,
   como no exemplo do plano.
5. **`hello` carrega `role` e `protocolVersions`**; a versão usada é a maior
   comum.
6. **`financial` é rejeitada já no protocolo**, além da política (M3).
7. **Convenção de ângulos** do esqueleto: 0 = para baixo, anti-horário,
   lados anatômicos — é o que faz o exemplo `wave` do plano levantar a mão.
8. **Contato do Código de Conduta** deixado como `[CONTATO A DEFINIR]`: não
   publiquei nenhum e-mail pessoal.

## Bloqueios e pendências para humanos

- **Nome do repositório**: o plano pede para evitar "Dot" na marca e no
  repositório por causa do "Dots" da OpenAI, mas o repositório se chama
  `glyph-dot`. Sugestão: renomear para `glyph` (ou similar) antes de publicar,
  e checar disponibilidade no GitHub e no Homebrew.
- Definir o contato do `CODE_OF_CONDUCT.md`.
- Ativar o *private vulnerability reporting* nas configurações do repositório
  (citado em `docs/SECURITY.md`).
- Conta Apple Developer para Developer ID + notarização.

## Como rodar

```sh
swift test
swift run glyphd mock --fast | swift run glyphd validate

# macOS
Scripts/bundle-app.sh && open build/Glyph.app
GLYPH_MOCK=1 build/Glyph.app/Contents/MacOS/Glyph
```
