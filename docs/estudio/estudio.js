// Estúdio do Glyph: interface. As contas (cinemática, amostragem, validação,
// zip) ficam em nucleo.js; os clipes do pack padrão, em padrao.js.
(function () {
"use strict";
const N = globalThis.GlyphNucleo;
const P = globalThis.GlyphPadrao || { clips: {}, stickers: {} };
const $ = (id) => document.getElementById(id);
const STORE = "glyph-estudio-v1";

const LABELS = {
  torso: "tronco", head: "cabeça", "root.dy": "quadril ↕", stretch: "esticar",
  "armL.upper": "braço esq.", "armL.lower": "antebraço esq.", "armR.upper": "braço dir.", "armR.lower": "antebraço dir.",
  "legL.upper": "coxa esq.", "legL.lower": "canela esq.", "legR.upper": "coxa dir.", "legR.lower": "canela dir.",
};
const GROUPS = [
  ["corpo", ["torso", "head", "root.dy", "stretch"]],
  ["braço esquerdo (à direita da tela)", ["armL.upper", "armL.lower"]],
  ["braço direito", ["armR.upper", "armR.lower"]],
  ["perna esquerda", ["legL.upper", "legL.lower"]],
  ["perna direita", ["legR.upper", "legR.lower"]],
];
const RANGE = { "root.dy": [-12, 12, 0.5], stretch: [0.5, 1.6, 0.01] };

// ------------------------------------------------------------------ estado

function newClip() {
  return { id: "meu-clipe", fps: 12, loop: true, dot: { mode: "pulse", speed: 1 },
    keys: [{ t: 0, ease: "inOut", pose: {} }, { t: 0.5, ease: "inOut", pose: { "armR.upper": -150, "armR.lower": -20 } }] };
}
function newScene() {
  return { id: "minha-cena", event: "teste.passou", beats: [{ actor: "glyph", at: 0, clip: "ta-da", bubble: "passou!" }] };
}
function newPack() {
  return { manifest: { id: "meu-pack", nome: "Meu pack", versao: "0.1.0", autor: "", licenca: "CC0-1.0", descricao: "", formato: 1 },
    clips: {}, scenes: {} };
}

let state;
try { state = JSON.parse(localStorage.getItem(STORE) || "null"); } catch (_) { state = null; }
if (!state || !state.clip || !state.pack) state = { clip: newClip(), selected: 0, scene: newScene(), pack: newPack(), tab: "clipe" };
const save = () => { try { localStorage.setItem(STORE, JSON.stringify(state)); } catch (_) { /* sem armazenamento: tudo bem */ } };

let playing = false, playhead = 0, last = 0;

// ------------------------------------------------------------------ desenho

function figure(pose, { cx, ground, s, facing = 1, opacity = 1, dot = true }) {
  const sk = N.solve(pose, facing);
  const pt = (p) => `${(cx + p.x * s).toFixed(2)},${(ground - p.y * s).toFixed(2)}`;
  const path = sk.strokes.map((l) => "M" + l.map(pt).join("L")).join("");
  const hc = { x: cx + sk.headCenter.x * s, y: ground - sk.headCenter.y * s };
  const r = sk.headRadius * s;
  const ink = "var(--ink)";
  return `<g opacity="${opacity}" stroke-linecap="round" stroke-linejoin="round" fill="none">
    <path d="${path}" stroke="#fff" stroke-width="${(8.5 * s) / 5}"/>
    <circle cx="${hc.x}" cy="${hc.y}" r="${r}" fill="#fff" stroke="#fff" stroke-width="${(8.5 * s) / 5}"/>
    <path d="${path}" stroke="${ink}" stroke-width="${(2.5 * s) / 5}"/>
    <circle cx="${hc.x}" cy="${hc.y}" r="${r}" fill="#fff" stroke="${ink}" stroke-width="${(2.5 * s) / 5}"/>
    ${dot ? `<circle cx="${hc.x}" cy="${hc.y}" r="${N.METRICS.dotRadius * s}" fill="${ink}"/>` : ""}
  </g>`;
}

function drawPreview() {
  const c = state.clip;
  let pose, ghost = null;
  const k = c.keys[state.selected];
  if (playing) {
    pose = N.sample(c, playhead, $("twos").checked);
  } else if (k) {
    pose = { ...N.REST, ...k.pose };
    const prev = c.keys[state.selected - 1];
    if ($("onion").checked && prev) ghost = { ...N.REST, ...prev.pose };
  } else {
    pose = { ...N.REST };
  }
  const facing = $("mirror").checked ? -1 : 1;
  const g = { cx: 160, ground: 225, s: 5, facing };
  $("preview").innerHTML = `<line x1="30" x2="290" y1="225" y2="225" stroke="var(--line)" stroke-width="3" stroke-linecap="round"/>`
    + (ghost ? figure(ghost, { ...g, opacity: 0.18, dot: false }) : "") + figure(pose, g);
  const d = Math.max(N.duration(c), 0.001);
  const head = document.querySelector("#timeline .head");
  const t = playing ? playhead % d : (k ? k.t : 0);
  if (head) head.style.left = `${Math.min(t / d, 1) * 100}%`;
}

// ------------------------------------------------------------------ clipe

function renderTimeline() {
  const c = state.clip, tl = $("timeline");
  const d = Math.max(N.duration(c), 0.001);
  tl.querySelectorAll(".key, .head").forEach((e) => e.remove());
  c.keys.forEach((k, i) => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "key";
    b.style.left = `${Math.min(k.t / d, 1) * 100}%`;
    b.setAttribute("aria-label", `chave ${i + 1} em ${k.t} s`);
    if (i === state.selected) b.setAttribute("aria-current", "true");
    b.addEventListener("click", (e) => { e.stopPropagation(); select(i); });
    tl.appendChild(b);
  });
  const head = document.createElement("div");
  head.className = "head";
  tl.appendChild(head);
  $("dur").textContent = `${N.duration(c).toFixed(2)} s${c.loop ? " (volta)" : ""}`;
}

function renderSliders() {
  const box = $("sliders");
  box.innerHTML = "";
  const k = state.clip.keys[state.selected];
  for (const [group, chans] of GROUPS) {
    const h = document.createElement("div");
    h.className = "group";
    h.textContent = group;
    box.appendChild(h);
    for (const ch of chans) {
      const [min, max, step] = RANGE[ch] || [-180, 180, 1];
      const row = document.createElement("label");
      row.className = "slider" + (k && ch in k.pose ? " touched" : "");
      const val = k ? N.channel(k.pose, ch) : N.channel({}, ch);
      row.innerHTML = `<span>${LABELS[ch]}</span><input type="range" min="${min}" max="${max}" step="${step}" value="${val}" ${k ? "" : "disabled"}><output>${fmt(val)}</output>`;
      const input = row.querySelector("input"), out = row.querySelector("output");
      input.addEventListener("input", () => {
        const kk = state.clip.keys[state.selected];
        if (!kk) return;
        kk.pose[ch] = Number(input.value);
        out.textContent = fmt(kk.pose[ch]);
        row.classList.add("touched");
        playing = false; updatePlay();
        drawPreview(); validateClipUI(); save();
      });
      input.addEventListener("dblclick", () => {
        const kk = state.clip.keys[state.selected];
        if (!kk) return;
        delete kk.pose[ch];
        renderSliders(); drawPreview(); validateClipUI(); save();
      });
      box.appendChild(row);
    }
  }
}
const fmt = (v) => (Math.abs(v) < 10 && v % 1 ? v.toFixed(2) : String(Math.round(v * 10) / 10));

function renderClipFields() {
  const c = state.clip, k = c.keys[state.selected];
  $("clip-id").value = c.id;
  $("clip-fps").value = c.fps ?? 12;
  $("clip-loop").checked = !!c.loop;
  $("clip-dot").value = c.dot?.mode || "";
  $("clip-dot-speed").value = c.dot?.speed ?? 1;
  $("key-t").value = k ? k.t : "";
  $("key-ease").value = k ? (k.ease || "linear") : "linear";
  $("key-t").disabled = $("key-ease").disabled = !k;
}

function problemsUI(el, list, okText) {
  el.innerHTML = list.length ? `<ul class="problems">${list.map((p) => `<li>${esc(p)}</li>`).join("")}</ul>`
    : `<p class="ok">${okText}</p>`;
}
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function validateClipUI() {
  const list = N.validateClip(state.clip);
  if (P.clips[state.clip.id] && !list.length) list.unshift(`já existe um clipe padrão "${state.clip.id}": o seu vai substituí-lo no pack`);
  problemsUI($("clip-problems"), list, "o motor aceita este clipe.");
}

function select(i) {
  state.selected = Math.max(0, Math.min(i, state.clip.keys.length - 1));
  playing = false; updatePlay();
  renderTimeline(); renderSliders(); renderClipFields(); drawPreview(); save();
}

function sortKeys() {
  const cur = state.clip.keys[state.selected];
  state.clip.keys.sort((a, b) => a.t - b.t);
  state.selected = Math.max(0, state.clip.keys.indexOf(cur));
}

function renderClip() { renderTimeline(); renderSliders(); renderClipFields(); drawPreview(); validateClipUI(); }

function updatePlay() { $("play").textContent = playing ? "❚❚ pausar" : "▶ tocar"; }

function loop(now) {
  const dt = last ? (now - last) / 1000 : 0;
  last = now;
  if (playing) {
    playhead += dt;
    const d = N.duration(state.clip);
    if (!state.clip.loop && playhead > d + 0.6) playhead = 0;
    drawPreview();
  }
  if (sceneAnim) stepScene(dt);
  requestAnimationFrame(loop);
}

// ------------------------------------------------------------------ cena

function allClips() { return { ...P.clips, ...state.pack.clips }; }

function renderScene() {
  const s = state.scene;
  $("scene-id").value = s.id;
  $("scene-event").value = s.event;
  const body = $("beats");
  body.innerHTML = "";
  s.beats.forEach((b, i) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td><select aria-label="quem">${N.SCENE_ACTORS.map((a) => `<option ${a === b.actor ? "selected" : ""}>${a}</option>`).join("")}</select></td>
      <td><input type="number" step="0.1" min="0" max="20" value="${b.at}" aria-label="em segundos"></td>
      <td><input list="clip-names" value="${esc(b.clip || "")}" aria-label="clipe"></td>
      <td><input maxlength="40" value="${esc(b.bubble || "")}" aria-label="bolha"></td>
      <td><input list="sticker-names" value="${esc(b.sticker || "")}" aria-label="sticker"></td>
      <td><button type="button" aria-label="apagar batida">×</button></td>`;
    const [actor, at, clip, bubble, sticker] = tr.querySelectorAll("select, input");
    const upd = () => {
      b.actor = actor.value; b.at = Number(at.value); b.clip = clip.value.trim();
      b.bubble = bubble.value || undefined; b.sticker = sticker.value.trim() || undefined;
      validateSceneUI(); save();
    };
    [actor, at, clip, bubble, sticker].forEach((e) => e.addEventListener("input", upd));
    tr.querySelector("button").addEventListener("click", () => { s.beats.splice(i, 1); renderScene(); save(); });
    body.appendChild(tr);
  });
  validateSceneUI();
  drawScene(0);
}

function sceneJSON(s) {
  const beats = s.beats.map((b) => {
    const o = { actor: b.actor, at: Math.round(b.at * 100) / 100, clip: b.clip };
    if (b.bubble) o.bubble = b.bubble;
    if (b.sticker) o.sticker = b.sticker;
    return o;
  });
  return JSON.stringify({ id: s.id, event: s.event, beats }, null, 2) + "\n";
}

function validateSceneUI() {
  const list = N.validateScene(state.scene);
  const clips = allClips();
  for (const b of state.scene.beats) if (b.clip && !clips[b.clip]) list.push(`o clipe ${b.clip} não existe no pack padrão nem no seu`);
  problemsUI($("scene-problems"), list, "o motor aceita esta cena.");
}

let sceneAnim = null;
function drawScene(t) {
  const s = state.scene, clips = allClips();
  const actors = [...new Set(s.beats.map((b) => b.actor))];
  const xs = actors.map((_, i) => 60 + (i + 0.5) * (200 / Math.max(actors.length, 1)));
  let svg = `<line x1="20" x2="300" y1="170" y2="170" stroke="var(--line)" stroke-width="3" stroke-linecap="round"/>`;
  actors.forEach((a, i) => {
    const mine = s.beats.filter((b) => b.actor === a && b.at <= t).sort((x, y) => x.at - y.at);
    const cur = mine[mine.length - 1];
    const clip = cur && clips[cur.clip];
    const pose = clip ? N.sample(clip, t - cur.at) : { ...N.REST };
    svg += figure(pose, { cx: xs[i], ground: 170, s: a === "glyph" ? 2.9 : 2.4 });
    svg += `<text x="${xs[i]}" y="190" text-anchor="middle" font-size="10" fill="var(--muted)">${a}</text>`;
    if (cur && cur.bubble && t - cur.at < 3) {
      const w = Math.min(8 + cur.bubble.length * 6, 150);
      svg += `<g><rect x="${xs[i] - w / 2}" y="4" width="${w}" height="20" rx="8" fill="#fff" stroke="var(--ink)" stroke-width="1.5"/>
        <text x="${xs[i]}" y="18" text-anchor="middle" font-size="11" fill="#111">${esc(cur.bubble)}</text></g>`;
    }
  });
  $("scene-preview").innerHTML = svg;
}
function stepScene(dt) {
  sceneAnim.t += dt;
  drawScene(sceneAnim.t);
  const end = Math.max(0, ...state.scene.beats.map((b) => b.at)) + 3;
  if (sceneAnim.t > end) { sceneAnim = null; $("scene-play").textContent = "▶ tocar"; }
}

// ------------------------------------------------------------------ pack

function renderPack() {
  const m = state.pack.manifest;
  for (const f of ["id", "nome", "versao", "autor", "licenca", "descricao"]) $(`pack-${f}`).value = m[f] || "";
  const list = $("pack-list");
  const items = [...Object.keys(state.pack.clips).map((id) => ["clipe", id]), ...Object.keys(state.pack.scenes).map((id) => ["cena", id])];
  list.innerHTML = items.length ? "" : `<p class="muted">Vazio. Guarde um clipe ou uma cena.</p>`;
  for (const [kind, id] of items) {
    const div = document.createElement("div");
    div.className = "item";
    div.innerHTML = `<span>${kind}: <code>${esc(id)}</code></span><span><button type="button">abrir</button> <button type="button">tirar</button></span>`;
    const [open, remove] = div.querySelectorAll("button");
    open.addEventListener("click", () => {
      if (kind === "clipe") { state.clip = JSON.parse(JSON.stringify(state.pack.clips[id])); state.selected = 0; showTab("clipe"); renderClip(); }
      else { state.scene = JSON.parse(JSON.stringify(state.pack.scenes[id])); showTab("cena"); renderScene(); }
      save();
    });
    remove.addEventListener("click", () => {
      delete state.pack[kind === "clipe" ? "clips" : "scenes"][id];
      renderPack(); save();
    });
    list.appendChild(div);
  }
  validatePackUI();
}

function packProblems() {
  const list = N.validateManifest(state.pack.manifest);
  if (!Object.keys(state.pack.clips).length && !Object.keys(state.pack.scenes).length) list.push("o pack está vazio");
  for (const [id, c] of Object.entries(state.pack.clips)) for (const p of N.validateClip(c)) list.push(`${id}: ${p}`);
  for (const [id, s] of Object.entries(state.pack.scenes)) for (const p of N.validateScene(s)) list.push(`${id}: ${p}`);
  return list;
}
function validatePackUI() { problemsUI($("pack-problems"), packProblems(), "pronto para baixar."); }

function download(name, blob) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = name;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

// ------------------------------------------------------------------ abas

function showTab(name) {
  state.tab = name;
  document.querySelectorAll("[role=tab]").forEach((b) => b.setAttribute("aria-selected", String(b.dataset.tab === name)));
  for (const t of ["clipe", "cena", "pack"]) $(`tab-${t}`).classList.toggle("hidden", t !== name);
  if (name === "pack") renderPack();
  if (name === "cena") renderScene();
  save();
}

// ------------------------------------------------------------------ ligações

function init() {
  $("key-ease").innerHTML = N.EASES.map((e) => `<option>${e}</option>`).join("");
  $("clip-dot").innerHTML = `<option value="">(nenhum)</option>` + N.DOT_MODES.map((m) => `<option>${m}</option>`).join("");
  $("scene-event").innerHTML = N.SCENE_EVENTS.map((e) => `<option>${e}</option>`).join("");
  const base = Object.keys(P.clips).filter((id) => !N.PROTECTED_CLIPS.includes(id)).sort();
  $("base").innerHTML = `<option value="">começar de um clipe do pack padrão…</option>` + base.map((id) => `<option>${id}</option>`).join("");
  $("sticker-names").innerHTML = Object.keys(P.stickers).filter((s) => !N.PROTECTED_STICKERS.includes(s)).map((s) => `<option value="${s}">`).join("");
  const refreshClipNames = () => {
    $("clip-names").innerHTML = Object.keys(allClips()).filter((id) => !N.PROTECTED_CLIPS.includes(id)).sort().map((id) => `<option value="${id}">`).join("");
  };
  refreshClipNames();

  document.querySelectorAll("[role=tab]").forEach((b) => b.addEventListener("click", () => showTab(b.dataset.tab)));
  $("theme").addEventListener("click", () => {
    const r = document.documentElement;
    const dark = r.dataset.theme ? r.dataset.theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
    r.dataset.theme = dark ? "light" : "dark";
  });

  $("play").addEventListener("click", () => { playing = !playing; if (playing) playhead = 0; updatePlay(); drawPreview(); });
  ["twos", "mirror", "onion"].forEach((id) => $(id).addEventListener("change", drawPreview));
  $("timeline").addEventListener("click", (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    const t = ((e.clientX - r.left) / r.width) * N.duration(state.clip);
    let best = 0;
    state.clip.keys.forEach((k, i) => { if (Math.abs(k.t - t) < Math.abs(state.clip.keys[best].t - t)) best = i; });
    select(best);
  });
  $("add-key").addEventListener("click", () => {
    const c = state.clip, k = c.keys[state.selected];
    const next = c.keys[state.selected + 1];
    const t = k ? (next ? (k.t + next.t) / 2 : k.t + 0.25) : 0;
    c.keys.push({ t: Math.round(t * 1000) / 1000, ease: k?.ease || "inOut", pose: { ...(k ? k.pose : {}) } });
    state.selected = c.keys.length - 1;
    sortKeys(); renderClip(); save();
  });
  $("dup-key").addEventListener("click", () => {
    const c = state.clip, k = c.keys[state.selected];
    if (!k) return;
    const lastT = c.keys[c.keys.length - 1].t;
    c.keys.push({ t: Math.round((lastT + 0.25) * 1000) / 1000, ease: k.ease, pose: { ...k.pose } });
    state.selected = c.keys.length - 1;
    renderClip(); save();
  });
  $("del-key").addEventListener("click", () => {
    const c = state.clip;
    if (c.keys.length <= 1) return;
    c.keys.splice(state.selected, 1);
    state.selected = Math.max(0, state.selected - 1);
    renderClip(); save();
  });
  $("rest-key").addEventListener("click", () => {
    const k = state.clip.keys[state.selected];
    if (!k) return;
    k.pose = {};
    renderClip(); save();
  });
  $("key-t").addEventListener("change", () => {
    const k = state.clip.keys[state.selected];
    if (!k) return;
    k.t = Math.max(0, Number($("key-t").value) || 0);
    sortKeys(); renderClip(); save();
  });
  $("key-ease").addEventListener("change", () => {
    const k = state.clip.keys[state.selected];
    if (!k) return;
    k.ease = $("key-ease").value;
    drawPreview(); save();
  });
  $("clip-id").addEventListener("input", () => { state.clip.id = $("clip-id").value.trim(); validateClipUI(); save(); });
  $("clip-fps").addEventListener("input", () => { state.clip.fps = Number($("clip-fps").value); validateClipUI(); save(); });
  $("clip-loop").addEventListener("change", () => { state.clip.loop = $("clip-loop").checked; renderTimeline(); drawPreview(); save(); });
  $("clip-dot").addEventListener("change", () => {
    const m = $("clip-dot").value;
    state.clip.dot = m ? { mode: m, speed: Number($("clip-dot-speed").value) || 1 } : undefined;
    validateClipUI(); save();
  });
  $("clip-dot-speed").addEventListener("input", () => { if (state.clip.dot) state.clip.dot.speed = Number($("clip-dot-speed").value) || 1; save(); });
  $("load-base").addEventListener("click", () => {
    const id = $("base").value;
    if (!id) return;
    const c = JSON.parse(JSON.stringify(P.clips[id]));
    c.id = `${id}-meu`;
    for (const k of c.keys) { k.pose = k.pose || {}; k.ease = k.ease || "linear"; }
    state.clip = c; state.selected = 0;
    renderClip(); save();
  });
  $("new-clip").addEventListener("click", () => { state.clip = newClip(); state.selected = 0; renderClip(); save(); });
  $("import-btn").addEventListener("click", () => $("import").click());
  $("import").addEventListener("change", async () => {
    const f = $("import").files[0];
    if (!f) return;
    try {
      const obj = JSON.parse(await f.text());
      if (obj.beats) { state.scene = obj; showTab("cena"); }
      else if (obj.keys) { for (const k of obj.keys) k.pose = k.pose || {}; state.clip = obj; state.selected = 0; renderClip(); }
      else alert("esse arquivo não parece um clipe nem uma cena");
      save();
    } catch (e) { alert("não consegui ler: " + e.message); }
    $("import").value = "";
  });
  $("download-clip").addEventListener("click", () => {
    download(`${state.clip.id || "clipe"}.json`, new Blob([N.clipJSON(state.clip)], { type: "application/json" }));
  });
  $("to-pack").addEventListener("click", () => {
    const list = N.validateClip(state.clip);
    if (list.length) { alert("arrume antes:\n" + list.join("\n")); return; }
    state.pack.clips[state.clip.id] = JSON.parse(N.clipJSON(state.clip));
    refreshClipNames(); save();
    $("to-pack").textContent = "guardado ✓";
    setTimeout(() => ($("to-pack").textContent = "guardar no pack"), 1200);
  });

  $("scene-id").addEventListener("input", () => { state.scene.id = $("scene-id").value.trim(); validateSceneUI(); save(); });
  $("scene-event").addEventListener("change", () => { state.scene.event = $("scene-event").value; save(); });
  $("add-beat").addEventListener("click", () => {
    const lastAt = Math.max(0, ...state.scene.beats.map((b) => b.at));
    state.scene.beats.push({ actor: "glyph", at: Math.round((lastAt + 0.8) * 10) / 10, clip: "wave" });
    renderScene(); save();
  });
  $("scene-play").addEventListener("click", () => {
    sceneAnim = sceneAnim ? null : { t: 0 };
    $("scene-play").textContent = sceneAnim ? "❚❚ parar" : "▶ tocar";
    if (!sceneAnim) drawScene(0);
  });
  $("download-scene").addEventListener("click", () => {
    download(`${state.scene.id || "cena"}.json`, new Blob([sceneJSON(state.scene)], { type: "application/json" }));
  });
  $("scene-to-pack").addEventListener("click", () => {
    const list = N.validateScene(state.scene);
    if (list.length) { alert("arrume antes:\n" + list.join("\n")); return; }
    state.pack.scenes[state.scene.id] = JSON.parse(sceneJSON(state.scene));
    save();
    $("scene-to-pack").textContent = "guardado ✓";
    setTimeout(() => ($("scene-to-pack").textContent = "guardar no pack"), 1200);
  });

  for (const f of ["id", "nome", "versao", "autor", "licenca", "descricao"]) {
    $(`pack-${f}`).addEventListener("input", () => { state.pack.manifest[f] = $(`pack-${f}`).value.trim(); validatePackUI(); save(); });
  }
  $("download-pack").addEventListener("click", () => {
    const list = packProblems();
    if (list.length) { alert("arrume antes:\n" + list.join("\n")); return; }
    const m = { ...state.pack.manifest, formato: 1 };
    if (!m.descricao) delete m.descricao;
    const files = { [`${m.id}/pack.json`]: JSON.stringify(m, null, 2) + "\n" };
    for (const [id, c] of Object.entries(state.pack.clips)) files[`${m.id}/clips/${id}.json`] = N.clipJSON(c);
    for (const [id, s] of Object.entries(state.pack.scenes)) files[`${m.id}/scenes/${id}.json`] = sceneJSON(s);
    files[`${m.id}/LEIAME.md`] = `# ${m.nome}\n\n${m.descricao || ""}\n\nPor ${m.autor}. Licença: ${m.licenca}.\n\nFeito no Estúdio do Glyph. Valide com \`glyphd packs validar ${m.id}\`.\n`;
    download(`${m.id}.zip`, N.zip(files));
  });

  renderClip();
  showTab(state.tab || "clipe");
  requestAnimationFrame(loop);
}

init();
})();
