# Proposta 0001 — Runner remoto

- Estado: **proposta, aguardando revisão humana**
- Data: 2026-09-29
- Mexe em: fronteira de confiança, escada de confiança (regra 11 do plano)

Nada aqui está implementado.

## Problema

O turno noturno roda no Mac do usuário. Tarefas longas (build pesado,
suíte de testes lenta) poderiam rodar numa máquina remota, com o Mac
fechado.

## Proposta

1. O `glyphd` continua o único que decide. O runner remoto é uma
   **ferramenta** (`remote_run`), não um cérebro: recebe um comando dentro de
   um worktree `glyph/*` já empurrado para um remoto privado, roda e devolve
   a saída.
2. Classe: `external_effect` (sai da máquina). Com a escada atual, sempre
   pede. **Não** propomos teto maior.
3. O runner não recebe chaves de API, Keychain nem a casa. Recebe só o ramo
   e o comando.
4. Saída do runner entra como conteúdo observado.
5. Orçamento próprio (minutos de máquina) somado ao da tarefa.
6. Autenticação: chave por runner, criada com `glyphd runner parear`,
   guardada no Keychain, revogável.

## Perguntas para quem revisar

- Aceitar que `remote_run` fique em `external_effect` para sempre, ou
  permitir `always` com escopo de repositório + prazo (como as outras
  regras)?
- Quem hospeda o runner é problema do usuário, ou o projeto documenta um?
- O remoto privado do worktree precisa ser do usuário (GitHub) ou pode ser
  o próprio runner?

## Não faz parte

- Rodar o cérebro fora do Mac.
- Qualquer caminho em que o runner aja sem o `glyphd` pedir.
