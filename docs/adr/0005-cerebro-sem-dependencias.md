# 0005 — M2 sem dependências: HTTP direto, YAML próprio, posix_spawn

- Estado: aceita
- Data: 2026-09-29

## Contexto

O plano previa GRDB, swift-argument-parser e o MCP swift-sdk. O M2 precisa
de: chamar APIs de modelos, ler `config.yaml`, rodar comandos com timeout e
falar por socket Unix. A ADR 0004 exige ADR para cada dependência.

## Decisão

- **APIs de modelo por HTTP direto** (`URLSession`). Não existe SDK oficial
  da Anthropic em Swift; OpenAI e Ollama têm formatos simples. Os três
  adaptadores têm testes de formato com transporte falso.
- **`MiniYAML` próprio** no Core: o subconjunto que `config.yaml`,
  `goals.yaml` e `policy.yaml` usam. Âncoras, tags e multidocumento dão erro.
- **`posix_spawn` com grupo de processos próprio** para o `shell`, em vez de
  `Process`: o timeout mata a árvore inteira.
- **Socket Unix com `DispatchSource`** (`GlyphIPC`), sem SwiftNIO.
- **Argumentos do `glyphd` à mão.** São poucos comandos.

## Consequências

- Build sem rede e sem resolver pacotes; o CI de Linux cobre tudo.
- Mais código nosso para manter (YAML, spawn). Os dois têm testes.
- MCP (M3/M6) será implementado como cliente JSON-RPC por stdio próprio ou
  entrará com ADR própria.
