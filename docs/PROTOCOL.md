# Glyph Protocol v0

O protocolo que liga o **corpo** (`Glyph.app`) ao **cérebro** (`glyphd` ou
qualquer outro agente). Implementação de referência:
`Sources/GlyphCore/Protocol/`.

## Transporte

- Socket Unix em `~/Library/Application Support/Glyph/glyphd.sock`
  (sobrescrevível com `GLYPH_HOME`).
- **JSON por linha**: cada mensagem é um objeto JSON sem quebras de linha,
  terminado por `\n`. UTF-8.
- Linha máxima: 1 MiB. Linhas maiores são descartadas e contam como erro.
- Datas em ISO 8601 UTC (`2026-09-29T21:10:00Z`). Frações de segundo são
  aceitas na leitura.

## Autenticação

O papel de cada lado (`body` ou `brain`) vem da **autenticação do socket**,
nunca de um campo da mensagem:

- O `glyphd` confere o UID do par (`getpeereid`) e a assinatura do app via
  audit token. Só o app assinado recebe o papel `body`.
- O corpo só fala com o socket do `glyphd` do mesmo usuário.

A implementação do socket autenticado chega no M2. No M0 existe só a regra
de validação (`ProtocolValidator`), que já é testada.

## Envelope

Todo objeto tem os campos do envelope **no mesmo nível** dos campos do
conteúdo:

| Campo | Tipo | Descrição |
|---|---|---|
| `v` | inteiro | Versão do protocolo. Hoje `0` |
| `id` | string | Único por remetente, até 128 caracteres |
| `type` | string | Um dos tipos abaixo |
| `ts` | string | Momento de envio, ISO 8601 |

Tipos desconhecidos são rejeitados (`unknownType`). Campos desconhecidos são
ignorados, para permitir extensões compatíveis.

## Mensagens

| Direção | `type` | Campos |
|---|---|---|
| ambos | `hello` | `role` (`body`\|`brain`), `protocolVersions` [int], `capabilities` [string], `name`? |
| corpo → cérebro | `world.update` | `activeApp`?, `activePID`?, `idleSeconds`, `cursorNearGlyph`, `focus` (`normal`\|`typing`\|`fullscreen`\|`meeting`), `windows`? [{`pid`, `app`, `frame`}] (sem títulos), `glyph`? {x,y} |
| corpo → cérebro | `input.summon` | `source` (`hotkey`\|`click`\|`voice`), `text`? |
| corpo → cérebro | `input.brake` | `engage` (bool): freio global. Pausa tudo, cancela tarefas, nega aprovações pendentes, todos voltam para casa |
| corpo → cérebro | `approval.response` | `requestId`, `decision` (`approve`\|`deny`\|`always`), `scope`? e `expires`? quando `always` |
| cérebro → corpo | `body.goto` | `target` (`window`\|`point`\|`home`); `pid` + `frame` {x,y,w,h} para janela; `point` {x,y} para ponto |
| cérebro → corpo | `body.emote` | `clip`, `dot`? (modo do Dot), `sticker`? (id de um sticker do pack para segurar), `agentId`? (especialista) |
| cérebro → corpo | `bubble.say` | `text`, `durationSec` (0 < d ≤ 30, padrão 4), `agentId`? (quem fala: especialista) |
| cérebro → corpo | `approval.request` | `action`, `target`, `class`, `why`, `timeoutSec` (0 < t ≤ 3600) |
| cérebro → corpo | `task.update` | `taskId`, `step`, `progress` (0…1), `budgetRemaining`? |
| cérebro → corpo | `agent.spawn` | `agentId`, `role` (`builder`\|`researcher`\|`designer`\|`auditor`) |
| cérebro → corpo | `agent.despawn` | `agentId` |
| cérebro → corpo | `diary.ready` | `path` |

Coordenadas (`frame`, `point`) usam o sistema global do AppKit: origem no
canto inferior esquerdo da tela principal, y para cima, em pontos.

Modos do Dot (`dot`): `steady`, `glance`, `orbit`, `trail`, `blink`, `alert`,
`shrink`, `fade`, `split`, `pulse`. Veja docs/ANIMATION.md.

Classes de ação (`class`): `read`, `compute`, `local_write`, `network_read`,
`external_effect`, `destructive`, `financial`. Veja docs/AUTONOMY.md.

## Regras de aceitação

1. `v` precisa estar entre as versões suportadas.
2. O remetente precisa estar autorizado para o tipo:
   - `approval.request` **só** é aceito vindo do cérebro;
   - `approval.response` **só** é aceito vindo do corpo (app assinado);
   - `world.*` e `input.*` só vêm do corpo; `body.*`, `bubble.*`, `task.*`,
     `agent.*` e `diary.*` só vêm do cérebro.
3. `hello.role` precisa ser igual ao papel autenticado.
4. `approval.request` com `class: financial` é rejeitado: a classe é proibida.
5. Sem resposta a um `approval.request` até `timeoutSec` → **negar**.
6. O corpo mostra no máximo ~40 caracteres por bolha (`displayText` corta
   com `…`) e uma bolha por vez.

## Handshake

Os dois lados mandam `hello` ao conectar. A versão usada é a maior comum
entre `protocolVersions`. Sem versão comum, a conexão é fechada.

## Exemplos

```json
{"v":0,"id":"a1","type":"approval.request","ts":"2026-09-29T21:10:00Z","action":"git.push","target":"origin/glyph/fix-tests","class":"external_effect","why":"Testes voltaram a passar; abrir PR de rascunho?","timeoutSec":120}
{"v":0,"id":"b7","type":"approval.response","ts":"2026-09-29T21:10:09Z","requestId":"a1","decision":"always","scope":"compute:~/dev/vk","expires":"2026-10-13T00:00:00Z"}
{"v":0,"id":"c2","type":"body.goto","ts":"2026-09-29T21:11:00Z","target":"window","pid":812,"frame":{"x":120,"y":80,"w":900,"h":600}}
```

## Modo mock

`GLYPH_MOCK=1` faz o corpo usar o `MockBrain` (roteiro fixo que passa pelos
estados do Dot), sem `glyphd`. Para ver o roteiro no terminal:

```sh
swift run glyphd mock --fast                         # imprime tudo de uma vez
swift run glyphd mock --loop                         # no tempo real, em loop
swift run glyphd mock --fast | swift run glyphd validate
```

## Versionamento

- Mudança compatível (campo novo opcional, tipo novo que o outro lado pode
  ignorar após `hello`) não muda `v`.
- Mudança incompatível sobe `v` e exige ADR em `docs/adr/`.
