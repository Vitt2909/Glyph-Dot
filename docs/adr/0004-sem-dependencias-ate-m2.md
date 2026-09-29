# 0004 — Nenhuma dependência externa até o M2

- Estado: aceita
- Data: 2026-09-29

## Contexto

O plano prevê GRDB, swift-argument-parser e o MCP swift-sdk no `GlyphDaemon`.
Nada disso é usado no M0 e no M1, e toda dependência nova exige ADR.

## Decisão

- M0 e M1 não adicionam dependências. `glyphd` faz o parse de argumentos à
  mão (quatro subcomandos).
- Cada dependência do M2 em diante entra com sua própria ADR, fixada por versão.

## Consequências

- Build em Linux e macOS sem rede além do toolchain.
- O parse manual de argumentos será trocado pelo swift-argument-parser quando
  o `glyphd` ganhar opções de verdade (M2).
