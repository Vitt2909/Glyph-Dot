# Animação e estilo sticker

O visual é o que vende o projeto. O Glyph parece **um pequeno desenho que
ganhou vida**, colado na tela como um adesivo.

## Regras de estilo

1. **Esqueleto procedural:** cabeça (círculo), tronco, dois braços e duas
   pernas (dois segmentos cada) e o Dot. Nada de sprites.
2. **Adesivo recortado:** traço preto de 2,5 pt com pontas arredondadas por
   cima de um contorno branco de 3 pt por lado (traço branco de 8,5 pt), mais
   uma sombra curta e suave. A cabeça é preenchida de branco (o "papel").
3. **Line boil:** a cada 3 quadros (contados a 24 Hz, ou seja ~8 vezes por
   segundo), cada ponto do traço recebe um deslocamento de ±0,6 pt com semente
   fixa. Os traços são subdivididos a
   cada ~4 pt antes, para o boil não ficar só nas juntas.
4. **Animação "em dois":** a física roda a 60 Hz; a pose é amostrada a 12 fps.
5. **Princípios:** antecipação antes do pulo, squash & stretch no pouso,
   overshoot ao parar, cabeça segue o cursor antes do corpo.
6. **Olhos só quando expressam:** dois traços curtos para olhar, piscar ou
   estranhar. Somem em repouso.
7. **Ícones internos são stickers desenhados**, nunca emoji do sistema.
   `!` e `z z z` são traços, não texto.

Números em `StickerStyle` (`Sources/GlyphCore/Animation/StickerStyle.swift`).

## Esqueleto

Coordenadas locais: origem entre os pés, no chão, y para cima. O Glyph tem
~40 pt de altura (`SkeletonMetrics`).

| Canal | Significado |
|---|---|
| `torso` | Inclinação do tronco a partir da vertical (graus, anti-horário) |
| `head` | Inclinação da cabeça relativa ao tronco |
| `armL.upper`, `armR.upper`, `legL.upper`, `legR.upper` | Ângulo do segmento superior: **0 aponta para baixo**, positivo gira no sentido anti-horário (para +x na tela) |
| `armL.lower`, `armR.lower`, `legL.lower`, `legR.lower` | Ângulo do segmento inferior **relativo** ao superior |
| `root.dy` | Deslocamento vertical do quadril em pt (agachar < 0) |
| `stretch` | Squash & stretch: 1 neutro, < 1 amassa, > 1 estica (preserva área) |

Lados são anatômicos: com o Glyph de frente para você, `armR` fica à sua
esquerda. Levantar o braço direito para fora é um ângulo **negativo**
(`armR.upper: -150` = mão lá em cima). Quando o Glyph anda para a esquerda, o
desenho inteiro é espelhado (`facing = -1`); os clipes não precisam de versão
espelhada.

Canais ausentes valem a pose de repouso (`Pose.rest`).

## Formato de clipe

Um arquivo JSON por clipe em `Packs/<pack>/clips/`:

```json
{
  "id": "wave",
  "fps": 12,
  "loop": false,
  "keys": [
    { "t": 0.00, "ease": "out", "pose": { "armR.upper": -20, "armR.lower": -10 } },
    { "t": 0.25, "ease": "inOut", "pose": { "armR.upper": -150, "armR.lower": -30 } },
    { "t": 0.50, "ease": "inOut", "pose": { "armR.upper": -150, "armR.lower": 20 } },
    { "t": 0.75, "ease": "in", "pose": { "armR.upper": -20, "armR.lower": -10 } }
  ],
  "dot": { "mode": "pulse", "speed": 1.5 }
}
```

| Campo | Obrigatório | Descrição |
|---|---|---|
| `id` | sim | Igual ao nome do arquivo, `[a-z0-9-]+` |
| `fps` | não (12) | Taxa de amostragem da pose. 12 é o padrão "em dois" |
| `loop` | não (false) | Repete ao chegar ao fim |
| `keys` | sim | Pelo menos uma chave, `t` em segundos, crescente |
| `keys[].ease` | não (`linear`) | Curva **até a próxima chave**: `linear`, `in`, `out`, `inOut`, `step` |
| `keys[].pose` | sim | Canais da tabela acima. Canais ausentes herdam o repouso |
| `dot.mode` | não | Um dos modos do Dot (abaixo) |
| `dot.speed` | não (1) | Multiplicador de velocidade do modo |

A duração do clipe é o `t` da última chave. Em clipes com `loop`, a última
chave interpola de volta para a primeira no mesmo intervalo da primeira à
segunda.

Por cima do clipe o motor aplica camadas procedurais: IK dos pés na
plataforma, look-at da cabeça para o cursor ou para a janela de interesse, e
respiração.

## Modos do Dot

O Dot muda de **comportamento**, não de cor.

| Estado | `mode` | Comportamento |
|---|---|---|
| Repouso | `steady` | Brilho estável, respira a 0,25 Hz |
| Observando | `glance` | Pequenos deslocamentos na direção do evento |
| Pensando | `orbit` | Sai da cabeça e orbita. Nº de partículas ≈ log₂ dos passos planejados |
| Trabalhando | `trail` | Rastro de pontos até a janela alvo |
| Esperando aprovação | `blink` | Pisca 2× e para |
| Perigo | `alert` | `!` acima da cabeça |
| Erro | `shrink` | Encolhe um pouco |
| Dormindo | `fade` | Esmaece, `z z z` |
| Multi-Glyph | `split` | Um ponto se separa e vira outro Glyph |
| Genérico | `pulse` | Pulsa em `speed` Hz |

## Como contribuir com um clipe

1. Crie `Packs/default/clips/<id>.json` seguindo o formato.
2. Rode `swift test`: o teste `PackTests` valida todos os clipes do pack.
3. Grave um GIF curto no PR. Arte em `Packs/` é licenciada em CC BY 4.0.
