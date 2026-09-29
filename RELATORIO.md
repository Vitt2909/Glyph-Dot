# Entrega — M0 a M6

Todos os marcos do plano estão implementados, cada um num branch empilhado
sobre o anterior, com PR de rascunho (nada foi mesclado por mim):

| Marco | Branch | PR |
|---|---|---|
| M0 Fundação + M1 A criatura muda | `feat/m1-na-main` (contém `feat/m0-fundacao`) | #3 → `main` |
| Arte em SVG | `feat/arte-svg` | #4 |
| M2 Cérebro reativo | `feat/m2-cerebro` | #5 |
| M3 Autonomia v1 | `feat/m3-autonomia` | #6 |
| M4 Objetivos e turno noturno | `feat/m4-objetivos` | #7 |
| M5 Multi-Glyph | `feat/m5-multi-glyph` | #8 |
| M6 Ecossistema | `feat/m6-ecossistema` | #9 |

Cada PR aponta para o branch do marco anterior: mesclados em ordem (#3 → #9),
a `main` fica com tudo.

`swift test` em Linux: **245 testes** verdes. O corpo (AppKit) é compilado
pelo CI de macOS; ainda **não foi visto rodando num Mac de verdade**.

## Bug grave encontrado no M6 (vale para M2–M5)

`glyphd run` e `glyphd ask` **travavam para sempre** desde o M2: o código de
topo do `main.swift` roda no MainActor, os comandos criavam um `Task {}`
(que herda o MainActor) e bloqueavam a thread principal num semáforo
esperando por ele. Os testes usam o servidor direto, por isso não pegaram.
Corrigido no commit "glyphd: run e ask não travam mais no MainActor" deste
branch (troca por `Task.detached`, sem outra mudança) e coberto pelo novo
`Scripts/fumaca.sh` no CI, que roda o binário de verdade. **Mesclar só até o
M5 deixa o `glyphd` travado**: mescle a pilha até o M6, ou traga esse commit
(é isolado; `git cherry-pick` aplica limpo no M2).

## Como rodar

```sh
swift test
Scripts/fumaca.sh                                    # glyphd de verdade: ask, run, agente externo
swift run glyphd mock --fast | swift run glyphd validate
swift run glyph-art                                  # regenera a arte (determinística)

# macOS
Scripts/bundle-app.sh && open build/Glyph.app        # a criatura (sem cérebro, anda sozinha)
GLYPH_MOCK=1 build/Glyph.app/Contents/MacOS/Glyph    # com o cérebro falso
swift build -c release
.build/release/glyphd config && .build/release/glyphd chave anthropic
.build/release/glyphd install                        # LaunchAgent
.build/release/glyphd pair build/Glyph.app           # sem Developer ID
```

## Decisões que precisam de gente

- **Nome do repositório** tem "Dot" (o plano pede para evitar). Sugestão:
  renomear antes de publicar.
- Contato do `CODE_OF_CONDUCT.md` (está `[CONTATO A DEFINIR]`).
- Ativar o *private vulnerability reporting* do GitHub.
- Conta Apple Developer (Developer ID + notarização).
- ADR 0003 (app sem App Sandbox) continua **proposta**.
- Proposta 0001 (runner remoto) aguarda revisão: mexe na fronteira de
  confiança.
- Validar o M1 num Mac: rodar, medir CPU em repouso, gravar o GIF.

---

# Relatório — M6 Ecossistema

Branch: `feat/m6-ecossistema` (empilhado sobre `feat/m5-multi-glyph`).

## Feito

| Área | Onde | O quê |
|---|---|---|
| Agente externo como cérebro | `ExternalAgentBrain`, `provider: externo` | O `glyphd` roda o agente por stdio no protocolo `glyph-brain/1` (docs/ECOSYSTEM.md). Ele só propõe chamadas; o `AgentLoop` executa pela política. Não recebe chaves nem o `raw` de outro provedor. Timeout, processo em grupo próprio, sobe de novo se cair |
| MCP | `MCPClient`, `MCPTool`, seção `mcp:` | Cliente JSON-RPC 2.0 por stdio (`2025-06-18`): `initialize`, `tools/list` com paginação, `tools/call`. Ferramenta nasce `external_effect`; só o config muda a classe; dicas do servidor ignoradas; saída como conteúdo observado; pedidos do servidor recusados; servidor travado é morto |
| Processo de linhas | `LineProcess` | `posix_spawn` com stdin/stdout em pipe, stderr em `/dev/null`, leitura numa thread, `SIGPIPE` ignorado, sem zumbi |
| Agentes no socket | `GlyphServer` | `hello` com papel `brain` vira marionetista (só com `agentes_externos.corpo`): gesto, fala (≤ 8 s), ir a ponto/casa; sem aprovação, tarefa, mundo ou sinais de segurança; 5 msgs/2 s; mudo com o freio |
| Packs da comunidade | `PackManifest`, `PackLoader` (Core) | `pack.json` com licença; só JSON, até 256 KB por arquivo e 200 por pasta; sem link simbólico; não troca `await`/`error`/`alert` nem `cartao`/`pausa`/`escudo`. O corpo carrega `casa/packs/` |
| Pack de exemplo | `Examples/pack-exemplo/` | "Festa": clipe `danca` e sticker `balao`; prévia animada gerada pelo `glyph-art` |
| Mala | `Mala`, `glyphd mala` | Exporta objetivos, config (sem pareamento), habilidades (sem rascunhos), memória e packs; importar nunca sobrescreve (`.da-mala`) e recusa `..`, ocultos e objetivos inválidos |
| Comandos | `glyphd mcp`, `glyphd packs [validar]`, `glyphd mala` | |
| Exemplos | `Examples/agentes/` | `agente-eco.py` (cérebro por stdio) e `marionete.py` (socket), só biblioteca padrão |
| CI | `Scripts/fumaca.sh` | Roda o `glyphd` de verdade; valida o pack de exemplo; a prévia do pack entra na checagem de arte |

## Aceite

| Critério | Estado |
|---|---|
| Um agente externo (VK ou outro) serve de cérebro | ✅ `testExternalAgentBrainDrivesTheLoopThroughThePolicy` (agente em `sh`), `Scripts/fumaca.sh`, e `glyphd ask` com `Examples/agentes/agente-eco.py` pedindo `web_search` de verdade |
| Agente externo não pula a trava | ✅ `testExternalAgentCannotSkipApproval` |
| MCP desconhecido = `external_effect` | ✅ `testMCPToolDefaultsToExternalEffectAndIgnoresServerHints`, `testMCPToolNeedsApprovalInTheAgentLoop` |
| Packs da comunidade | ✅ `CommunityPackTests` (5 testes) |
| Viagem entre dispositivos | Parcial: a mala (✅ `testMalaCarriesWhatTheUserWroteAndLeavesTrustBehind`). O Glyph andando entre aparelhos não existe: precisa de um corpo em outro sistema |
| Runner remoto opcional | Só proposta (`docs/propostas/0001-runner-remoto.md`) |

## Decisões tomadas sozinho

1. **MCP sem SDK** (ADR 0006): o cliente só-de-ferramentas é pequeno.
2. **Dicas do servidor MCP não contam**: `readOnlyHint` vem de quem não é o
   usuário.
3. **Agente externo pensa por stdio, não pelo socket**: o `glyphd` controla o
   processo e o agente nunca vira executor.
4. **Agente no socket desligado por padrão** e, ligado, só marionete.
5. **Sinais de segurança são exclusivos do `glyphd`**, em packs e em agentes.
6. **A mala não leva confiança**: pastas e repositórios são outros na outra
   máquina.
7. **Runner remoto e corpo em outro aparelho viraram proposta**: mexem na
   fronteira de confiança.

## Faltando

- Corpo em outro aparelho (iPhone, outro Mac) e o Glyph "atravessando".
- Runner remoto (proposta).
- Recursos e prompts do MCP (só ferramentas); transporte HTTP do MCP.
- Loja ou índice de packs; assinatura de packs.

---

# Relatório — M5 Multi-Glyph

Branch: `feat/m5-multi-glyph` (empilhado sobre `feat/m4-objetivos`).

## Feito

| Área | Onde | O quê |
|---|---|---|
| Perfis | `SpecialistProfile` | Builder (lê, escreve, testa; chave), Pesquisador (web e leitura; lupa), Designer (lê e propõe; pincel), Auditor (lê e roda testes, não escreve; escudo) |
| Portão por papel | `SpecialistGate` | Fora do papel nem pede (o Auditor não escreve); irreversível sempre passa pela política |
| Time | `Team` (actor) | Máximo de 3 especialistas simultâneos (o 4º espera vaga); cada um com prompt, ferramentas e orçamento próprios; `agent.spawn`/`agent.despawn` para o corpo |
| Veto | `Team.buildAndAudit` | Builder faz → Auditor confere: primeiro os fatos (o comando de verificação; teste falhando = veto sem gastar modelo), depois o julgamento (diff + "VEREDITO: APROVADO / VETO: motivo"; sem veredito claro = veto). Veto volta ao Builder com o motivo; depois de 2 rodadas, escala |
| Objetivos | `GoalRunner` + `Team` | Cada abordagem passa pelo Builder e pelo Auditor; verificação passando **não basta** se o Auditor vetou até o fim |
| Supervisor | `DelegateTool` | Nos chamados, o Glyph pode chamar o Pesquisador ou o Designer; o que eles trazem volta como conteúdo observado |
| Visual | `GlyphEngine.companions` | Assobio (clipe `whistle`, Dot em `split`), o especialista salta da cabeça, anda ao lado segurando o sticker do papel, fala em bolha própria (`agentId`) e volta para o Dot; o corpo desenha vários Glyphs e bolhas |
| Protocolo | `agentId` | Opcional em `bubble.say` e `body.emote` |
| Config | `equipe` | `ativa`, `cerebros` por papel (ex.: Auditor com esforço `high`) |

## Aceite

| Critério | Estado |
|---|---|
| Tarefa de código passa pelo Auditor; um veto devolve ao Builder e aparece no diário | ✅ `TeamTests.testGoalWithTeamVetoAppearsInDiary`: a gambiarra passava no teste, o Auditor vetou pelo diff, o Builder refez, o ramo recebeu a versão aprovada, e o diário registra "veto do Auditor: gambiarra no valor" |
| No máximo 3 especialistas | ✅ `testAtMostThreeSpecialists`, `CompanionTests.testAtMostThreeCompanions` |
| Visual (assobio, sai do Dot, "terminou?" · "sim." · "não.") | ✅ `testVetoReturnsToBuilderThenApproves` (sequência exata de bolhas), `CompanionTests`; cena em `docs/art/equipe.svg` |

`swift test`: **224 testes** verdes.

## Decisões tomadas sozinho

1. **O Auditor primeiro olha os fatos:** se a verificação falha, é veto sem
   chamar modelo (mais barato e mais confiável).
2. **Sem veredito explícito = veto** (conservador).
3. **Especialista fora do seu papel não pede aprovação:** é negado. Pedir
   para o Auditor escrever código seria um desvio de papel, não uma decisão sua.
4. **Designer não escreve código**: propõe.
5. **Especialistas não chamam especialistas** (só o supervisor delega).

---

# Relatório — M4 Objetivos e turno noturno

Branch: `feat/m4-objetivos` (empilhado sobre `feat/m3-autonomia`).

## Feito

| Área | Onde | O quê |
|---|---|---|
| Objetivos | `Core/Goals/Goal.swift` | `goals.yaml` no formato do plano; validação recusa classe irreversível em `classes_permitidas`, comando de sucesso destrutivo e horário inválido; horários `sempre`, `noite`, `HH:MM` |
| Orçamentos | `Budget`, `BudgetLedger`, `ModelPrice` | Ações, tokens, tempo e dólares por tarefa e por dia; preços dos modelos Claude atuais; Ollama custa zero |
| Quadro | `BoardTask`, `BoardStore` (`casa/quadro.json`) | Tarefas por objetivo, tentativas com hipótese e resultado, estado `precisa_de_voce` |
| Espaço de trabalho | `WorkspaceManager` | `git worktree add -b glyph/<tarefa>` (nunca a main nem a cópia do usuário); sem git, checkpoint em `casa/journal/<id>/` |
| Ferramentas da tarefa | `ReadFileTool`, `WriteFileTool` | Presas ao worktree; nunca em `.git`; leitura marcada como conteúdo observado |
| Executor | `GoalRunner` | Verifica → cria tarefa → worktree → até 3 abordagens diferentes (a hipótese de cada uma entra no prompt da próxima) → commit no ramo → pede para publicar (irreversível: sempre pede) → escala com uma linha |
| Portão do objetivo | `GoalGate` | O que o objetivo autoriza e é reversível roda sem pedir **dentro do worktree**; o resto segue a política |
| Lições | `casa/skills/_rascunhos/<tarefa>.md` | Quando dá certo depois de falhar; só vira skill ativa com aprovação |
| Diário | `Diary`, `casa/diario/AAAA-MM-DD.md` | Feito · tentado sem sucesso · precisa de você · custos; `diary.ready` para o corpo |
| Turno noturno | batimento de 30 s | Noite (22h–7h) ou usuário ausente há mais de 10 min; `NightPower` segura o sono ocioso só com tarefa aberta, só na tomada, só com opt-in |
| Corpo | mochila, diário, casa | Clipe `backpack` com a mochila; de manhã volta segurando o diário (clique abre); duplo clique abre a casa (SwiftUI, só leitura: Memória · Tarefas · Skills · Histórico · Cérebro · Política) |

## Aceite

| Critério | Estado |
|---|---|
| "Testes verdes" ativo à noite → de manhã há um ramo `glyph/*` com correção proposta e um diário explicando; a main está intocada | ✅ `GoalRunnerTests.testNightShiftProposesFixOnGlyphBranchAndWritesDiary`: git real, a 1ª abordagem falha, a 2ª (diferente) passa; commit no ramo; `main` e a cópia do usuário iguais; o diário cita o ramo, a hipótese que falhou e "publicar: precisa de você" |
| 3 falhas → escala | ✅ `testThreeFailuresEscalate` |
| Orçamento para o trabalho | ✅ `testBudgetStopsWork` |

`swift test`: **216 testes** verdes.

## Decisões tomadas sozinho

1. **O comando de `sucesso` é uma verificação declarada pelo usuário.** Roda
   sem cartão, mas é recusado na validação se o classificador o vir como
   destrutivo.
2. **`classes_permitidas` valem como autorização dentro do worktree** do
   objetivo. Classes irreversíveis nem são aceitas no arquivo.
3. **Tentativa que falhou é descartada** (`reset --hard`/`clean`) **só no
   worktree do Glyph**, para a próxima abordagem começar limpa.
4. **"Noite" = 22h–7h ou usuário ausente há mais de 10 min** (ou nenhum corpo conectado).
5. **Diário das últimas 24 h** no horário do objetivo de resumo (sem `sucesso`).
6. **O painel da casa é só leitura.** Editar é pelo `glyphd` ou nos arquivos,
   que são legíveis de propósito.
7. **O desfazer de um ramo** apaga o worktree e o ramo (`git branch -D`, só do
   ramo `glyph/*`), e rebaixa a escada como qualquer desfazer.

---

# Relatório — M3 Autonomia v1

Branch: `feat/m3-autonomia` (empilhado sobre `feat/m2-cerebro`).

## Feito

| Área | Onde | O quê |
|---|---|---|
| Política | `Core/Policy/TrustLadder.swift` | Níveis 0–3, iniciais e tetos da tabela do plano, escada por classe e escopo (5 aprovações em 14 dias sobem; recusa/desfazer desce; só reversíveis se movem), regras "sempre" com escopo e validade, **trava de irreversíveis em código** |
| Intenções | `Core/Policy/Intent.swift` | `Intent`, `S = R·C·U·(1 − I·F)`, limiares 0,3/0,6, foco, calibração da confiança pelo histórico |
| Falhas de teste | `Core/Policy/FailureParser.swift` | Primeiro arquivo:linha em XCTest, Swift Testing, pytest, Jest/Vitest, Go, Rust |
| Sensores | `Daemon/Sensors` | `sensors.sock` (só o mesmo usuário), `Scripts/glyph-shell.zsh` (comando, código, pasta, duração; nunca a saída; espaço na frente = privado; em segundo plano), `GitWatcher` (commit novo) |
| Autonomia | `Daemon/Autonomy` | Reflexos → intenção → pontuação → política → age/aponta/descarta → histórico. Não repete a mesma intenção por 60 s. Respeita o freio |
| Casa | `policy.yaml`, `confianca.json`, `historico.jsonl` | Legíveis; `glyphd historico`, `desfazer`, `confianca` |
| Servidor | `GlyphServer` | Portão com a política de verdade; "sempre" do cartão vira regra no escopo guardado pelo daemon; freio cancela o chamado, nega pendências e manda todos para casa; chamar solta o freio |
| Protocolo | `input.brake` | Corpo → cérebro |
| Corpo | ⌃⌥⌘. | Freio (o corpo vai para casa sem esperar o cérebro) |
| Pack | `point` | Aponta segurando o alfinete |

## Aceite

| Critério | Estado |
|---|---|
| Teste falha no terminal → percebe, se aproxima, roda os testes sozinho (`compute`, nível 2) e aponta o arquivo | ✅ `AutonomyTests.testFailingTestsAreRerunAndFilePointed`: vai até o terminal, segura o alfinete, bolha "2 falhas: ParserTests.swift:42", sem cartão |
| Qualquer `external_effect` sempre gera cartão; timeout nega | ✅ `PolicyTests.testIrreversibleLockHoldsAgainstEverything`, `ServerTests.testApprovalTimeoutDenies` |
| Testes do Core cobrem promoção, rebaixamento e a trava | ✅ `TrustLadderTests` (6), `PolicyTests` (5), `ScoringTests` (4) |

`swift test`: **206 testes** verdes.

## Decisões tomadas sozinho

1. **Autonomia só age em repositórios marcados** (`sensores.repos`). Fora
   deles, a relevância fica abaixo de 0,6: ele só aponta, calado.
2. **Custo de interrupção baixo para "repetir testes"** (0,2): ele não fala
   com você para fazer isso; só anda até o terminal.
3. **Pedido do usuário não gera bolha de "aviso"** no nível 2: a resposta
   final já é o aviso (uma bolha por vez).
4. **Nível 0 com pedido explícito do usuário vira cartão** em vez de recusa
   silenciosa.
5. **Regra "sempre" vale no máximo 90 dias**, mesmo que o corpo peça mais.
6. **Script chamado por caminho** (`./x`) é `external_effect`: nunca repetido sozinho.
7. **JSON/JSONL em vez de `glyph.sqlite`**: sem dependência (ADR 0005),
   legível e fácil de auditar. Se o volume crescer, SQLite entra com ADR.
8. **Freio solta ao chamar o Glyph** (pedido explícito).
9. **Nenhuma mudança nas regras da escada ou da trava**: implementadas como
   estão no plano. Propostas futuras vão em `docs/AUTONOMY.md`.

## Faltando

- Sensor de calendário (EventKit) para `focus: meeting` automático: o foco
  hoje vem do corpo (tela cheia) e do que o `world.update` disser.
- FSEvents no lugar do polling de git (mesma interface).
- Segurar a casa por 1 s como freio (hoje é só o atalho).

---

# Relatório — M2 Cérebro reativo

Branch: `feat/m2-cerebro` (empilhado sobre `feat/arte-svg`).

## Feito

| Área | Onde | O quê |
|---|---|---|
| Transporte | `GlyphIPC` | Socket Unix 0600 com `DispatchSource`, JSON por linha, credenciais do par (`SO_PEERCRED` no Linux, `getpeereid` + audit token no macOS) |
| Confiança | `PeerVerifier` | Outro UID → recusa. Mesmo UID sem assinatura → corpo não verificado (percebe e chama, **não aprova**). Assinatura conferida por `SecCode` (equipe Developer ID ou cdhash pareado) → pode aprovar |
| Cérebros | `GlyphDaemon/Brains` | Anthropic (Messages API, `claude-opus-5-5`, esforço configurável, fallback de recusa ligado, conteúdo do assistente reenviado intacto, `refusal` tratado, repetição em 429/5xx), OpenAI, Ollama, roteiro (testes) e offline |
| Ferramentas | `GlyphDaemon/Tools` | `shell` (pastas permitidas, sem `sudo`, ambiente limpo, `posix_spawn` com grupo próprio para o timeout, `sandbox-exec` no macOS), `web_search` (DuckDuckGo/Brave/SearXNG), `web_fetch` (só hosts públicos), `open` |
| Classificação | `Core/Policy/CommandClassifier` | Cada comando de shell ganha a classe mais arriscada possível: push na main e push forçado são `destructive`; desconhecido é `external_effect` |
| Agente | `AgentLoop` | Pergunta → cérebro → portão → ferramenta → resultado → resposta. Leitura roda; `compute` roda e avisa; o resto pede; `financial` nunca. Depois de conteúdo observado, até `compute` pede |
| Servidor | `GlyphServer` | Encena o trabalho no corpo: pensa (Dot orbita), vai até a janela do navegador/terminal, trabalha, volta, fala. Aprovação só de corpo verificado; timeout nega |
| Config | `MiniYAML` + `DaemonConfig` | `casa/config.yaml` (modelo `config`), chaves no Keychain ou em variáveis de ambiente, log diário com redação de segredos |
| LaunchAgent | `LaunchAgent` | `glyphd install/uninstall`, reinicia só se morrer com erro |
| Corpo | `GlyphBody/Brain` | `BrainLink` (reconecta sozinho), campo de chamada com ⌃⌥Espaço (Carbon, sem Acessibilidade), cartão de aprovação (sem "sempre" para irreversíveis), resumo das janelas sem títulos |

## Aceite

| Critério | Estado |
|---|---|
| "Glyph, quanto está o dólar?" → vai ao navegador, consulta pela ferramenta, volta e responde na bolha | ✅ `ServerTests.testDollarQuestionEndToEnd` pelo socket real, com cérebro roteirizado e busca com HTTP falso. ⚠️ Com a API real, falta testar num Mac com chave |
| `glyphd` como LaunchAgent | ✅ plist testado; ⚠️ `launchctl bootstrap` só num Mac |
| Ferramentas `shell` (sandbox) e `web.search` | ✅ testadas (timeout mata a árvore, ambiente limpo, pastas) |

`swift test`: **176 testes** verdes em Linux.

## Decisões tomadas sozinho

1. **Sem dependências** (ADR 0005): HTTP direto, YAML próprio, `posix_spawn`.
2. **Modelo padrão `claude-opus-5-5`** com `effort: medium` e o fallback de
   recusa (`fallbacks: "default"`) **ligado por padrão**. Desliga com
   `fallbacks: false` no `config.yaml`.
3. **Sem Developer ID, aprovação só com cdhash pareado** (`glyphd pair`). Um
   build ad hoc qualquer com o mesmo identificador não aprova nada.
4. **`--dev`** permite aprovar de um corpo não verificado, só para desenvolvimento.
5. **Resposta de até 40 caracteres** pedida no prompt do sistema e cortada no corpo.
6. **O "sempre permitir" do cartão** ainda vale só como aprovação da vez: a
   regra com escopo e validade em `policy.yaml` é do M3.
7. **`world.update` ganhou `windows` e `glyph`** (campos opcionais): donos e
   posições das janelas, nunca títulos, para o cérebro saber aonde "ir".

---

# Relatório — M1 A criatura muda

Branch: `feat/m1-criatura` (sai de `feat/m0-fundacao`). Sem IA nenhuma.
O relatório do M0 continua abaixo.

## Feito

Tudo que decide alguma coisa mora no **GlyphCore** e é testado em Linux. O
corpo macOS só lê o sistema, alimenta o motor e desenha.

| Área | Onde | O quê |
|---|---|---|
| World Model | `Core/World` | Telas, janelas (da frente para trás), chão = topo do Dock (ou borda), teto = base da barra de menu, casa = notch (ou pílula). Topo de janela só vira plataforma onde está visível (oclusão por ordem Z) e onde cabe o corpo em pé. Laterais visíveis viram paredes escaláveis; bordas de tela seguram. Diff entre snapshots. Conversão CG → AppKit num lugar só (`WorldCoordinates`) |
| Física | `Core/Physics` | Passo fixo de 1/60 s, gravidade, velocidade terminal, plataformas de mão única, coyote time de 80 ms, escalar e subir no topo, pendurar no teto, ser carregado e arremessado. Janela arrastada leva o Glyph junto; janela que some derruba; janela que cobre (ou a própria que maximiza) segura enquanto ele foge |
| Pulo resolvido | `JumpSolver` | Arco balístico que alcança o alvo; tenta arcos mais altos se precisar; recusa o que o corpo não alcança |
| Navegação | `Core/Navigation` | Grafo de segmentos com arestas de andar, cair, pular, escalar, agarrar o teto e soltar; A* com heurística admissível; `PathFollower` vira comandos e pede replanejamento quando o mundo muda |
| Comportamento | `Core/Behavior` | Locomoção (`stand … carried`), intenções por utilidade com histerese, necessidades (energia, curiosidade, sociabilidade), reações ao cursor (olhar, recuar, acenar após 1 s) |
| Animação | `Core/Animation` | Formato de clipe do plano, amostragem a 12 fps, easing, validação, IK de dois ossos, respiração, olhar, squash & stretch com overshoot, antecipação de 0,1 s antes do pulo, Dot com os 10 modos, olhos só quando expressam |
| Motor | `Core/Engine/GlyphEngine` | Junta tudo; aceita mensagens do cérebro (`body.goto`, `body.emote`, `bubble.say`, `approval.request`, `task.update`); pede ao corpo 60/12/6/0 fps |
| Pack | `Packs/default/clips` | 23 clipes: idle, walk, run, crouch, jump, fall, land, climb, hang, hang-move, carried, wave, think, work, await, alert, error, look, recoil, yawn, sit, sleep, stand-up |
| Corpo | `GlyphBody` | `SystemWorldReader` (CGWindowList + NSScreen, notch por `safeAreaInsets`), `CursorMonitor` (monitores de `.mouseMoved`, sem permissão), `BodyController` (display link do macOS 14 com taxa pedida pelo motor, pausa em casa, teto de 12 fps em modo de economia) |

## Aceite

| Critério | Estado |
|---|---|
| Fechar a janela onde ele está → cai e pousa na de baixo, ou no Dock | ✅ testado (`EngineTests`, `PhysicsTests`) |
| Arrastar a janela → ele vai junto | ✅ testado |
| Maximizar → ele corre para não ser empurrado | ✅ testado (a própria janela e outra por cima) |
| Zero permissões pedidas | ✅ por construção: CGWindowList sem títulos, monitor global só de mouse, entitlements vazios. ⚠️ não verificado num Mac |
| CPU < 2% em repouso, < 0,5% dormindo, 0 fps oculto | ⚠️ parcial. O motor gasta ~0,03% de um núcleo (release, 10 min simulados em 0,17 s). O motor pede 12 fps em repouso, 6 dormindo e 0 em casa, e o display link pausa. O custo do Core Animation só dá para medir num Mac |
| O GIF do README | ❌ precisa de um Mac |

`swift test`: **112 testes** verdes em Linux (Swift 6.1.3).

## Não compilado (precisa de macOS)

Tudo em `Sources/GlyphBody/` e `Sources/GlyphApp/`. Pontos de atenção:

- `NSView.displayLink(target:selector:)` (macOS 14) com `@objc` num `NSObject` `@MainActor`.
- `CGWindowListCopyWindowInfo` convertido com `as? [[String: Any]]`.
- `auxiliaryTopLeftArea`/`RightArea`: só a largura é usada; a notch é centralizada.
- Monitores de evento chamam `MainActor.assumeIsolated`.
- A sombra do adesivo fica na camada que agrupa o desenho, o que força uma
  passada fora da tela por quadro. Se a CPU em repouso passar de 2%, este é o
  primeiro suspeito (trocar por `shadowPath` ou por um traço cinza deslocado).

## Decisões tomadas sozinho

1. **Teto andável = pendurado.** A "barra de menu, teto andável" virou uma
   superfície onde ele anda de mão em mão por baixo; a casa fica nela, sob a
   notch. Para chegar lá ele escala a borda da tela ou pula de uma janela alta.
2. **Bordas de tela são escaláveis e sólidas.** Garante que a casa é sempre
   alcançável.
3. **Plataforma exige espaço para o corpo em pé.** Janela maximizada não tem
   topo andável (encostaria na barra de menu).
4. **Maximizar:** quando a janela onde ele está cresce por cima dele (ou outra
   cobre o ponto), ele não é levado para o topo novo. Fica "engolido" e corre
   (320 pt/s) até sair do retângulo; aí cai.
5. **Andar de um trecho visível para um coberto é sair da borda** (cai).
   Ficar em pé sobre um trecho coberto só acontece se a cobertura chegou depois.
6. **Line boil a ~8 Hz** (a cada 3 quadros de 24 Hz), independente do fps de
   desenho.
7. **Clique** mostra a bolha local *e* manda `input.summon` ao cérebro.
8. **Dormir** só no chão: pendurado no teto sem objetivo, ele vai passear.
9. **Leitura do mundo a 10 Hz por timer**, que também mantém o relógio do
   motor andando quando o display link está pausado (em casa).
10. **Pack procurado** em `GLYPH_PACK`, depois em `Glyph.app/Contents/Resources/Pack`,
    depois subindo a partir do executável (para `swift run Glyph`).

## Faltando no M1

- Validar no Mac: compilar, rodar, medir CPU, gravar o GIF.
- `AXObserver` opcional para arrasto suave (precisa de Acessibilidade; opt-in).
- Desenho da casa (porta, cabeça para fora) e do painel da casa (duplo clique
  hoje só gera o evento `openHome`).
- Janela de aprovação em forma de cartão (hoje é bolha + pose `await`): é M3.

---

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
