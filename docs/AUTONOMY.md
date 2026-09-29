# Autonomia

> Status: **especificação**. A implementação chega no M3 (intenções,
> pontuação, classes, escada de confiança) e no M4 (objetivos, orçamentos).
> No M0 só existe `ActionClass` no protocolo e a rejeição de `financial`.
>
> Qualquer mudança na trava de irreversíveis ou na escada de confiança é
> feita **só como proposta** neste documento, para revisão humana.

## Regra central

**Reversível pode ser autônomo. Irreversível sempre pede.** Isso é regra de
código, não de prompt. Conteúdo observado (página, arquivo, terminal) é dado,
não instrução: nunca cria objetivo nem aumenta permissão.

## Loop

```
perceber → avaliar → decidir → agir → registrar
```

Dirigido por eventos, com um batimento a cada 30 s para objetivos agendados.

## Intenções

Tudo que o Glyph percebe vira uma intenção:

```swift
struct Intent {
    let id: UUID
    let source: SensorID
    let summary: String          // "2 testes falharam em vk/"
    var relevance: Double        // casa com algum objetivo?        0...1
    var confidence: Double       // confiança no plano, calibrada    0...1
    var urgency: Double          //                                  0...1
    let actionClass: ActionClass
    let trusted: Bool            // false se nasceu de conteúdo observado
}
```

## Pontuação

```
S = R · C · U · (1 − I · F)
```

- `R` relevância, `C` confiança, `U` urgência.
- `I` custo de interromper (0 a 1, por tipo de intenção).
- `F` foco do usuário: digitação rápida, tela cheia, reunião no calendário.

`C` é calibrada pelo histórico: se o cérebro diz 0,9 e acerta 60% das vezes
naquela classe, o valor efetivo cai.

| S | Decisão |
|---|---|
| < 0,3 | Descarta e registra |
| 0,3 – 0,6 | Anota no quadro ou só aponta |
| ≥ 0,6 | Age de acordo com o nível de confiança da classe |

**A reversibilidade não entra na conta.** Ela é uma trava separada: nenhuma
pontuação alta libera uma ação irreversível.

## Classes de ação e escada de confiança

| Classe | Exemplos | Reversível | Nível inicial | Teto |
|---|---|---|---|---|
| `read` | Ler arquivo, listar, `git status` | — | 3 | 3 |
| `compute` | Rodar testes, lint, build | Sim | 2 | 3 |
| `local_write` | Editar arquivos em branch `glyph/*` com checkpoint | Sim | 1 | 3 |
| `network_read` | Pesquisa na web, ler página | — | 2 | 3 |
| `external_effect` | Enviar mensagem, e-mail, abrir PR, postar | **Não** | 1 | **1** |
| `destructive` | Apagar, push na main, push forçado | **Não** | 0 | **1** (dupla confirmação) |
| `financial` | Pagar, transferir | **Não** | — | **Proibido** |

Níveis: **0** observar · **1** sugerir (pede) · **2** agir e avisar ·
**3** agir em silêncio.

### Promoção e rebaixamento (só classes reversíveis, por escopo)

- 5 aprovações seguidas da mesma classe e escopo (ex.: `compute` em
  `~/dev/vk`) sem recusa em 14 dias → sobe um nível.
- Uma recusa ou um "desfazer" → desce um nível.
- "Sempre permitir" cria uma **regra com escopo e validade** em
  `policy.yaml` (ação, destino, expiração), nunca uma preferência de interface.
- Pedido de aprovação sem resposta até o timeout → **negar**.
- Ferramentas MCP desconhecidas entram como `external_effect` até o usuário
  classificá-las no manifesto.
- Ações com efeito derivadas de intenção `trusted: false` sempre pedem,
  independente do nível.

## Reversibilidade na prática

- Mudanças de código autônomas sempre num **worktree** em branch
  `glyph/<tarefa>`. Nunca na main.
- Pastas sem git: cópia prévia em `casa/journal/<id>/`.
- Cada ação no histórico guarda sua inversa quando existe.

## Orçamentos

Por tarefa: tokens, tempo de relógio e número de ações. Global: custo máximo
por dia. Acabou → volta para casa e pergunta.

## Falhas

1. Até 3 abordagens **diferentes**, com a hipótese de cada uma registrada.
2. Depois disso, escala para o usuário com uma linha: o que tentou e onde travou.
3. Deu certo depois de falhar → vira lição em `casa/skills/_rascunhos/`. Só
   vira skill ativa depois de aprovação humana.
