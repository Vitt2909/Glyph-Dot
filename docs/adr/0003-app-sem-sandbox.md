# 0003 — App sem App Sandbox

- Estado: proposta (precisa de revisão humana)
- Data: 2026-09-29

## Contexto

O corpo precisa ler os limites de janelas de todos os apps
(`CGWindowListCopyWindowInfo`) e falar com o socket do `glyphd` em
`~/Library/Application Support/Glyph/`. Sob App Sandbox o socket fica fora do
container e exigiria app group ou exceção temporária.

## Decisão proposta

- Distribuir fora da Mac App Store, sem App Sandbox, com Hardened Runtime.
- Entitlements vazios: nenhuma exceção do Hardened Runtime.

## Consequências

- Menos isolamento do que um app sandboxed; compensado pela regra de que o
  corpo nunca executa e pelo Hardened Runtime.
- Se a Mac App Store virar objetivo, rever com app group compartilhado.
