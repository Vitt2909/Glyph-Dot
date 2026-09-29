# 0002 — SwiftPM sem projeto Xcode

- Estado: aceita
- Data: 2026-09-29

## Contexto

Projetos `.xcodeproj` são difíceis de revisar em PR, geram conflitos e não
existem em Linux. O plano pede `Apps/Glyph/` com Info.plist e entitlements.

## Decisão

- Todo o código é SwiftPM (`Package.swift`, tools 6.0, modo Swift 6).
- Os alvos macOS (`GlyphBody`, `GlyphApp`) só são declarados quando
  `os(macOS)`.
- `Scripts/bundle-app.sh` monta `build/Glyph.app` a partir do executável do
  SwiftPM, com `Apps/Glyph/Info.plist` e `Apps/Glyph/Glyph.entitlements`, e
  assina (ad hoc por padrão; Developer ID via `GLYPH_SIGN_IDENTITY`).

## Consequências

- `swift build` / `swift test` bastam em qualquer plataforma.
- Sem catálogo de assets do Xcode: o ícone do app (quando existir) entra como
  `.icns` copiado pelo script.
- Quem preferir Xcode pode abrir o `Package.swift` direto.
