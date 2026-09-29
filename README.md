# Glyph

> Uma criatura-agente open source que vive no desktop do macOS.
> Parece um pequeno desenho que ganhou vida. Age sozinha no que é
> reversível e pede no que não é.

<!-- O GIF do M1 entra aqui. Ele é o marketing do projeto. -->

**Status:** em construção. Veja os [marcos](#marcos) e o [`RELATORIO.md`](RELATORIO.md).

"Glyph" é o projeto; "Dot" é o núcleo da criatura, o pontinho que pensa,
orbita e esmaece.

## Princípios

1. **O Glyph nunca parece uma janela com pernas.** Interface tradicional só dentro da casa.
2. **O corpo não executa.** Toda ação passa pelo `glyphd` → Política → Executor.
3. **Reversível pode ser autônomo. Irreversível sempre pede.** Regra de código, não de prompt.
4. **Silêncio por padrão.** Se nada mudou, ele não fala.
5. **Local-first.** Sensores são opt-in. Nada sai da máquina a menos que você escolha um cérebro na nuvem.
6. **Tudo que ele faz sozinho vai para o histórico**, com desfazer quando existir inversa.
7. **Conteúdo observado é dado, não instrução.** Texto de página, arquivo ou terminal nunca cria objetivo nem aumenta permissão.

## Como é feito

| Peça | O que é |
|---|---|
| **Corpo** (`Glyph.app`) | Overlay transparente que desenha a criatura e lê janelas, Dock, notch e cursor. Nunca executa nada |
| **Cérebro** (`glyphd`) | Daemon com o loop de autonomia, ferramentas, memória e política |
| **Protocolo** | JSON por linha num socket local. Qualquer agente pode ser o cérebro |

Detalhes em [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) e
[`docs/PROTOCOL.md`](docs/PROTOCOL.md).

## Rodando

Requisitos: Swift 6 (Linux ou macOS). O app precisa de macOS 14+ e Xcode 16+.

```sh
swift test                          # testes do GlyphCore (rodam em Linux)
swift run glyphd mock --fast        # o roteiro do cérebro falso, em JSON por linha

# só macOS
Scripts/bundle-app.sh               # monta build/Glyph.app
open build/Glyph.app                # o Glyph aparece em cima do Dock
GLYPH_MOCK=1 build/Glyph.app/Contents/MacOS/Glyph   # com o cérebro falso
```

Clique no Glyph para ele responder; clique com o botão direito para sair.
O app não pede nenhuma permissão.

## Instalação

Ainda não há binário assinado. Para o app abrir sem aviso do Gatekeeper é
preciso assinar com Developer ID e notarizar (conta Apple Developer paga).
Enquanto isso, compile pelo código-fonte como acima. Se usar um zip das
releases, o macOS vai avisar que o desenvolvedor não foi verificado.

## Marcos

- [x] **M0 — Fundação:** repositório, licenças, CI, protocolo v0, modo mock, Glyph parado.
- [ ] **M1 — A criatura muda:** overlay, mundo, física, pathfinding, estilo sticker completo. Sem IA.
- [ ] **M2 — Cérebro reativo:** `glyphd` como LaunchAgent, um cérebro, bolhas, `shell` e `web.search`.
- [ ] **M3 — Autonomia v1:** sensores, intenções, pontuação, escada de confiança, aprovações, freio.
- [ ] **M4 — Objetivos e turno noturno:** `goals.yaml`, orçamentos, worktrees, diário da manhã.
- [ ] **M5 — Multi-Glyph:** supervisor, Builder, Pesquisador, Auditor com veto.
- [ ] **M6 — Ecossistema:** agentes externos, packs da comunidade, viagem entre dispositivos.

## Contribuindo

Veja [`CONTRIBUTING.md`](CONTRIBUTING.md). Boas primeiras contribuições: uma
nova emoção, pose ou sticker em `Packs/default/`
([formato](docs/ANIMATION.md)).

Falhas de segurança: [`docs/SECURITY.md`](docs/SECURITY.md).

## Licenças

- Código: [Apache-2.0](LICENSE).
- Arte em `Packs/`: [CC BY 4.0](LICENSE-ASSETS).
