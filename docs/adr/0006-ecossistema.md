# 0006 — Ecossistema sem dependências e com o glyphd como único ator

- Estado: aceita
- Data: 2026-09-29

## Contexto

O M6 abre o Glyph para fora: agentes externos (VK ou outros), ferramentas
MCP, packs da comunidade e a casa em outro Mac. A ADR 0005 deixou o MCP para
"cliente próprio ou ADR própria". Cada uma dessas portas pode virar um
jeito de alguém agir sem passar pela política.

## Decisão

- **MCP por cliente próprio** (JSON-RPC 2.0 por stdio, `LineProcess` com
  `posix_spawn` e grupo de processos). Sem o MCP swift-sdk: o subconjunto
  que um cliente só-de-ferramentas usa é pequeno, e o SDK traria
  dependências e um runtime que não controlamos.
- **Ferramenta MCP nasce `external_effect`.** Só o usuário, no config, muda
  a classe. Dicas do servidor (`readOnlyHint`) são ignoradas.
- **Agente externo como cérebro por stdio (`glyph-brain/1`)**, não por
  socket: o `glyphd` controla o processo (sobe, derruba, mede tempo) e o
  agente nunca age: pede ferramentas e o `AgentLoop` decide pela política.
- **Agente no socket só anima o corpo**, e só com opção ligada. Sinais de
  segurança (clipes, stickers e pontos de aprovação, erro e perigo) são
  exclusivos do `glyphd`.
- **Pack é dado**, com manifesto e licença; não troca sinais de segurança.
- **A mala não leva confiança.** Escada, regras "sempre", histórico e chaves
  ficam na máquina.
- **Runner remoto e corpo em outro aparelho ficam como proposta**: mexem na
  fronteira de confiança (regra 11 do plano).

## Consequências

- Nenhuma dependência nova; o CI de Linux cobre MCP, agente externo, packs e
  mala com servidores e agentes falsos em `sh`.
- Mais código nosso (cliente MCP, processo de linhas).
- Um agente externo ou servidor MCP malicioso pode, no máximo, pedir: o
  usuário vê o cartão de aprovação para tudo que não é reversível.
- A descrição de uma ferramenta MCP vai para o modelo; é cortada em 1000
  caracteres e marcada com `[MCP <servidor>]`, mas continua sendo texto de
  terceiros. A trava por classe é a defesa real.
