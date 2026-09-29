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

## Prévia

`Examples/pack-exemplo/` é um pack completo. O `swift run glyph-art` gera
a prévia animada dos clipes dele em `Examples/pack-exemplo/previa/`.
