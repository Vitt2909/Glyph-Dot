# Pack de exemplo: Festa

Um pack da comunidade mínimo, para copiar. Veja `docs/PACKS.md`.

```sh
glyphd packs validar Examples/pack-exemplo
cp -R Examples/pack-exemplo "$(glyphd paths | sed -n 's/^casa: *//p')/packs/festa"
```

Reabra o Glyph.app para carregar. Licença dos assets: CC0-1.0.
