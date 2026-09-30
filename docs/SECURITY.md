# Segurança

## Como reportar uma falha

**Não abra issue pública.** Use o reporte privado de vulnerabilidades do
GitHub (aba *Security* → *Report a vulnerability*) neste repositório. A
resposta inicial deve vir em até 7 dias.

Inclua: versão/commit, passos para reproduzir, impacto esperado.

## Modelo de ameaças

### O que protegemos

1. **A máquina do usuário** contra ações que ele não quis: apagar, publicar,
   pagar, enviar.
2. **Os dados do usuário**: memória da casa, chaves de API, conteúdo de
   arquivos e do terminal.
3. **A confiança**: o Glyph nunca finge ter feito algo, nunca esconde uma ação.

### Fronteiras

| Fronteira | Ameaça | Defesa |
|---|---|---|
| Socket corpo ↔ cérebro | Outro processo se passa pelo corpo e aprova ações | UID do par + assinatura do app via audit token; `approval.response` só aceito do app assinado (docs/PROTOCOL.md). Com Developer ID, a exigência é "assinado pela equipe X"; sem ele, só vale um cdhash pareado com `glyphd pair` |
| Socket corpo ↔ cérebro | Outro processo se passa pelo cérebro e pede aprovações falsas | Corpo só conecta ao socket do usuário, em pasta 0700; `approval.request` só aceito do `glyphd` |
| Conteúdo observado → cérebro | **Injeção de prompt** em página, arquivo, saída de terminal | Conteúdo observado entra como `trusted: false`; ações com efeito derivadas dele sempre pedem aprovação; nunca cria objetivo |
| Cérebro → mundo | Ação irreversível autônoma | Trava por classe em código (docs/AUTONOMY.md); `financial` proibida; `destructive` com dupla confirmação |
| Ferramentas MCP | Ferramenta desconhecida com efeito colateral; servidor que mente sobre ser só leitura | Entra como `external_effect` até o **usuário** classificar no `config.yaml`; dicas do servidor ignoradas; saída marcada como conteúdo observado; processo em grupo próprio, morto no timeout |
| Agente externo (cérebro) | Agente age por conta própria ou pula a aprovação | Ele só propõe chamadas por stdio; quem executa é o `AgentLoop`, pela política; não recebe chaves nem o `raw` de outros provedores |
| Agente externo (socket) | Agente finge ser o `glyphd` pedindo aprovação | Desligado por padrão; ligado, só `body.emote`/`bubble.say`/`body.goto`; sinais de segurança (clipes `await`/`error`/`alert`, stickers `cartao`/`pausa`/`escudo`, pontos `blink`/`alert`) bloqueados; mudo com o freio |
| Packs da comunidade | Pack com código, ou que disfarça um pedido de aprovação | Só JSON lido, com limite de tamanho; manifesto e licença obrigatórios; sinais de segurança não podem ser trocados; link simbólico não carrega |
| Mala (viagem) | Levar confiança para uma máquina onde ela não foi ganha | Escada, regras "sempre", histórico e chaves ficam; importar nunca sobrescreve |
| `shell` | Escalada, vazamento de ambiente | Sandbox: pastas permitidas, sem `sudo`, ambiente limpo, timeout |
| Disco | Vazamento de segredos | Chaves no Keychain; logs com redação de segredos; casa em 0700 |
| Arquivos entregues (drop) | Ler além do que você entregou; conteúdo mandar o Glyph agir | Concessão de leitura só dos caminhos soltos, por 10 min; o cérebro que lê não recebe ferramenta nenhuma e o conteúdo vai como dado observado; com cérebro na nuvem, a primeira entrega de cada tipo pede um cartão (recusa: nada sai) |
| Modo ensaio | Organizar pasta apagar ou sobrescrever | Só mover e renomear, dentro da pasta, nunca por link simbólico, nunca sobre arquivo existente; manifesto por arquivo; desfazer o plano inteiro; aprovar o plano não cobre irreversíveis (cada um pede o próprio cartão) |
| Rotinas ensinadas | Uma demonstração virar permissão; valor de parâmetro injetar shell | Rascunho só vale com aprovação explícita; primeira execução por conjunto de valores é ensaio; cada passo passa pela política; valores com sintaxe de shell recusados; `sudo` fica de fora |
| Memória de projetos | Guardar segredo ou conteúdo; memória virar instrução | Só metadados (ramo, commit, nomes de arquivos, códigos de saída, arquivo:linha); nunca saída de terminal nem texto de arquivo; o marcador não é enviado ao cérebro |
| Convivência e cenas | Personalidade ou pack mexer em permissão ou fingir um evento | `Coexistence` não conhece ferramentas nem política; cenas só tocam com `scene.cue` do `glyphd`, e sinais de segurança não entram em cena |
| Rede | Telemetria | Nenhuma telemetria. Nada sai da máquina sem o usuário escolher um cérebro na nuvem |

### Freio

Segurar a casa por 1 s ou o atalho global `⌃⌥⌘.` → pausa geral, cancela
tarefas, todos os Glyphs voltam para casa. (M3)

### Permissões do macOS

- M1: **nenhuma**. Limites de janela vêm do `CGWindowList` sem títulos;
  mouse vem de monitor global de `.mouseMoved`.
- Acessibilidade (arrasto suave de janelas) e sensores são opt-in e pedidos
  só quando a função é usada.
- APIs privadas são proibidas no projeto.

## Estado atual

| Defesa | Estado |
|---|---|
| Regras de remetente no protocolo | Implementado e testado (M0) |
| Rejeição de `financial` no protocolo | Implementado e testado (M0) |
| Socket autenticado (UID + assinatura/cdhash via audit token) | M2 ✅ |
| Corpo não verificado não aprova | M2 ✅ (testado) |
| Aprovação sem resposta → negada | M2 ✅ (testado) |
| `shell`: pastas permitidas, sem `sudo`, ambiente limpo, timeout do grupo, `sandbox-exec` no macOS | M2 ✅ |
| Conteúdo observado marcado; depois dele, até `compute` pede | M2 ✅ (testado) |
| `web_fetch` bloqueia localhost e redes privadas | M2 ✅ |
| Keychain, redação de logs | M2 ✅ |
| Trava de irreversíveis com escada de confiança | M3 ✅ |
| Freio global | M3 ✅ |
| Ferramentas MCP nascem `external_effect` | M6 ✅ (testado com servidor falso) |
| Agente externo só propõe; agente no socket só anima | M6 ✅ (testado) |
| Packs: só dado, sinais de segurança protegidos | M6 ✅ (testado) |
