# Modo Diversão

Por alguns minutos o desktop vira palco: você chama o Glyph, pede um truque,
uma cena ou um jogo, e ele responde com o corpo, o Dot e as bordas das
janelas.

O modo é **local e só visual**. Os comandos são reconhecidos pelo próprio
corpo e **nunca chegam ao `glyphd`**: não alteram arquivos, não rodam
comandos, não movem janelas e não criam especialistas. Funciona até sem
cérebro, com o Glyph "mudo".

## Comandos

No campo de chamada (**⌃⌥Espaço**). Maiúsculas, acentos e pontuação final
não importam. Qualquer outro texto vai para o cérebro como sempre.

| Comando | Frases equivalentes | O que acontece |
|---|---|---|
| `/diversao iniciar` | "vamos brincar", "bora brincar" | Liga o modo por **5 minutos**. Um convite curto e ele espera no lugar |
| `/diversao parar` | "chega de brincar" | Desliga na hora e volta à vida normal |
| `/surpresa` | "me surpreenda" | Sorteia uma cena disponível, sem repetir a última |
| `/danca` | "dança pra mim" | Coreografia de ~7 s. Com o [pack de exemplo](../Examples/pack-exemplo) instalado, usa a `danca` dele |
| `/robo` | "modo robô" | Três batidas mecânicas, pausa, desliga e religa |
| `/truque` | "mostra um truque" | Malabarismo com o Dot e *ta-da* |
| `/estatua` | "estátua" | Jogo: ele congela. Chegue com o cursor perto para tentar fazê-lo rir. Três provocações e ele perde; 30 s e ele ganha; clique nele para encerrar |
| `/janela-palco` | "sobe no palco" | Vai até a borda de janela mais próxima, desfila, se equilibra, gira e agradece |

Qualquer comando de brincadeira liga o modo, se ele estiver desligado: pedir
é o opt-in. Com o modo ligado o Glyph fica no palco (não passeia nem dorme)
até o tempo acabar, e então avisa "fim do recreio.".

## Regras

- **Sinais de verdade vencem.** O freio (⌃⌥⌘.), um pedido de aprovação, uma
  tarefa, um erro ou alerta, um `body.goto` do cérebro, uma janela cobrindo
  o Glyph ou a tela cheia encerram o modo na hora, sem terminar a cena.
- Com o freio puxado ou uma aprovação pendente, o Glyph recusa brincar
  numa bolha curta, e o comando **não** solta o freio.
- Cada comando é uma apresentação finita. Nada entra em loop sozinho.
- Arrastar o Glyph ou clicar nele corta a cena atual (na estátua, o clique
  encerra a rodada).
- Sem janela onde desfilar, `/janela-palco` sugere outra brincadeira em vez de
  forçar uma animação desconectada do mundo.
- **Movimento reduzido** (Acessibilidade do macOS): cada cena vira só a pose
  final, sem trajeto nem giro.
- Nenhuma cena usa os sinais protegidos (`await`, `error`, `alert`) nem os
  modos do Dot que têm significado de segurança ou de equipe (`blink`,
  `alert`, `shrink`, `split`). `ta-da` é truque de palco, nunca prova de
  tarefa concluída.

## Clipes

Novos no pack padrão, usados pelas cenas (e disponíveis para `body.emote`):

| Clipe | Uso |
|---|---|
| `invite` | Convite curto, depois espera |
| `groove` | Passo de dança em loop |
| `spin` | Giro: o motor troca o lado desenhado a cada meia-volta |
| `ta-da` | Braços abertos, apresenta o Dot |
| `robot` | Dança do robô com desligamento cômico |
| `dot-juggle` | Mãos acompanham a órbita do Dot (um Dot só) |
| `statue` | Pose congelada da estátua |
| `balance` | Braços abertos, pequenas correções |
| `bow` | Reverência curta |
| `parade` | Passo de desfile, troca o `walk` no palco |

## Onde mora

Tudo no Core, testado em Linux: `FunCommand`, `FunCatalog`, `FunStage` e
`FunMode` em `Sources/GlyphCore/Behavior/FunMode.swift`, e a costura no
`GlyphEngine` (`fun(_:)`, `setBrake(_:)`, `reducedMotion`). O app só chama
`BodyController.fun(_:)` antes de mandar o texto ao cérebro.
