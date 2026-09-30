// Carrosséis de divulgação do Glyph para o Instagram (1080×1350, 4:5).
//
//   node docs/divulgacao/instagram/gerar.mjs
//
// Cada carrossel é uma faixa contínua (o chão atravessa todos os slides) e o
// Glyph aparece em todos, fazendo alguma coisa. As poses não são desenhadas à
// mão: cada quadro sai das prévias que o próprio motor grava em
// docs/art/clips (swift run glyph-art), e a posição das mãos vem das mesmas
// contas do motor (docs/estudio/nucleo.js). Escreve carrossel-1.html e
// carrossel-2.html e, se o Playwright estiver disponível, os PNGs em png/.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../../..");
await import(path.join(ROOT, "docs/estudio/nucleo.js"));
await import(path.join(ROOT, "docs/estudio/padrao.js"));
const N = globalThis.GlyphNucleo;
const P = globalThis.GlyphPadrao;

const W = 1080, H = 1350, FLOOR = 1190;
const INK = "#111", PAPER = "#f4f1ea", MUTED = "#5c574e", LINE = "#c9c4b8", MARK = "#ffd166";

// ------------------------------------------------------------------ arte

const clipCache = new Map();
function clipFrames(id) {
  if (clipCache.has(id)) return clipCache.get(id);
  const svg = fs.readFileSync(path.join(ROOT, "docs/art/clips", `${id}.svg`), "utf8");
  const body = svg.slice(svg.indexOf('<g filter="url(#sticker-shadow)">'), svg.lastIndexOf("</svg>"))
    .replaceAll("url(#sticker-shadow)", "url(#gs)");
  const n = body.match(/values="([^"]*)"/)[1].split(";").length;
  const frames = [];
  for (let k = 0; k < n; k++) {
    frames.push(body.replace(/<path d="[^"]*"([^>]*)><animate attributeName="d"[^>]*values="([^"]*)"\/><\/path>/g,
      (_, attrs, vals) => `<path d="${vals.split(";")[k]}"${attrs}/>`));
  }
  clipCache.set(id, frames);
  return frames;
}

function stickerBody(id) {
  const svg = fs.readFileSync(path.join(ROOT, "Packs/default/stickers", `${id}.svg`), "utf8");
  return svg.slice(svg.indexOf("</defs>") + 7, svg.lastIndexOf("</svg>")).replaceAll("url(#sticker-shadow)", "url(#gs)");
}

/**
 * O Glyph no quadro `t` do clipe, com os pés em (x, y) e `s` px por unidade
 * da prévia (a prévia já é 1,5× o ponto do motor). Devolve o SVG e onde
 * ficaram mãos e cabeça, em px da faixa.
 */
function glyph(id, t, x, y = FLOOR, s = 5, { flip = false, hang = false, base = 117 } = {}) {
  const frames = clipFrames(id);
  const k = Math.floor(t * 12 + 1e-9) % frames.length;
  const sk = N.solve(N.sample(P.clips[id], k / 12));
  const u = 1.5 * s, f = flip ? -1 : 1;
  // Na prévia, os pés ficam em y = 117; pendurado, as mãos ficam na barra (y = 9).
  let top = y - base * s;
  if (hang) { top = y - 9 * s; y += Math.max(sk.handL.y, sk.handR.y) * u; }
  const at = (p) => ({ x: x + p.x * u * f, y: y - p.y * u });
  let g = frames[k];
  if (flip) g = `<g transform="translate(180 0) scale(-1 1)">${g}</g>`;
  const svg = `<svg x="${x - 90 * s}" y="${top}" width="${180 * s}" height="${144 * s}" viewBox="0 0 180 144" overflow="visible">${g}</svg>`;
  const hands = [at(sk.handL), at(sk.handR)];
  return {
    svg, head: at(sk.headCenter), headR: sk.headRadius * u,
    handL: hands[0], handR: hands[1],
    handFront: hands.sort((a, b) => (b.x - a.x) * f)[0],
    handTop: [...hands].sort((a, b) => a.y - b.y)[0],
  };
}

/** Sticker do pack padrão centrado em (x, y), com `size` px de lado. */
function sticker(id, x, y, size = 150, rot = 0) {
  return `<svg x="${x - size / 2}" y="${y - size / 2}" width="${size}" height="${size}" viewBox="0 0 48 48" overflow="visible"><g transform="rotate(${rot} 24 24) translate(24 24) scale(1.35) translate(-24 -24)">${stickerBody(id)}</g></svg>`;
}

/** O Dot solto, grande. */
const dot = (x, y, r = 30) => `<circle cx="${x}" cy="${y}" r="${r + 9}" fill="#fff" filter="url(#gs2)"/><circle cx="${x}" cy="${y}" r="${r}" fill="${INK}"/>`;

// ------------------------------------------------------------------ faixa

class Strip {
  constructor(n) { this.n = n; this.back = ""; this.front = ""; this.html = ""; this.bg = []; }
  slide(i, fn) { fn(new Slide(this, i)); }
}

class Slide {
  constructor(strip, i) { this.s = strip; this.i = i; this.ox = i * W; }
  X(x) { return this.ox + x; }
  html(h) { this.s.html += h; }
  back(h) { this.s.back += h; }
  front(h) { this.s.front += h; }
  bg(color) { this.s.bg.push([this.i, color]); }
  text(x, y, w, cls, content, style = "") {
    this.html(`<div class="${cls}" style="left:${this.X(x)}px;top:${y}px;width:${w}px;${style}">${content}</div>`);
  }
  glyph(id, t, x, y, s, opt) {
    const g = glyph(id, t, this.X(x), y, s, opt);
    this.front(g.svg);
    for (const k of ["head", "handL", "handR", "handFront", "handTop"]) g[k] = { x: g[k].x - this.ox, y: g[k].y };
    return g;
  }
  sticker(id, x, y, size, rot) { this.front(sticker(id, this.X(x), y, size, rot)); }
  /** Bolha de fala com a ponta em (x, y). `tail`: onde fica a ponta (0 esquerda … 1 direita). */
  bubble(text, x, y, tail = 0.5, cls = "") {
    this.html(`<div class="bubble ${cls}" style="left:${this.X(x)}px;top:${y}px;--tail:${tail}"><span>${text}</span></div>`);
  }
  /** Bloco do topo em fluxo: kicker, título e texto não se atropelam. */
  head(kicker, title, body = "", { w = 952, dark = false, xl = false, bodyW = w } = {}) {
    this.html(`<div class="head" style="left:${this.X(64)}px;width:${w}px"><div class="kicker${dark ? " dark" : ""}">${kicker}</div>`
      + `<div class="title${xl ? " xl" : ""}"${dark ? ' style="color:#f2efe8"' : ""}>${title}</div>`
      + (body ? `<div class="body${dark ? " dk" : ""}" style="width:${bodyW}px">${body}</div>` : "") + `</div>`);
  }
  chrome(total, { dark = false } = {}) {
    this.html(`<div class="brand${dark ? " dark" : ""}" style="left:${this.X(64)}px">glyph</div>`);
    this.html(`<div class="count${dark ? " dark" : ""}" style="left:${this.X(W - 64 - 200)}px">${String(this.i + 1).padStart(2, "0")} / ${String(total).padStart(2, "0")}</div>`);
  }
}

function page(title, strip) {
  const w = strip.n * W;
  const bgs = strip.bg.map(([i, c]) => `<rect x="${i * W}" y="0" width="${W}" height="${H}" fill="${c}"/>`).join("");
  return `<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><title>${title}</title>
<style>
  @font-face { font-family: "Nunito"; font-weight: 200 1000; src: url("fontes/nunito-latin.woff2") format("woff2"); }
  @font-face { font-family: "JetBrains Mono"; font-weight: 100 800; src: url("fontes/jetbrainsmono-latin.woff2") format("woff2"); }
  * { box-sizing: border-box; }
  html, body { margin: 0; background: ${PAPER}; }
  body { font-family: "Nunito", ui-rounded, system-ui, sans-serif; color: ${INK}; -webkit-font-smoothing: antialiased; }
  .strip { position: relative; width: ${w}px; height: ${H}px; overflow: hidden; }
  .strip > svg { position: absolute; left: 0; top: 0; }
  .strip > div { position: absolute; }
  .brand { top: 56px; font-weight: 900; font-size: 44px; letter-spacing: -1px; color: ${INK};
    -webkit-text-stroke: 10px #fff; paint-order: stroke fill; filter: drop-shadow(0 3px 3px rgba(0,0,0,.18)); }
  .count { top: 66px; width: 200px; text-align: right; font: 700 26px "JetBrains Mono", ui-monospace, monospace; color: ${MUTED}; }
  .kicker { font-weight: 800; font-size: 28px; letter-spacing: 4px; text-transform: uppercase; color: ${MUTED}; }
  .dark { color: #a8a295 !important; }
  .brand.dark { color: #f2efe8 !important; -webkit-text-stroke: 10px #1d1c1a; }
  .title { font-weight: 900; font-size: 92px; line-height: 1.0; letter-spacing: -2.5px; }
  .title.xl { font-size: 138px; letter-spacing: -4.5px; line-height: .95; }
  .body { font-weight: 700; font-size: 38px; line-height: 1.34; color: #2b2925; }
  .body b { font-weight: 900; color: ${INK}; }
  .small { font-weight: 700; font-size: 28px; line-height: 1.35; color: ${MUTED}; }
  .hl { background: linear-gradient(transparent 58%, ${MARK} 58%, ${MARK} 92%, transparent 92%); padding: 0 .08em; }
  .mono, code { font-family: "JetBrains Mono", ui-monospace, monospace; font-weight: 700; }
  .body.dk { color: #d8d3c8; } .body.dk b { color: #fff; }
  code { color: ${INK}; font-size: .86em; background: #fff; border: 3px solid ${INK}; border-radius: 12px; padding: 0 .3em; }
  .bubble { transform: translate(calc(var(--tail) * -100%), calc(-100% - 30px)); background: #fff; border: 5px solid ${INK};
    border-radius: 30px; padding: 16px 30px 18px; font-weight: 800; font-size: 40px; line-height: 1.15; white-space: nowrap;
    filter: drop-shadow(0 4px 4px rgba(0,0,0,.2)); }
  .bubble::before, .bubble::after { content: ""; position: absolute; left: calc(var(--tail) * 100%); top: 100%;
    border: solid transparent; transform: translateX(-50%); }
  .bubble::before { border-width: 30px 18px 0; border-top-color: ${INK}; }
  .bubble::after { border-width: 21px 12px 0; border-top-color: #fff; margin-top: -1px; }
  .bubble.sm { font-size: 34px; padding: 12px 24px 14px; }
  .bubble.r { transform: translate(calc(-100% - 30px), -50%); }
  .bubble.l { transform: translate(30px, -50%); }
  .bubble.r::before, .bubble.r::after, .bubble.l::before, .bubble.l::after { top: 50%; transform: translateY(-50%); }
  .bubble.r::before { left: 100%; border-width: 18px 0 18px 30px; border-color: transparent transparent transparent ${INK}; }
  .bubble.r::after { left: 100%; margin: 0 0 0 -1px; border-width: 12px 0 12px 21px; border-color: transparent transparent transparent #fff; }
  .bubble.l::before { left: auto; right: 100%; border-width: 18px 30px 18px 0; border-color: transparent ${INK} transparent transparent; }
  .bubble.l::after { left: auto; right: 100%; margin: 0 -1px 0 0; border-width: 12px 21px 12px 0; border-color: transparent #fff transparent transparent; }
  .head { top: 150px; }
  .head .kicker { margin-bottom: 26px; }
  .head .body { margin-top: 30px; }
  .card { background: #fff; border: 5px solid ${INK}; border-radius: 30px; padding: 30px 36px; filter: drop-shadow(0 6px 6px rgba(0,0,0,.18)); }
  .win { background: #fff; border: 5px solid ${INK}; border-radius: 24px; overflow: hidden; filter: drop-shadow(0 6px 6px rgba(0,0,0,.18)); }
  .win .bar { height: 58px; border-bottom: 5px solid ${INK}; display: flex; align-items: center; gap: 12px; padding: 0 22px; background: #e9e5dc; }
  .win .bar i { width: 18px; height: 18px; border-radius: 50%; border: 4px solid ${INK}; background: #fff; }
  .win .bar span { margin-left: 14px; font-weight: 800; font-size: 26px; color: ${MUTED}; }
  .win .in { padding: 26px 30px; }
  .term { background: #1d1c1a; color: #f2efe8; font: 700 30px/1.55 "JetBrains Mono", ui-monospace, monospace; }
  .term .bar { background: #2e2c29; border-bottom-color: ${INK}; }
  .term .bar span { color: #a8a295; }
  .ok { color: #7fd18a; } .bad { color: #ff8a7a; } .dim { color: #8f897c; }
  .chip { display: inline-block; background: #fff; border: 4px solid ${INK}; border-radius: 999px; padding: 8px 24px 10px;
    font-weight: 800; font-size: 32px; filter: drop-shadow(0 3px 3px rgba(0,0,0,.16)); white-space: nowrap; }
  .chip.ink { background: ${INK}; color: #fff; }
  .btn { display: inline-block; border: 4px solid ${INK}; border-radius: 16px; padding: 8px 26px 10px; font-weight: 900; font-size: 32px; }
  .btn.ink { background: ${INK}; color: #fff; }
  .list { margin: 0; padding: 0; list-style: none; }
  .list li { position: relative; padding-left: 58px; margin: 0 0 20px; }
  .list li::before { content: ""; position: absolute; left: 0; top: .28em; width: 30px; height: 30px; border-radius: 50%;
    background: ${INK}; box-shadow: 0 0 0 7px #fff, 0 3px 6px 7px rgba(0,0,0,.14); }
  .swipe { font-weight: 900; font-size: 34px; color: ${INK}; }
</style></head>
<body><div class="strip">
<svg width="${w}" height="${H}" viewBox="0 0 ${w} ${H}" xmlns="http://www.w3.org/2000/svg">
<defs>
  <filter id="gs" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="0.45" stdDeviation="0.45" flood-color="#000" flood-opacity="0.24"/></filter>
  <filter id="gs2" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="4" stdDeviation="4" flood-color="#000" flood-opacity="0.22"/></filter>
</defs>
<rect width="${w}" height="${H}" fill="${PAPER}"/>${bgs}
${strip.back}
</svg>
${strip.html}
<svg width="${w}" height="${H}" viewBox="0 0 ${w} ${H}" style="pointer-events:none" xmlns="http://www.w3.org/2000/svg">
${strip.front}
</svg>
</div></body></html>
`;
}

/** O chão contínuo, com buracos onde algum slide não quer chão. */
function floor(strip, from = 0, to = strip.n * W, y = FLOOR, color = LINE) {
  strip.back += `<path d="M${from} ${y}H${to}" stroke="${color}" stroke-width="7" stroke-linecap="round"/>`;
}

// ================================================================== carrossel 1 — como eu fui feito

function carrossel1() {
  const n = 9;
  const S = new Strip(n);
  floor(S, 40, n * W - 40);

  // 1 — capa: pendurado no sublinhado do título
  S.slide(0, (s) => {
    s.chrome(n);
    s.head("Carrossel 1 · bastidores", "Como eu<br>fui feito.", "", { xl: true });
    s.back(`<path d="M${s.X(64)} 540H${s.X(1016)}" stroke="${INK}" stroke-width="14" stroke-linecap="round"/>`);
    const g = s.glyph("hang", 0.5, 820, 540, 5, { hang: true });
    s.bubble("oi! deixa<br>que eu conto.", g.head.x - g.headR - 24, g.head.y, 0, "r");
    s.text(64, 790, 560, "body", "A história do <b>Glyph</b>, a criatura open source que vive no desktop do Mac. Contada por ele mesmo.");
    s.glyph("walk", 0.25, 150, FLOOR, 2.4);
    s.text(600, 1236, 416, "swipe", "arrasta →", "text-align:right");
  });

  // 2 — o Dot
  S.slide(1, (s) => {
    s.chrome(n);
    s.head("Capítulo 1 · o ponto", "Primeiro, eu era<br>só um <span class=\"hl\">ponto</span>.",
      "Antes de ter corpo, existia o <b>Dot</b>: o pontinho que pensa, orbita e esmaece. Ele muda de <b>comportamento</b>, nunca de cor.");
    const cx = 720, cy = 920;
    for (const [r, o] of [[115, 0.9], [180, 0.55], [245, 0.3]]) {
      s.back(`<circle cx="${s.X(cx)}" cy="${cy}" r="${r}" fill="none" stroke="${INK}" stroke-opacity="${o}" stroke-width="5" stroke-dasharray="4 18" stroke-linecap="round"/>`);
    }
    s.front(dot(s.X(cx), cy, 44));
    s.front(dot(s.X(cx + 128), cy - 56, 12));
    s.front(dot(s.X(cx - 196), cy + 108, 9));
    const g = s.glyph("point", 1.0, 230, FLOOR, 4.2);
    s.bubble("esse aí<br>era eu.", g.head.x + 70, g.head.y - g.headR - 40, 0.12, "sm");
  });

  // 3 — o esqueleto
  S.slide(2, (s) => {
    s.chrome(n);
    s.head("Capítulo 2 · o esqueleto", "Depois, ganhei<br>um esqueleto.",
      "<b>10 articulações.</b> Cada gesto é um clipe de poses, a 12 quadros por segundo.", { bodyW: 470 });
    const sk = N.solve(N.REST);
    const k = 13.5, ox = s.X(800), oy = 1150;
    const p = (q) => `${ox + q.x * k} ${oy - q.y * k}`;
    let bones = "";
    for (const line of sk.strokes) bones += `M${line.map(p).join("L")}`;
    s.back(`<path d="${bones}" fill="none" stroke="#fff" stroke-width="30" stroke-linecap="round" stroke-linejoin="round" filter="url(#gs2)"/>`);
    s.back(`<path d="${bones}" fill="none" stroke="${INK}" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>`);
    const hc = sk.headCenter;
    s.back(`<circle cx="${ox + hc.x * k}" cy="${oy - hc.y * k}" r="${sk.headRadius * k}" fill="#fff" stroke="${INK}" stroke-width="9"/>`);
    s.back(`<circle cx="${ox + hc.x * k}" cy="${oy - hc.y * k}" r="${2.6 * k * 0.55}" fill="${INK}"/>`);
    const labels = [
      ["cabeça", hc, 1, 0], ["cotovelo", sk.elbowL, 1, -18], ["quadril", sk.hip, 1, 22], ["pé", sk.footL, 1, 0],
      ["ombro", sk.shoulderR, -1, 0], ["mão", sk.handR, -1, 0], ["joelho", sk.kneeR, -1, 0],
    ];
    for (const [name, q, side, dy] of labels) {
      const x = ox + q.x * k, y = oy - q.y * k;
      if (name !== "cabeça") s.back(`<circle cx="${x}" cy="${y}" r="11" fill="#fff" stroke="${INK}" stroke-width="5"/>`);
      const lx = side > 0 ? ox + 150 : ox - 165;
      s.back(`<path d="M${x + side * 14} ${y}L${lx - side * 50} ${y}L${lx - side * 10} ${y + dy}" fill="none" stroke="${MUTED}" stroke-width="3" stroke-dasharray="2 8" stroke-linecap="round"/>`);
      s.back(`<text x="${lx}" y="${y + dy + 10}" text-anchor="${side > 0 ? "start" : "end"}" font-family="Nunito, sans-serif" font-weight="800" font-size="30" fill="${MUTED}">${name}</text>`);
    }
    const g = s.glyph("point", 1.0, 180, FLOOR, 3.4);
    s.bubble("eu, por<br>dentro.", g.head.x + 56, g.head.y - g.headR - 36, 0.12, "sm");
  });

  // 4 — line boil
  S.slide(3, (s) => {
    s.chrome(n);
    s.head("Capítulo 3 · o traço", "Meu traço treme<br><span class=\"hl\">de propósito</span>.",
      "A cada quadro, o contorno é redesenhado com um tremidinho: o <b>line boil</b>. Contorno branco e sombra dão o <b>estilo adesivo</b>.");
    const xs = [210, 540, 870];
    let last;
    xs.forEach((x, i) => {
      last = s.glyph("idle", i / 12, x, FLOOR, 4.6);
      s.text(x - 120, 1222, 240, "small", `quadro ${i + 1}`, "text-align:center");
    });
    s.bubble("viu? tremi.", last.head.x - 20, last.head.y - last.headR - 20, 0.7, "sm");
  });

  // 5 — três peças
  S.slide(4, (s) => {
    s.chrome(n);
    s.head("Capítulo 4 · a arquitetura", "Corpo, cérebro<br>e um protocolo.");
    const top = 650;
    const cards = [
      [64, "Corpo", "Glyph.app", "desenha e percebe janelas, Dock e cursor"],
      [396, "Protocolo", "JSON por linha", "qualquer agente pode ser o cérebro"],
      [728, "Cérebro", "glyphd", "o único que age, e sempre pela política"],
    ];
    for (const [x, t, sub, d] of cards) {
      s.text(x, top, 288, "card", `<div style="font-weight:900;font-size:42px">${t}</div><div class="mono" style="font-size:24px;color:${MUTED};margin:2px 0 14px">${sub}</div><div style="font-weight:700;font-size:30px;line-height:1.28">${d}</div>`, "padding:26px 26px;height:320px");
    }
    for (const x of [352, 684]) s.front(`<path d="M${s.X(x) + 8} ${top + 160}h28m-12 -12l12 12l-12 12" fill="none" stroke="${INK}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>`);
    // o Glyph em cima do cartão "Corpo", olhando para o cérebro
    s.glyph("look", 0.2, 210, top, 3.2);
    s.text(64, 1020, 700, "body", "Meu corpo <b>nunca executa nada</b>. Ele só desenha e repassa o que vê.");
    s.glyph("wave", 0.42, 930, FLOOR, 2.6, { flip: true });
  });

  // 6 — a regra
  S.slide(5, (s) => {
    s.chrome(n);
    s.head("Capítulo 5 · a regra", "Dá pra desfazer?<br>Eu faço. Não dá?<br><span class=\"hl\">Eu peço</span>.",
      "É regra de <b>código</b>, não de prompt. O que não tem volta vira um cartão que eu seguro. Sem resposta, a resposta é <b>não</b>.");
    const g = s.glyph("await", 0.3, 250, FLOOR, 4.6);
    const hx = g.handFront.x, hy = g.handFront.y;
    s.text(hx + 6, hy - 230, 540, "card", `<div style="font-weight:900;font-size:38px;line-height:1.15">Enviar este e-mail<br>para 40 pessoas?</div><div class="small" style="margin:10px 0 22px">isso não dá para desfazer</div><span class="btn">Não</span>&nbsp;&nbsp;<span class="btn ink">Enviar</span>`, "transform:rotate(-3deg)");
  });

  // 7 — marcos (escada)
  S.slide(6, (s) => {
    s.chrome(n);
    s.head("Capítulo 6 · os marcos", "Cresci degrau<br>por degrau.");
    const steps = ["fundação", "criatura", "cérebro", "autonomia", "turno noturno", "time", "ecossistema"];
    const sw = 136, x0 = 64, hOf = (i) => 230 + i * 48;
    steps.forEach((name, i) => {
      const x = x0 + i * sw, h = hOf(i);
      s.back(`<rect x="${s.X(x)}" y="${FLOOR - h}" width="${sw}" height="${h}" fill="#fff" stroke="${INK}" stroke-width="5" rx="6"/>`);
      s.back(`<text x="${s.X(x + sw / 2)}" y="${FLOOR - h + 46}" text-anchor="middle" font-family="JetBrains Mono, monospace" font-weight="700" font-size="32" fill="${INK}">M${i}</text>`);
      s.back(`<text transform="translate(${s.X(x + sw / 2 + 10)} ${FLOOR - 20}) rotate(-90)" font-family="Nunito, sans-serif" font-weight="800" font-size="28" fill="${MUTED}">${name}</text>`);
    });
    s.glyph("ta-da", 0.75, x0 + 6.5 * sw, FLOOR - hOf(6), 3.0);
    // e, no meio do caminho, pulando do M2 para o M3
    s.glyph("jump", 0.33, x0 + 2.55 * sw, FLOOR - hOf(2) - 60, 2.4);
  });

  // 8 — testes
  S.slide(7, (s) => {
    s.chrome(n);
    s.head("Capítulo 7 · a prova", "<span style=\"font-size:200px;letter-spacing:-8px;line-height:.9\">370</span><br>testes verdes.",
      "Tudo que dá pra testar mora no núcleo e roda a cada mudança. E <b>toda imagem deste carrossel saiu do meu próprio motor</b>.", { bodyW: 540 });
    s.text(660, 560, 356, "win term", `<div class="bar"><i></i><i></i><i></i><span>swift test</span></div><div class="in" style="font-size:26px"><span class="ok">✓</span> Física<br><span class="ok">✓</span> Navegação<br><span class="ok">✓</span> Política<br><span class="ok">✓</span> Ensaio<br><span class="ok">✓</span> Time<br><span class="dim">… 370 ok</span></div>`);
    const g = s.glyph("look", 0.2, 380, FLOOR, 3.6);
    s.sticker("lupa", g.handFront.x + 44, g.handFront.y - 26, 120, -20);
  });

  // 9 — CTA
  S.slide(8, (s) => {
    s.chrome(n);
    s.head("Fim da história (por enquanto)", "Sou open<br><span class=\"hl\">source</span>.",
      "Código <b>Apache-2.0</b>, arte <b>CC BY 4.0</b>. Vivo no macOS e ainda estou crescendo: dá pra contribuir com uma pose, um sticker ou um pack inteiro.", { xl: true });
    s.text(64, 760, 520, "body", "Quer ver o que eu sei fazer?<br><b>Carrossel 2 →</b>");
    s.text(64, 1236, 600, "swipe", "link na bio");
    const g = s.glyph("wave", 0.42, 800, FLOOR, 5);
    s.bubble("tchau!", g.head.x - 30, g.head.y - g.headR - 16, 0.8);
  });

  return S;
}

// ================================================================== carrossel 2 — o que eu faço

function carrossel2() {
  const n = 11;
  const S = new Strip(n);
  floor(S, 40, n * W - 40);

  // 1 — capa: em cima da janela do título
  S.slide(0, (s) => {
    s.chrome(n);
    s.text(64, 150, 952, "kicker", "Carrossel 2 · na prática");
    const top = 440;
    s.text(64, top, 952, "win", `<div class="bar"><i></i><i></i><i></i><span>glyph</span></div><div class="in" style="padding:40px 48px 50px"><div class="title xl">O que eu<br>faço por<br><span class="hl">você</span>.</div></div>`);
    const g = s.glyph("invite", 0.9, 720, top, 4.2);
    s.bubble("vem!", g.head.x + g.headR + 26, g.head.y, 0, "l");
    s.text(600, 1236, 416, "swipe", "arrasta →", "text-align:right");
  });

  // 2 — pergunte
  S.slide(1, (s) => {
    s.chrome(n);
    s.head("Chamado", "Pergunte.<br>Eu vou lá e <span class=\"hl\">descubro</span>.");
    s.text(64, 450, 952, "card", `<span class="mono" style="font-size:28px;color:${MUTED}">⌃⌥Espaço</span>&nbsp;&nbsp;<span style="font-weight:800;font-size:40px">quanto está o dólar hoje?</span>`, "border-radius:999px;padding:22px 40px");
    s.text(64, 610, 540, "body", "Eu penso (o Dot orbita), vou até o navegador, <b>pesquiso de verdade</b> e volto com a resposta numa bolha.");
    s.text(660, 620, 356, "win", `<div class="bar"><i></i><i></i><i></i><span>navegador</span></div><div class="in"><div style="height:18px;background:#e9e5dc;border-radius:9px;margin:4px 0 18px"></div><div style="height:18px;width:70%;background:#e9e5dc;border-radius:9px;margin-bottom:18px"></div><div style="height:18px;width:85%;background:#e9e5dc;border-radius:9px"></div></div>`);
    const g = s.glyph("think", 0.67, 840, FLOOR, 4.2);
    s.bubble("deixa eu ver…", g.head.x - g.headR - 40, g.head.y + 10, 0, "r sm");
  });

  // 3 — teste quebrou
  S.slide(2, (s) => {
    s.chrome(n);
    s.head("Autonomia", "Teste quebrou?<br>Já tô no <span class=\"hl\">terminal</span>.");
    const top = 700;
    s.text(64, top, 952, "win term", `<div class="bar"><i></i><i></i><i></i><span>~/dev/app — zsh</span></div><div class="in"><span class="dim">$</span> swift test<br><span class="ok">✓</span> 211 passaram<br><span class="bad">✗ ParserTests.testVazio</span><br><span class="dim">&nbsp;&nbsp;Parser.swift:42</span></div>`);
    const g = s.glyph("point", 1.0, 900, top, 3.1, { flip: true });
    s.bubble("quebrou aqui.", g.head.x - g.headR - 70, g.head.y + 20, 0, "r sm");
    s.text(64, 1030, 952, "body", "Rodo a bateria de novo sozinho e aponto o arquivo que quebrou. Rodar teste é reversível, então eu faço <b>sem perguntar</b>.");
  });

  // 4 — turno noturno (noite)
  S.slide(3, (s) => {
    s.bg("#1d1c1a");
    s.chrome(n, { dark: true });
    s.head("Turno noturno", `Você dorme.<br>Eu <span style="color:${MARK}">trabalho</span>.`,
      "Num ramo <code>glyph/*</code> separado (a main nunca é tocada), com orçamento e até <b>3 abordagens</b> diferentes.", { dark: true, bodyW: 700 });
    s.back(`<circle cx="${s.X(900)}" cy="330" r="64" fill="#f2efe8"/><circle cx="${s.X(930)}" cy="305" r="58" fill="#1d1c1a"/>`);
    for (const [x, y, r] of [[780, 250, 5], [990, 470, 4], [840, 520, 3], [1010, 200, 3], [720, 400, 3]]) s.back(`<circle cx="${s.X(x)}" cy="${y}" r="${r}" fill="#f2efe8"/>`);
    const tries = [["abordagem 1", "✗"], ["abordagem 2", "✗"], ["abordagem 3", "…"]];
    tries.forEach(([t, m], i) => s.text(64, 740 + i * 100, 420, "", `<span class="chip"${i < 2 ? ' style="opacity:.5"' : ""}>${t} <span class="mono" style="margin-left:8px">${m}</span></span>`));
    s.glyph("work", 0.25, 720, FLOOR, 4.6);
  });

  // 5 — diário da manhã
  S.slide(4, (s) => {
    s.chrome(n);
    s.head("De manhã", "De manhã, volto<br>com o <span class=\"hl\">diário</span>.");
    s.text(430, 480, 586, "card", `<div class="mono" style="font-size:24px;color:${MUTED};margin-bottom:14px">diario/2026-09-30.md</div><ul class="list" style="font-weight:800;font-size:36px"><li>feito</li><li>tentado sem sucesso</li><li>precisa de você</li><li style="margin:0">custos</li></ul>`, "transform:rotate(2deg)");
    const g = s.glyph("await", 0.3, 210, FLOOR, 4.6);
    s.sticker("diario", g.handFront.x + 44, g.handFront.y - 14, 150, 8);
    s.text(490, 900, 526, "body", "Se deu certo, faço commit no ramo e <b>peço pra publicar</b>. Se não deu, te conto numa linha.");
  });

  // 6 — modo ensaio
  S.slide(5, (s) => {
    s.chrome(n);
    s.head("Modo ensaio", "Eu mostro<br>antes de <span class=\"hl\">fazer</span>.");
    s.text(64, 450, 952, "card", `<div class="small" style="margin-bottom:8px">“organize meus Downloads”</div><div style="font-weight:900;font-size:46px;line-height:1.25">32 arquivos seriam movidos<br>4 nomes mudariam<br>3 casos precisam de você</div><div style="margin-top:24px"><span class="btn">Desfazer tudo</span>&nbsp;&nbsp;<span class="btn ink">Aplicar</span></div>`);
    s.text(64, 900, 540, "body", "Nunca apago nem sobrescrevo. Desfazer volta <b>o plano inteiro</b>.");
    const g = s.glyph("balance", 0.5, 820, FLOOR, 3.5);
    s.sticker("pasta", g.head.x, g.head.y - g.headR - 62, 150, -6);
  });

  // 7 — entregar arquivos
  S.slide(6, (s) => {
    s.chrome(n);
    s.head("Entregar arquivos", "Solte um arquivo<br><span class=\"hl\">em mim</span>.",
      "PDF, imagem ou pasta. Eu seguro e mostro o que dá pra fazer. Leio <b>só o que você entregou</b>.");
    const cx = 540;
    const g = s.glyph("ta-da", 0.75, cx, FLOOR, 4.2);
    s.sticker("folha", cx, g.handTop.y - 64, 160, 0);
    const chips = [["resumir", 90, 700], ["tarefas", 700, 700], ["comparar", 64, 880], ["explicar", 720, 880], ["duplicados", 64, 1060], ["organizar", 720, 1060]];
    for (const [t, x, y] of chips) s.text(x, y, 300, "", `<span class="chip">${t}</span>`);
  });

  // 8 — o time
  S.slide(7, (s) => {
    s.chrome(n);
    s.head("Multi-Glyph", "Tarefa grande?<br>Eu chamo o <span class=\"hl\">time</span>.",
      "O <b>Builder</b> muda o código. O <b>Auditor</b> confere testes e diff, com <b>veto</b>: só fica pronto quando ele aprova.");
    const a = s.glyph("work", 0.25, 220, FLOOR, 3.4);
    const g = s.glyph("whistle", 0.5, 540, FLOOR, 4.4);
    const b = s.glyph("look", 0.2, 860, FLOOR, 3.4, { flip: true });
    s.sticker("lupa", b.handFront.x - 30, b.handFront.y - 20, 110, 20);
    s.bubble("terminou?", g.head.x, g.head.y - g.headR - 16, 0.5, "sm");
    s.bubble("sim.", a.head.x, a.head.y - a.headR - 150, 0.3, "sm");
    s.bubble("não.", b.head.x, b.head.y - b.headR - 150, 0.7, "sm");
    s.text(a.head.x - 150, 1222, 300, "small", "Builder", "text-align:center");
    s.text(g.head.x - 150, 1222, 300, "small", "eu", "text-align:center");
    s.text(b.head.x - 150, 1222, 300, "small", "Auditor", "text-align:center");
  });

  // 9 — ensinar mostrando
  S.slide(8, (s) => {
    s.chrome(n);
    s.head("Ensinar mostrando", "Me mostre<br><span class=\"hl\">uma vez</span>.");
    s.text(64, 450, 640, "win term", `<div class="bar"><i></i><i></i><i></i><span>campo de chamada</span></div><div class="in" style="font-size:28px"><span class="dim">1</span> /ensinar relatorio<br><span class="dim">2</span> <span class="dim">(você faz no terminal)</span><br><span class="dim">3</span> /pronto<br><span class="dim">4</span> /aprovar relatorio<br><span class="dim">5</span> <span class="ok">/rotina relatorio</span></div>`);
    s.text(64, 880, 560, "body", "Da próxima vez, eu repito. Na primeira, <b>só ensaio</b>.");
    const g = s.glyph("await", 0.3, 840, FLOOR, 4.2, { flip: true });
    s.sticker("livro", g.handFront.x - 36, g.handFront.y - 20, 140, -8);
  });

  // 10 — freio
  S.slide(9, (s) => {
    s.chrome(n);
    s.head("Segurança", "Sempre com<br><span class=\"hl\">freio de mão</span>.");
    s.text(64, 470, 660, "body", `<ul class="list"><li><code>⌃⌥⌘.</code> me para na hora</li><li>tudo vai pro histórico, com desfazer</li><li>“por que você fez isso?” tem resposta registrada</li><li>local-first: sensor só se você ligar</li><li>silêncio por padrão</li></ul>`);
    const g = s.glyph("alert", 0.2, 870, FLOOR, 4.2);
    s.sticker("escudo", g.head.x, g.head.y - g.headR - 110, 170, 0);
  });

  // 11 — diversão + CTA
  S.slide(10, (s) => {
    s.chrome(n);
    s.head("Modo diversão", "E quando sobra<br>tempo… eu <span class=\"hl\">danço</span>.",
      "<code>/danca</code> <code>/robo</code> <code>/truque</code> <code>/estatua</code>");
    [[0.0, 190], [0.25, 410], [0.42, 630]].forEach(([t, x]) => s.glyph("groove", t, x, 900, 3.1));
    s.glyph("robot", 1.0, 870, 900, 3.1);
    s.back(`<path d="M${s.X(90)} 900H${s.X(990)}" stroke="${LINE}" stroke-width="7" stroke-linecap="round"/>`);
    s.text(64, 970, 952, "card", `<div style="font-weight:900;font-size:50px;line-height:1.1">Glyph · open source · macOS</div><div class="body" style="margin-top:8px">Código aberto no GitHub. <b>Link na bio.</b></div>`, "text-align:center");
  });

  return S;
}

// ------------------------------------------------------------------ saída

const out = [
  ["carrossel-1", "Glyph — como eu fui feito", carrossel1()],
  ["carrossel-2", "Glyph — o que eu faço por você", carrossel2()],
];
for (const [name, title, strip] of out) {
  fs.writeFileSync(path.join(HERE, `${name}.html`), page(title, strip));
  console.log(`ok docs/divulgacao/instagram/${name}.html`);
}

let chromium;
try {
  ({ chromium } = await import(process.env.PLAYWRIGHT || "playwright"));
} catch {
  console.log("Playwright não encontrado: só o HTML foi gerado (PLAYWRIGHT=/caminho/para/playwright/index.mjs para os PNGs).");
  process.exit(0);
}
const browser = await chromium.launch();
fs.mkdirSync(path.join(HERE, "png"), { recursive: true });
for (const [name, , strip] of out) {
  const pg = await browser.newPage({ viewport: { width: strip.n * W, height: H } });
  await pg.goto("file://" + path.join(HERE, `${name}.html`));
  await pg.evaluate(() => document.fonts.ready);
  await pg.waitForTimeout(300);
  for (let i = 0; i < strip.n; i++) {
    const file = path.join(HERE, "png", `${name}-${String(i + 1).padStart(2, "0")}.png`);
    await pg.screenshot({ path: file, clip: { x: i * W, y: 0, width: W, height: H } });
    console.log(`ok ${path.relative(ROOT, file)}`);
  }
  await pg.close();
}
await browser.close();
