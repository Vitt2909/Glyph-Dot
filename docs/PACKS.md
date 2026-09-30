# Packs

Um pack é uma pasta com clipes e stickers do Glyph. **Só dado**: nada de
código, script, fonte ou rede. O carregador lê só `pack.json`,
`clips/*.json` e `stickers/*.json`; o resto é ignorado.

```
festa/
├── pack.json
├── clips/
│   └── danca.json
└── stickers/
    └── balao.json
```

## `pack.json`

```json
{
  "id": "festa",
  "nome": "Festa",
  "versao": "0.1.0",
  "autor": "Seu nome",
  "licenca": "CC0-1.0",
  "descricao": "Uma dança e um balão.",
  "formato": 1
}
```

- `id`: letras, números, `-` e `_`, até 64. Dois packs com o mesmo `id`: o
  segundo (em ordem alfabética de pasta) é ignorado.
- `licenca`: obrigatória. Use um identificador SPDX.
- `formato`: hoje, `1`.

## Clipes e stickers

Formato em `docs/ANIMATION.md` (clipes) e nos stickers do pack padrão
(`Packs/default/stickers/*.json`). O `id` precisa ser igual ao nome do
arquivo. Cada arquivo tem até 256 KB; cada pasta, até 200 arquivos.

Um pack pode **adicionar** clipes e stickers e **substituir** os do pack
padrão, menos os sinais de segurança:

| Tipo | Protegidos | Por quê |
|---|---|---|
| Clipes | `await`, `error`, `alert` | Esperando aprovação, erro e perigo precisam ser reconhecíveis em qualquer pack |
| Stickers | `cartao`, `pausa`, `escudo` | Cartão de aprovação, freio e o escudo do Auditor |

Um arquivo protegido no pack é ignorado com um aviso.

## Instalar

```sh
glyphd packs validar caminho/do/pack    # confere antes
cp -R caminho/do/pack "$(glyphd paths | sed -n 's/^casa: *//p')/packs/"
glyphd packs                            # lista o que está instalado
```

Reabra o Glyph.app. Pastas que são link simbólico não são carregadas: o
pack precisa morar dentro da casa.

## Cenas

Um pack pode trazer `scenes/*.json`: pequenas cenas entre o Glyph e os
especialistas, ligadas a um **evento real**. O pack fornece a encenação,
nunca o evento: a cena só toca quando o `glyphd` manda `scene.cue`.

```json
{
  "id": "veto-conversa",
  "event": "auditor.veto",
  "beats": [
    {"actor": "auditor", "at": 0, "clip": "point", "bubble": "olha isso."},
    {"actor": "builder", "at": 0.8, "clip": "look", "bubble": "hm."}
  ]
}
```

| Campo | Regra |
|---|---|
| `event` | `auditor.veto`, `auditor.aprovou`, `teste.passou`, `entrega.pronta`, `rotina.aprovada` |
| `beats[].actor` | `glyph` ou um papel (`builder`, `researcher`, `designer`, `auditor`). Especialista só atua se estiver mesmo em cena |
| `beats[].at` | 0…20 s; até 24 batidas |
| `beats[].clip` | Um clipe do pack ou do padrão; nunca `await`, `error`, `alert` |
| `beats[].bubble` | Até 40 caracteres |
| `beats[].sticker` | Nunca `cartao`, `pausa`, `escudo` |

Uma cena nunca toca por cima de um pedido de aprovação.

## Estúdio

`docs/estudio/index.html` abre direto no navegador (sem Swift, sem Mac):
poses por articulação, linha do tempo, prévia "em dois", cenas com
especialistas, e um `.zip` do pack pronto para `glyphd packs validar`. As
contas da prévia são as do motor (conferidas por
`node Scripts/estudio-check.mjs`).

## Prévia

`Examples/pack-exemplo/` é um pack completo. O `swift run glyph-art` gera
a prévia animada dos clipes dele em `Examples/pack-exemplo/previa/`.
