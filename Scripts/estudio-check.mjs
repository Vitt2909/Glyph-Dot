// Confere o núcleo do estúdio (docs/estudio/nucleo.js) contra o motor:
// a cinemática e a amostragem dos clipes do pack padrão precisam bater com
// docs/estudio/referencia.json, que o teste StudioReferenceTests grava.
//
//   node Scripts/estudio-check.mjs
import { readFileSync, readdirSync } from "node:fs";
import vm from "node:vm";

const root = new URL("..", import.meta.url);
vm.runInThisContext(readFileSync(new URL("docs/estudio/nucleo.js", root), "utf8"));
const { sample, solve, validateClip, validateScene, validateManifest, zip, crc32 } = globalThis.GlyphNucleo;
const ref = JSON.parse(readFileSync(new URL("docs/estudio/referencia.json", root)));
const clips = {};
for (const f of readdirSync(new URL("Packs/default/clips/", root))) {
  if (f.endsWith(".json")) clips[f.slice(0, -5)] = JSON.parse(readFileSync(new URL(`Packs/default/clips/${f}`, root)));
}
// padrao.js (gerado pelo glyph-art) tem os mesmos clipes que o pack padrão.
vm.runInThisContext(readFileSync(new URL("docs/estudio/padrao.js", root), "utf8"));
const embedded = globalThis.GlyphPadrao;
let fails = 0;
if (JSON.stringify(Object.keys(embedded.clips).sort()) !== JSON.stringify(Object.keys(clips).sort())) {
  fails++; console.error("docs/estudio/padrao.js desatualizado: rode swift run glyph-art");
}

for (const s of ref) {
  const sk = solve(sample(clips[s.clip], s.t), s.facing);
  for (const [k, [x, y]] of Object.entries(s.points)) {
    if (Math.abs(sk[k].x - x) > 0.002 || Math.abs(sk[k].y - y) > 0.002) {
      fails++;
      if (fails < 10) console.error(`${s.clip} t=${s.t} f=${s.facing} ${k}: js (${sk[k].x}, ${sk[k].y}) motor (${x}, ${y})`);
    }
  }
}

// Os clipes do pack padrão passam na validação do estúdio (mesmas regras do motor).
for (const [id, c] of Object.entries(clips)) {
  const problems = validateClip(c).filter((p) => !p.includes("sinal de segurança"));
  if (problems.length) { fails++; console.error(`${id}: ${problems.join("; ")}`); }
}
for (const f of readdirSync(new URL("Examples/pack-exemplo/scenes/", root))) {
  const s = JSON.parse(readFileSync(new URL(`Examples/pack-exemplo/scenes/${f}`, root)));
  const p = validateScene(s);
  if (p.length) { fails++; console.error(`${f}: ${p.join("; ")}`); }
}
const manifest = JSON.parse(readFileSync(new URL("Examples/pack-exemplo/pack.json", root)));
if (validateManifest(manifest).length) { fails++; console.error("pack.json de exemplo reprovado"); }
if (!validateScene({ id: "x", event: "teste.passou", beats: [{ actor: "glyph", at: 0, clip: "await" }] }).length) {
  fails++; console.error("cena com sinal de segurança passou");
}
if (crc32(new TextEncoder().encode("123456789")) !== 0xcbf43926) { fails++; console.error("crc32 errado"); }
const blob = zip({ "a/pack.json": "{}\n" });
if (!(blob.size > 60)) { fails++; console.error("zip vazio"); }

console.log(fails ? `FALHOU (${fails})` : `ok: ${ref.length} amostras batem com o motor`);
process.exit(fails ? 1 : 0);
