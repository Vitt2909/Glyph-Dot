# 0001 — Três peças: corpo, cérebro, protocolo

- Estado: aceita
- Data: 2026-09-29

## Contexto

Uma criatura que age no computador do usuário precisa de uma separação clara
entre o que desenha e o que executa. Se o overlay pudesse executar, qualquer
bug de interface viraria um bug de segurança.

## Decisão

- O corpo (`Glyph.app`) só desenha e percebe. Nunca executa.
- O cérebro (`glyphd`) é o único processo que age, sempre passando pela política.
- Os dois falam o Glyph Protocol (JSON por linha num socket Unix).
- Toda lógica testável (protocolo, física, navegação, comportamento, animação)
  mora em `GlyphCore`, que só depende de Foundation e roda em Linux.

## Consequências

- Qualquer agente que fale o protocolo pode ser o cérebro.
- O corpo roda sem cérebro (mock) e o cérebro roda sem corpo (headless).
- O CI em Linux cobre a maior parte da lógica, inclusive a do corpo.
