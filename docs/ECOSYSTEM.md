# Ecossistema (M6)

Como outros programas entram no Glyph sem furar as duas regras de sempre:
**o corpo nunca executa** e **só o `glyphd` age, sempre pela política**.

| Peça | O que pode | O que não pode | Liga como |
|---|---|---|---|
| Agente externo como cérebro | Pensar: ver a conversa e as ferramentas, pedir chamadas | Executar qualquer coisa, pular aprovação, ver as chaves do glyphd, falar com o corpo | `cerebro.principal.provider: externo` |
| Agente no socket | Animar o corpo: gesto, fala, ir a um ponto ou para casa | Pedir aprovação, mexer em tarefa, ver o mundo, usar sinais de segurança, falar com o freio puxado | `agentes_externos.corpo: true` |
| Servidor MCP | Oferecer ferramentas | Rodar sem aprovação: toda ferramenta nova é `external_effect` até o usuário declarar outra classe | seção `mcp:` |
| Pack da comunidade | Trazer clipes e stickers | Trazer código; trocar os sinais de segurança | pasta em `casa/packs/` |
| Mala | Levar objetivos, habilidades, memória, packs e config | Levar confiança, regras "sempre", histórico, diário, quadro ou chaves | `glyphd mala` |

## Agente externo como cérebro (`glyph-brain/1`)

O `glyphd` roda o agente como processo filho e fala com ele por stdin/stdout,
uma linha JSON por mensagem. O stderr do agente vai para `/dev/null`. O
processo roda num grupo próprio; parar o `glyphd` mata a árvore inteira.

```yaml
cerebro:
  principal:
    provider: externo
    nome: vk
    comando: [vk, --glyph-brain]   # ~ é expandido; nomes vão para o PATH
    timeout: 300                   # segundos por resposta
```

### Pedido (glyphd → agente)

```json
{"id":"r1","protocol":"glyph-brain/1","system":"…","type":"brain.request",
 "turns":[{"role":"user","text":"quanto está o dólar?"}],
 "tools":[{"name":"web_search","description":"…","input_schema":{"type":"object"}}]}
```

Os turnos são `user` (`text`), `assistant` (`text`, `tool_calls`) e
`tool_results` (`results`: `call_id`, `name`, `content`, `is_error`). O
conteúdo bruto de outro provedor nunca vai para o agente. Resultados de
ferramentas que leem o mundo chegam marcados como conteúdo observado.

### Resposta (agente → glyphd)

```json
{"type":"brain.reply","id":"r1","text":"","stop":"tool_use",
 "tool_calls":[{"id":"c1","name":"web_search","input":{"query":"dólar hoje"}}],
 "usage":{"input_tokens":812,"output_tokens":40},"model":"vk-1"}
```

- `id` igual ao do pedido. Linhas que não são JSON, ou de outro `id`, são
  ignoradas.
- `stop`: `done`, `tool_use`, `max_tokens` ou `refusal`. Sem `stop`, vale
  `tool_use` se houver chamadas, senão `done`.
- `input` precisa ser objeto. Chamada sem `name` é erro.
- Sem resposta no tempo, ou processo encerrado: erro de transporte; o
  próximo pedido sobe o agente de novo.

Cada chamada pedida passa pela mesma política de qualquer cérebro: escada
de confiança, trava de irreversíveis, orçamento. Um agente externo não tem
mais poder que o Claude, o OpenAI ou o Ollama.

Exemplo completo: `Examples/agentes/agente-eco.py` (só biblioteca padrão).

## Agentes no socket (Glyph Protocol)

Um agente pode conectar no `glyphd.sock` e mandar `hello` com
`"role":"brain"`. Com `agentes_externos.corpo: false` (padrão), a conexão
é fechada. Ligado, o agente vira **marionetista**:

- aceita: `body.emote`, `bubble.say` (no máximo 8 s), `body.goto` para um
  ponto ou para casa;
- recusa: `approval.request`, `task.update`, `agent.spawn`, `diary.ready`,
  `body.goto` para janela (janelas são do mundo observado, que o agente não
  vê), os clipes `await`/`error`/`alert`, os stickers `cartao`/`pausa`/
  `escudo` e os pontos `blink`/`alert`;
- limite de 5 mensagens a cada 2 s;
- com o freio puxado, nada passa;
- o agente não recebe nada do corpo além do `hello`.

Os sinais de segurança são do `glyphd`: quem vê o Glyph pedindo permissão
precisa poder confiar que é o `glyphd` pedindo.

Exemplo: `Examples/agentes/marionete.py`.

## MCP

Cliente por stdio (JSON-RPC 2.0, protocolo `2025-06-18`), implementado no
`GlyphDaemon` sem dependência (ADR 0006).

```yaml
mcp:
  - nome: arquivos
    comando: [npx, -y, "@modelcontextprotocol/server-filesystem", ~/Documentos]
    env:
      TOKEN: $MEU_TOKEN      # $NOME copia do ambiente do glyphd
    classes:
      read_text_file: read
      list_directory: read
    timeout: 60
```

- Nome visto pelo modelo: `mcp__<servidor>__<ferramenta>`.
- **Classe padrão: `external_effect`** (irreversível: sempre pede). Só o
  usuário, no `config.yaml`, declara outra. `readOnlyHint` e as outras dicas
  do servidor são ignoradas: vêm de quem não é o usuário.
- A saída entra como conteúdo observado (`trusted: false`).
- O Glyph não oferece `sampling`, `roots` nem `elicitation`: pedidos do
  servidor recebem "método não encontrado".
- Servidor que não responde no tempo é encerrado e sobe de novo no próximo
  uso. Servidor que falha ao iniciar vira uma linha no log; os outros sobem.
- `glyphd mcp` conecta, lista as ferramentas com a classe de cada uma e sai.

## Packs da comunidade

Veja `docs/PACKS.md`.

## Viagem entre dispositivos

### Mala (implementada)

```sh
glyphd mala exportar ~/glyph.mala.json    # no Mac antigo
glyphd mala importar ~/glyph.mala.json    # no Mac novo
```

Vai: `goals.yaml`, `config.yaml` (sem `pareados`), `skills/` (sem
`_rascunhos/`), `memoria/`, `packs/`. Fica: escada de confiança e regras
"sempre" (confiança se ganha de novo em cada máquina), histórico, diário,
quadro, worktrees e chaves (moram no Keychain). Importar nunca sobrescreve:
um arquivo que já existe ganha uma cópia `.da-mala` ao lado. Um
`goals.yaml` inválido não entra. Caminhos com `..`, ocultos ou fora da lista
são recusados.

A mala não é cifrada: não leve para onde você não levaria a pasta `casa/`.

### Glyph andando de um aparelho para outro (não implementado)

A ideia do plano (o Glyph sai pela borda da tela do Mac e aparece no
iPhone) precisa de um corpo em outro sistema e de um canal entre
aparelhos. Nenhum dos dois existe neste repositório. O desenho seguro, quando
chegar a hora:

- o `glyphd` continua um só, no Mac; outro aparelho é **só corpo** (desenha
  e aprova), nunca cérebro;
- pareamento explícito com código na tela, chave por aparelho, revogável;
- aprovação vinda de outro aparelho vale só para classes reversíveis, até
  uma proposta revisada por humano dizer o contrário (mexe na escada de
  confiança).

## Runner remoto (proposta)

Veja `docs/propostas/0001-runner-remoto.md`. Não implementado: mexe na
fronteira de confiança e precisa de revisão humana.
