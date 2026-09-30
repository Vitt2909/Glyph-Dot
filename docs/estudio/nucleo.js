// Núcleo do estúdio de animações do Glyph: as mesmas contas do motor em Swift
// (Sources/GlyphCore/Animation), para a prévia ser fiel. Sem dependências.
// Conferido contra o motor por Scripts/estudio-check.mjs.
//
// Script clássico (não módulo) para a página abrir direto do disco (file://).
(function () {
"use strict";

const JOINTS = [
  "torso", "head",
  "armL.upper", "armL.lower", "armR.upper", "armR.lower",
  "legL.upper", "legL.lower", "legR.upper", "legR.lower",
];
const CHANNELS = [...JOINTS, "root.dy", "stretch"];

const REST = {
  torso: 0, head: 0,
  "armL.upper": 24, "armL.lower": 8, "armR.upper": -24, "armR.lower": -8,
  "legL.upper": 13, "legL.lower": -6, "legR.upper": -13, "legR.lower": 6,
};

const METRICS = {
  legUpper: 9, legLower: 9, torso: 13, armUpper: 9, armLower: 9,
  headRadius: 6, neck: 1.5, shoulderAt: 0.85, shoulderSpread: 2.5, dotRadius: 2.6,
};

const EASES = ["linear", "in", "out", "inOut", "step"];
const DOT_MODES = ["steady", "glance", "orbit", "trail", "blink", "alert", "shrink", "fade", "split", "pulse"];
const PROTECTED_CLIPS = ["await", "error", "alert"];
const PROTECTED_STICKERS = ["cartao", "pausa", "escudo"];
const SCENE_EVENTS = ["auditor.veto", "auditor.aprovou", "teste.passou", "entrega.pronta", "rotina.aprovada"];
const SCENE_ACTORS = ["glyph", "builder", "researcher", "designer", "auditor"];

const rad = (d) => (d * Math.PI) / 180;
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

/** Valor de um canal numa pose (ausente = repouso; stretch neutro = 1). */
function channel(pose, k) {
  if (k in pose) return pose[k];
  if (k === "stretch") return 1;
  return REST[k] ?? 0;
}

function ease(name, t) {
  t = clamp(t, 0, 1);
  switch (name) {
    case "in": return t * t;
    case "out": return 1 - (1 - t) * (1 - t);
    case "inOut": return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
    case "step": return 0;
    default: return t;
  }
}

function lerpPose(a, b, t) {
  const out = {};
  for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
    const neutral = k === "stretch" ? 1 : (REST[k] ?? 0);
    const va = k in a ? a[k] : neutral, vb = k in b ? b[k] : neutral;
    out[k] = va + (vb - va) * t;
  }
  return out;
}

const withRest = (p) => ({ ...REST, ...p });

function duration(clip) {
  const keys = clip.keys || [];
  if (!keys.length) return 0;
  const last = keys[keys.length - 1].t;
  if (clip.loop && keys.length > 1) return last + (keys[1].t - keys[0].t);
  return last;
}

/** Pose no tempo t, amostrada em fps ("em dois"), como Clip.sample. */
function sample(clip, t, quantize = true) {
  const keys = clip.keys || [];
  if (!keys.length) return { ...REST };
  if (keys.length === 1) return withRest(keys[0].pose);
  let time = Math.max(t, 0);
  const fps = clip.fps || 12;
  if (quantize) time = Math.floor(time * fps + 1e-9) / fps;
  const d = duration(clip);
  if (clip.loop) {
    if (d > 0) time = time % d;
  } else if (time >= keys[keys.length - 1].t) {
    return withRest(keys[keys.length - 1].pose);
  }
  let a = keys[0], b = keys[1], span = keys[1].t - keys[0].t, local = time - keys[0].t;
  let i = -1;
  for (let j = 0; j < keys.length; j++) if (keys[j].t <= time) i = j;
  if (i >= 0) {
    a = keys[i];
    if (i + 1 < keys.length) { b = keys[i + 1]; span = b.t - a.t; }
    else { b = keys[0]; span = d - a.t; }
    local = time - a.t;
  }
  const u = ease(a.ease || "linear", span > 0 ? local / span : 1);
  return lerpPose(withRest(a.pose), withRest(b.pose), u);
}

const add = (p, q) => ({ x: p.x + q.x, y: p.y + q.y });
const mul = (p, s) => ({ x: p.x * s, y: p.y * s });
const rot = (p, a) => ({ x: p.x * Math.cos(a) - p.y * Math.sin(a), y: p.x * Math.sin(a) + p.y * Math.cos(a) });
const limbDir = (deg) => ({ x: Math.sin(rad(deg)), y: -Math.cos(rad(deg)) });

/** Pontos do esqueleto (origem entre os pés, y para cima), como ForwardKinematics.solve. */
function solve(pose, facing = 1, m = METRICS) {
  const c = (k) => channel(pose, k);
  const stretch = clamp(c("stretch"), 0.5, 1.6);
  const sx = 1 / Math.sqrt(stretch), sy = stretch;
  const hip = { x: 0, y: m.legUpper + m.legLower + c("root.dy") };
  const torsoDir = { x: -Math.sin(rad(c("torso"))), y: Math.cos(rad(c("torso"))) };
  const neck = add(hip, mul(torsoDir, m.torso));
  const shoulder = add(hip, mul(torsoDir, m.torso * m.shoulderAt));
  const headDir = rot(torsoDir, rad(c("head")));
  const headCenter = add(neck, mul(headDir, m.neck + m.headRadius));
  const limb = (root, up, low, l1, l2) => {
    const a = c(up);
    const mid = add(root, mul(limbDir(a), l1));
    return [mid, add(mid, mul(limbDir(a + c(low)), l2))];
  };
  const across = mul({ x: torsoDir.y, y: -torsoDir.x }, m.shoulderSpread);
  const shoulderL = add(shoulder, across), shoulderR = add(shoulder, mul(across, -1));
  const [elbowL, handL] = limb(shoulderL, "armL.upper", "armL.lower", m.armUpper, m.armLower);
  const [elbowR, handR] = limb(shoulderR, "armR.upper", "armR.lower", m.armUpper, m.armLower);
  const [kneeL, footL] = limb(hip, "legL.upper", "legL.lower", m.legUpper, m.legLower);
  const [kneeR, footR] = limb(hip, "legR.upper", "legR.lower", m.legUpper, m.legLower);
  const f = facing < 0 ? -1 : 1;
  const map = (p) => ({ x: p.x * sx * f, y: p.y * sy });
  const raw = { hip, neck, shoulder, shoulderL, shoulderR, headCenter, elbowL, handL, elbowR, handR, kneeL, footL, kneeR, footR };
  const out = {};
  for (const [k, v] of Object.entries(raw)) out[k] = map(v);
  out.headRadius = m.headRadius;
  out.strokes = [
    [out.hip, out.neck],
    [out.shoulder, out.shoulderL, out.elbowL, out.handL],
    [out.shoulder, out.shoulderR, out.elbowR, out.handR],
    [out.hip, out.kneeL, out.footL],
    [out.hip, out.kneeR, out.footR],
  ];
  return out;
}

// ---------------------------------------------------------------- validação

const ID = /^[a-z0-9-]+$/;
const TOKEN = /^[A-Za-z0-9_-]{1,64}$/;

/** Mesmas regras de Clip.validate. Devolve a lista de problemas. */
function validateClip(clip) {
  const out = [];
  if (!clip.id || !ID.test(clip.id)) out.push(`id inválido: use a-z, 0-9 e - (${clip.id || "vazio"})`);
  if (PROTECTED_CLIPS.includes(clip.id)) out.push(`${clip.id} é sinal de segurança: um pack não pode trocar`);
  const keys = clip.keys || [];
  if (!keys.length) out.push("o clipe precisa de pelo menos uma chave");
  if (keys.length && keys[0].t < 0) out.push("a primeira chave não pode ter t negativo");
  for (let i = 1; i < keys.length; i++) if (!(keys[i - 1].t < keys[i].t)) out.push(`chaves fora de ordem (t=${keys[i].t})`);
  const fps = clip.fps ?? 12;
  if (!(fps >= 1 && fps <= 60)) out.push("fps fora de 1…60");
  for (const k of keys) {
    for (const ch of Object.keys(k.pose || {})) if (!CHANNELS.includes(ch)) out.push(`canal desconhecido: ${ch}`);
    if (k.ease && !EASES.includes(k.ease)) out.push(`curva desconhecida: ${k.ease}`);
  }
  if (clip.dot && !DOT_MODES.includes(clip.dot.mode)) out.push(`modo do Dot desconhecido: ${clip.dot.mode}`);
  return out;
}

/** Mesmas regras de Scene.validate. */
function validateScene(scene) {
  const out = [];
  if (!scene.id || !ID.test(scene.id) || scene.id.length > 64) out.push(`id inválido: ${scene.id || "vazio"}`);
  if (!SCENE_EVENTS.includes(scene.event)) out.push("escolha um evento real");
  const beats = scene.beats || [];
  if (!beats.length || beats.length > 24) out.push("entre 1 e 24 batidas");
  for (const b of beats) {
    if (!SCENE_ACTORS.includes(b.actor)) out.push(`ator desconhecido: ${b.actor}`);
    if (!(b.at >= 0 && b.at <= 20)) out.push(`batida fora de 0…20 s (${b.at})`);
    if (PROTECTED_CLIPS.includes(b.clip)) out.push(`o clipe ${b.clip} é sinal de segurança`);
    if (!b.clip || !ID.test(b.clip)) out.push(`clipe inválido: ${b.clip || "vazio"}`);
    if (b.sticker && PROTECTED_STICKERS.includes(b.sticker)) out.push(`o sticker ${b.sticker} é sinal de segurança`);
    if (b.bubble && [...b.bubble].length > 40) out.push("bolha com mais de 40 caracteres");
  }
  return out;
}

/** Mesmas regras de PackManifest.validate (docs/PACKS.md). */
function validateManifest(m) {
  const out = [];
  if (!m.id || !TOKEN.test(m.id)) out.push("id do pack: letras, números, - e _ (até 64)");
  if (!m.nome || [...m.nome].length > 80) out.push("nome: de 1 a 80 caracteres");
  if (!m.autor || [...m.autor].length > 120) out.push("autoria: de 1 a 120 caracteres");
  if ((m.formato ?? 1) !== 1) out.push("formato: hoje só existe o 1");
  if (!m.licenca) out.push("a licença é obrigatória (SPDX, ex.: CC0-1.0)");
  if (!m.versao) out.push("falta a versão");
  return out;
}

/** O clipe como o motor lê: chaves com t arredondado, sem campos vazios. */
function clipJSON(clip) {
  const c = { id: clip.id, fps: clip.fps ?? 12, loop: !!clip.loop, keys: [] };
  for (const k of clip.keys) {
    const pose = {};
    for (const ch of CHANNELS) if (ch in k.pose) pose[ch] = Math.round(k.pose[ch] * 100) / 100;
    const key = { t: Math.round(k.t * 1000) / 1000 };
    if (k.ease && k.ease !== "linear") key.ease = k.ease;
    key.pose = pose;
    c.keys.push(key);
  }
  if (clip.dot && clip.dot.mode) c.dot = clip.dot.speed && clip.dot.speed !== 1 ? { mode: clip.dot.mode, speed: clip.dot.speed } : { mode: clip.dot.mode };
  return JSON.stringify(c, null, 2) + "\n";
}

// ---------------------------------------------------------------- zip (sem compressão)

const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(bytes) {
  let c = 0xffffffff;
  for (const b of bytes) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** ZIP "stored" com os arquivos dados ({caminho: texto}). */
function zip(files) {
  const enc = new TextEncoder();
  const parts = [], central = [];
  let offset = 0;
  const u16 = (v) => [v & 0xff, (v >> 8) & 0xff];
  const u32 = (v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >>> 24) & 0xff];
  for (const [name, text] of Object.entries(files)) {
    const data = enc.encode(text), fname = enc.encode(name), crc = crc32(data);
    const local = [0x50, 0x4b, 0x03, 0x04, ...u16(20), ...u16(0x0800), ...u16(0), ...u16(0), ...u16(0x21),
      ...u32(crc), ...u32(data.length), ...u32(data.length), ...u16(fname.length), ...u16(0)];
    parts.push(new Uint8Array(local), fname, data);
    central.push(new Uint8Array([0x50, 0x4b, 0x01, 0x02, ...u16(20), ...u16(20), ...u16(0x0800), ...u16(0), ...u16(0), ...u16(0x21),
      ...u32(crc), ...u32(data.length), ...u32(data.length), ...u16(fname.length), ...u16(0), ...u16(0), ...u16(0), ...u16(0),
      ...u32(0), ...u32(offset)]), fname);
    offset += local.length + fname.length + data.length;
  }
  const size = central.reduce((s, p) => s + p.length, 0);
  const n = Object.keys(files).length;
  const end = new Uint8Array([0x50, 0x4b, 0x05, 0x06, ...u16(0), ...u16(0), ...u16(n), ...u16(n), ...u32(size), ...u32(offset), ...u16(0)]);
  return new Blob([...parts, ...central, end], { type: "application/zip" });
}

globalThis.GlyphNucleo = {
  JOINTS, CHANNELS, REST, METRICS, EASES, DOT_MODES, PROTECTED_CLIPS, PROTECTED_STICKERS, SCENE_EVENTS, SCENE_ACTORS,
  channel, ease, lerpPose, duration, sample, solve, validateClip, validateScene, validateManifest, clipJSON, crc32, zip,
};
})();
