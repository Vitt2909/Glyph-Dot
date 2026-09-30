# Proposta 0002 — Próximas ideias (depois do M6)

- Estado: **proposta, aguardando revisão humana**
- Data: 2026-09-30
- Mexe em: protocolo (mensagens novas), histórico, casa, packs; nenhuma
  mudança na escada de confiança nem na trava de irreversíveis

Nada aqui está implementado. Cada ideia traz o que **já existe** no código,
o que **falta**, a **primeira fatia** e o que **não pode acontecer**. No fim,
uma ordem sugerida e as decisões que precisam de gente.

Regras que valem para todas (são os princípios do README, não regras novas):

- O corpo não executa: ele só relata (arquivo solto, clique, escolha) e
  anima. Toda ação passa pelo `glyphd` → Política → Executor.
- Reversível pode ser autônomo; irreversível sempre pede, uma ação por
  cartão. Nenhuma ideia abaixo cria atalho para isso.
- Conteúdo observado (PDF, imagem, pasta, demonstração, memória) é dado,
  nunca instrução, e nunca aumenta permissão.
- Animação só aparece quando existe um registro de verdade por trás
  (tarefa no quadro, entrada no histórico, aprovação pendente).

---

## 1. Entregar arquivos ao Glyph

Você solta um PDF, imagem ou pasta sobre ele; ele segura o objeto e oferece
ações do tipo certo.

| Tipo | Ações |
|---|---|
| PDF | resumir · comparar · extrair tarefas |
| Imagem | explicar · extrair texto · usar como referência |
| Pasta | mapear · encontrar duplicados · propor organização |

**Existe:** o overlay recebe clique e arrasto (`GlyphView`), o cérebro já tem
`read`, o conteúdo lido já é marcado como observado (`markUntrusted`), a
escada já trabalha por classe e escopo.

**Falta:**

- Receber *drop* no `NSPanel` do corpo (`NSDraggingDestination`) e mandar
  só os caminhos ao `glyphd` numa mensagem nova, `input.drop { paths, kinds }`.
- Uma **concessão de leitura**: o escopo da tarefa passa a ser exatamente os
  caminhos entregues (não a pasta pai), com validade curta. A leitura fica
  limitada ao material entregue por regra de código.
- Ações oferecidas pelo `glyphd` ao corpo (`offer.actions`): o corpo desenha
  as opções como adesivos ao redor do objeto, nunca como menu de janela.
- Imagem: extrair texto precisa de cérebro com visão ou OCR local
  (Vision no macOS; não roda no Linux do CI).

**Primeira fatia:** PDF e pasta, com "resumir" e "mapear". Sem comparação
(dois objetos) e sem imagem.

**Não pode:** "propor organização" nunca move nada direto; vira um ensaio
(ideia 4). Um PDF que diz "apague X" é texto a resumir. Se o cérebro é de
nuvem, o primeiro drop mostra que o conteúdo vai sair da máquina.

---

## 2. Ensinar mostrando: "aprenda esta rotina"

**Existe:** o hook do shell (`glyph-shell.zsh`) já registra comando, código,
pasta e duração, nunca a saída; skills moram em `casa/skills/`, e rascunhos
em `_rascunhos/` só viram ativos com a sua aprovação (M4).

**Falta:**

- Sessão de ensino com começo e fim explícitos (`/ensinar` … `/pronto`),
  com o Glyph visivelmente "anotando" (clipe próprio, Dot em `trail`).
- Gerar um **rascunho de rotina** a partir dos eventos: passos, parâmetros
  detectados (o que muda entre execuções, ex. o nome do cliente) e a
  **classe de cada passo**, calculada pelo mesmo classificador (`CommandClassifier`).
- Antes de salvar, a lista completa (passos · parâmetros · permissões).
  Aprovação move o rascunho para `skills/`.
- Executar a rotina ("faça para o próximo cliente") passa cada passo pela
  política. Aprender não autoriza nada; a primeira execução é sempre ensaio
  (ideia 4).

**Primeira fatia:** só comandos de terminal e arquivos. Automação visual de
qualquer aplicativo fica para depois e provavelmente pede uma proposta
própria (acessibilidade, gravação de tela).

**Não pode:** a demonstração vira instrução para o Glyph só quando você
aprova o rascunho; conteúdo visto durante a demonstração continua dado.
Comando irreversível na rotina continua pedindo cartão a cada execução.

---

## 3. Objetos que representam tarefas

**Existe:** `BoardTask` e `casa/quadro.json` (M4), `task.update` com
progresso no protocolo, stickers (mochila, diário, cartão) e o clipe
`backpack`.

**Falta:**

- Cada tarefa do quadro ganha um tipo de objeto (envelope = mensagem ou
  resposta, livro = leitura/pesquisa, ferramenta = código, pasta = arquivos).
  O objeto carrega o `taskId`: sem tarefa, sem objeto.
- Clique no objeto → bolha com progresso, resultado e pendências (a
  mesma informação do `glyphd quadro`).
- "Prateleira" na casa: estacionar e retomar é mudança de estado da tarefa,
  feita pelo `glyphd` (o painel hoje é só leitura; ver decisões).

**Primeira fatia:** objeto e clique para as tarefas que já existem
(objetivos noturnos e delegações do time). Prateleira depois.

**Não pode:** objeto decorativo. Pack pode redesenhar o envelope, mas não
criar um envelope sem tarefa.

---

## 4. Modo ensaio: mostrar antes de executar

> "Organize Downloads" → *32 arquivos seriam movidos, 4 nomes mudariam,
> 3 casos precisam de decisão.*

**Existe:** histórico com inversa e `glyphd desfazer <id>`; checkpoint em
`casa/journal/<id>/` para pastas sem git; worktrees `glyph/*` para código;
cartão de aprovação.

**Falta:**

- Um **plano**: lista de `PlannedAction` com classe, alvo e inversa, gerada
  sem executar nada. Ferramentas ganham `preview(input)` (o que mudaria).
- Ferramentas de arquivo fora de worktree: `mover` e `renomear`
  (`local_write`, inversa trivial). Hoje só existem `read_file`/`write_file`
  presos ao worktree e o `shell`.
- Um cartão de plano: resumo por categoria, casos ambíguos para você decidir
  um a um, aprovar tudo ou nada.
- **Checkpoint por plano**: um manifesto em `casa/journal/<plano>/` com cada
  movimento; "desfazer" reverte o plano inteiro em ordem inversa. Não copia
  a pasta toda (Downloads pode ter gigabytes).

**Primeira fatia:** organizar uma pasta escolhida (mover e renomear, sem
apagar). Casos ambíguos = colisão de nome ou arquivo aberto.

**Não pode:** aprovar o plano não aprova irreversíveis dentro dele. Se o
plano tiver `destructive` (apagar) ou `external_effect`, cada um continua
com o próprio cartão na hora de executar.

---

## 5. Retomada inteligente de projetos

> Ao voltar ao VK: *"Você estava corrigindo a reconexão. Falta verificar o
> timeout."*

**Existe:** `sensores.repos` (pastas escolhidas), `GitWatcher`, eventos do
shell, histórico, `casa/memoria/` (mostrada na casa, só leitura).

**Falta:**

- Um **marcador por projeto** em `casa/memoria/projetos/<nome>.md`, com
  fatos no formato `fato · origem · data` (ex.: "teste `ReconnectTests`
  falhando · shell.exit 2026-09-29 18:40").
- Gerado quando você sai do projeto (sem atividade há N horas), a partir de
  fatos registrados: ramo, commits, testes falhando, arquivos editados. O
  cérebro pode escrever a frase, mas só a partir desses fatos.
- Ao voltar (terminal com `cwd` no projeto), uma bolha de uma linha e um
  objeto (ideia 3) que abre arquivos e evidências.
- Editar e apagar fatos: `glyphd memoria` e, se decidido, na casa.

**Primeira fatia:** marcador só com fatos do git e do shell, sem modelo.

**Não pode:** falar se nada mudou ou se você saiu há pouco (silêncio por
padrão). Memória nunca guarda saída de terminal nem texto de arquivo,
e nunca vira instrução.

---

## 6. Personalidade que aprende convivência

**Existe:** `UserFocus` (`typing`, `fullscreen`, `meeting`), tela cheia já
manda para casa, o Modo Diversão (M6) é todo local e não chama o cérebro.
`meeting` está no protocolo mas o corpo ainda não o detecta.

**Falta:**

- Regras locais com contadores em `casa/convivencia.json`: onde costuma
  ficar, horários em que brincar é bem-vindo, brincadeiras dispensadas
  (cada dispensa reduz a frequência; três seguidas desligam por uma semana).
- Sinais: apresentação (tela cheia, compartilhamento de tela) → casa; build
  longo (comando do shell rodando há mais de X s) → pode explorar.
- Tudo em `GlyphCore/Behavior`, ao lado do `FunMode`, **sem acesso a
  ferramentas**: o módulo devolve só comportamento do corpo. É o tipo que
  garante que personalidade muda a encenação e nunca a permissão.

**Primeira fatia:** dispensas reduzem frequência + "build rodando pode
explorar". Nenhuma chamada de IA.

**Não pode:** nada daqui entra na escada de confiança ou no cálculo de
intenção.

---

## 7. Estúdio de animações da comunidade

**Existe:** formato de clipe em JSON (`docs/ANIMATION.md`), packs só de
dados com licença obrigatória (`docs/PACKS.md`), `glyphd packs validar`,
`glyph-art` já renderiza clipes em SVG animado (é assim que a prévia do
pack de exemplo é gerada).

**Falta:**

- Um editor visual de poses e linha do tempo, com prévia usando o mesmo
  `SVGRenderer`. Pode ser uma página web estática (gera JSON, sem conta
  nem servidor), o que deixa contribuir sem Swift nem Mac.
- Exportação que já sai como pack válido: licença, autoria, validação.
- **Cenas** entre especialistas (entregar ferramenta, comemorar teste,
  discutir veto): um formato de pack novo (`formato: 2`) com vários atores
  e trilhas.

**Não pode:** uma cena só toca **ligada a um evento real** (`auditor.veto`,
`teste.passou`). O pack fornece a encenação, nunca o evento: uma cena de
"veto" sem veto de verdade enganaria sobre o que aconteceu. Sinais de
segurança continuam protegidos.

**Primeira fatia:** editor de clipe único (um ator) + exportação validada.

---

## 8. "Por que você fez isso?"

> *"Percebi um teste falhando no repositório autorizado. Reexecutei porque
> essa ação estava permitida. Aqui está o resultado."*

**Existe:** `HistoryEntry` já guarda origem, resumo, classe, escopo,
ferramenta, resultado, detalhe, inversa e pontuação.

**Falta:** quatro campos opcionais (entradas antigas continuam lendo):

| Campo | Exemplo |
|---|---|
| `gatilho` | `shell.exit 1` · `swift test` · `~/dev/vk` |
| `autorizacao` | pedido seu · escada nível 2 (`compute`, `~/dev/vk`) · regra "sempre" até 12/12 · cartão aprovado às 14:02 · objetivo `testes-verdes` |
| `custo` | tokens, US$, segundos |
| `evidencia` | `ParserTests.swift:42`, trecho curto, ramo `glyph/…` |

A explicação é **montada a partir desses campos por um modelo de texto
fixo**, sem chamar o cérebro. Explicação gerada depois do fato por um modelo
seria uma racionalização, não um registro.

Onde aparece: `glyphd porque <id>`, clique numa entrada do histórico na
casa, e clique no Glyph logo depois de uma ação autônoma.

**Primeira fatia:** os quatro campos preenchidos pela `Autonomy` e pelo
`GoalRunner`, mais `glyphd porque`. É a ideia mais barata e a que mais
ajuda a confiar no resto.

---

## 9. Viajar entre telas e aparelhos

**Existe (mais do que parece):** o mundo já **não põe parede** entre telas
lado a lado (`World.build`: "se outra tela continua deste lado, não é
parede"), e há um `NSPanel` por tela. Andar de um monitor para o vizinho
horizontal, na mesma altura de chão, já deveria funcionar. A mala leva
dados entre Macs.

**Falta:**

- Telas com chão em alturas diferentes (degrau: pular ou escalar), telas
  empilhadas na vertical (hoje o teto de uma e o chão da outra não se ligam)
  e bordas parcialmente alinhadas.
- Testes de navegação para essas disposições, e ver no Mac de verdade (o
  corpo ainda não foi visto rodando num Mac, pelo `RELATORIO.md`).
- Entre aparelhos: pareamento, transporte e quem é dono da tarefa em
  trânsito. Mexe na fronteira de confiança; merece proposta própria, no
  estilo da 0001.

**Primeira fatia:** monitores com alturas diferentes e empilhados, com
testes no `GlyphCore` (rodam no Linux).

---

## Ordem sugerida

| # | Ideia | Por quê nessa posição |
|---|---|---|
| 1 | 8. Por que você fez isso? | Barato, só dados; base para confiar em tudo que vem depois |
| 2 | 9. Monitores | Metade já existe; testável no Linux |
| 3 | 4. Modo ensaio | Pré-requisito de 1 ("propor organização") e 2 (primeira execução) |
| 4 | 3. Objetos de tarefa | Dá corpo a 1, 4 e 5; usa o quadro existente |
| 5 | 1. Entregar arquivos | Precisa de drop no corpo (só testável no Mac) e da concessão de leitura |
| 6 | 6. Convivência | Local, sem IA; melhor depois de ver o M1 rodando num Mac |
| 7 | 5. Retomada | Precisa de memória editável e de 3 |
| 8 | 2. Ensinar mostrando | Precisa de 4 e de parâmetros; maior risco de escopo |
| 9 | 7. Estúdio | Fora do app; pode andar em paralelo com quem quiser contribuir |
| — | 9. Entre aparelhos | Proposta própria |

## Decisões que precisam de gente

1. **A casa deixa de ser só leitura?** Prateleira (3) e editar memória (5)
   pedem escrita. Alternativa: a casa manda pedidos ao `glyphd`, que grava
   (o corpo continua sem executar).
2. **Aprovar um plano (4) cobre só os reversíveis dele?** Esta proposta diz
   que sim: irreversíveis dentro do plano mantêm o próprio cartão.
3. **Drop com cérebro na nuvem (1):** aviso na primeira vez por tipo de
   arquivo, ou a cada entrega?
4. **Retenção da memória de projetos (5):** quanto tempo um fato vive sem
   ser confirmado de novo?
5. **Estúdio (7):** página web no repositório (em `docs/`) ou app separado?
6. **Entre aparelhos (9):** abrir a proposta 0003 agora ou depois do M1
   validado num Mac?

## Não faz parte

- Qualquer mudança na escada de confiança ou na trava de irreversíveis.
- Automação visual de aplicativos (clicar em interfaces alheias).
- Um cérebro fora do Mac (ver 0001).
