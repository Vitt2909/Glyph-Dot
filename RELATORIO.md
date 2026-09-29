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
