#!/usr/bin/env node
// Community results database tooling (SPEC §9).
//
//   node index.mjs --check            validate every file under results/, exit 1 on any problem
//   node index.mjs --write            also regenerate MATRIX.md and site/index.html
//   node index.mjs --results DIR ...  use another results directory (tests)
//
// Rules enforced, all of them (SPEC §9, §14):
//   - the file validates against Schema/export-v1.schema.json (which is also the privacy allowlist)
//   - is_simulator, is_translated, is_ios_app_on_mac, is_virtual_machine must all be false
//   - the file lives at results/<identity>/<os_build>-<n>.json and identity/build match its content
//   - size limit 512 KiB
//   - two results for the same (identity, os_build) that disagree on a measured fact are a conflict:
//     never silently resolved, always shown in the matrix
import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, dirname, resolve, basename } from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..", "..");
const args = process.argv.slice(2);
const write = args.includes("--write");
let resultsDir = join(root, "results");
const ri = args.indexOf("--results");
if (ri >= 0) resultsDir = resolve(args[ri + 1]);
const outMatrix = join(root, "MATRIX.md");
const outSite = join(root, "site", "index.html");

const schema = JSON.parse(readFileSync(join(root, "Schema", "export-v1.schema.json"), "utf8"));
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validate = ajv.compile(schema);

const MAX_BYTES = 512 * 1024;
const FLAGS = ["is_simulator", "is_translated", "is_ios_app_on_mac", "is_virtual_machine"];

// Columns of the measured matrix, in SPEC §4.3 order. Only flags: counts and bitmasks are not
// present/absent questions.
const MEASURED_COLUMNS = [
  ["arm.FEAT_MTE", "MTE"], ["arm.FEAT_MTE2", "MTE2"], ["arm.FEAT_MTE3", "MTE3"], ["arm.FEAT_MTE4", "MTE4"],
  ["arm.FEAT_MTE_ASYNC", "MTE async"], ["arm.FEAT_MTE_CANONICAL_TAGS", "canon. tags"], ["arm.FEAT_MTE_STORE_ONLY", "store-only"],
  ["arm.FEAT_MTE_NO_ADDRESS_TAGS", "no-addr tags"],
  ["arm.FEAT_PAuth", "PAuth"], ["arm.FEAT_PAuth2", "PAuth2"], ["arm.FEAT_FPAC", "FPAC"], ["arm.FEAT_FPACCOMBINE", "FPACCOMBINE"], ["arm.FEAT_PACIMP", "PACIMP"],
  ["arm.FEAT_BTI", "BTI"],
  ["arm.FEAT_CSV2", "CSV2"], ["arm.FEAT_CSV3", "CSV3"], ["arm.FEAT_SB", "SB"], ["arm.FEAT_SSBS", "SSBS"], ["arm.FEAT_SPECRES", "SPECRES"], ["arm.FEAT_SPECRES2", "SPECRES2"],
  ["arm.FEAT_DIT", "DIT"],
];
const DOCUMENTED_COLUMNS = [
  ["kip", "KIP"], ["fast_permission_restrictions", "FPR"], ["scip", "SCIP"], ["pac", "PAC (OS)"], ["ppl", "PPL"], ["sptm", "SPTM"], ["mie", "MIE"],
];
const GLYPH = { present: "●", not_present: "○", value: "◆", key_absent: "–", restricted: "⊘", not_applicable: "×", error: "!", unknown: "?" };

// ---------------------------------------------------------------- load
const problems = [];
const results = [];

function walk(dir) {
  if (!existsSync(dir)) return [];
  const out = [];
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (entry.endsWith(".json")) out.push(p);
  }
  return out;
}

for (const file of walk(resultsDir)) {
  const rel = file.slice(resultsDir.length + 1);
  const size = statSync(file).size;
  if (size > MAX_BYTES) { problems.push(`${rel}: ${size} bytes exceeds the ${MAX_BYTES}-byte limit`); continue; }
  let doc;
  try { doc = JSON.parse(readFileSync(file, "utf8")); } catch (e) { problems.push(`${rel}: not JSON (${e.message})`); continue; }
  if (!validate(doc)) {
    for (const err of validate.errors.slice(0, 5)) problems.push(`${rel}: schema ${err.instancePath || "/"} ${err.message}`);
    continue;
  }
  for (const flag of FLAGS) if (doc.environment[flag]) problems.push(`${rel}: environment.${flag} is true; results from simulators, translated processes, iOS-on-Mac, or virtual machines are not accepted`);
  const dirName = basename(dirname(file));
  const fileName = basename(file, ".json");
  const build = doc.environment.os_build || "nobuild";
  if (dirName !== doc.device.identity) problems.push(`${rel}: directory '${dirName}' does not match device.identity '${doc.device.identity}'`);
  if (!new RegExp(`^${build.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}-\\d+$`).test(fileName)) problems.push(`${rel}: file name must be '${build}-<n>.json' (os_build followed by a sequence number)`);
  if (doc.variant === "compact") problems.push(`${rel}: compact exports are for QR/sharing; submit the full export`);
  results.push({ rel, doc });
}

// ------------------------------------------------------------- conflicts
function factState(doc, id) { return doc.facts.find((f) => f.id === id)?.state; }
const groups = new Map();
for (const r of results) {
  const key = `${r.doc.device.identity}|${r.doc.environment.os_build}`;
  if (!groups.has(key)) groups.set(key, []);
  groups.get(key).push(r);
}
const conflicts = [];
for (const [key, members] of groups) {
  if (members.length < 2) continue;
  const measured = new Set();
  for (const m of members) for (const f of m.doc.facts) if (f.provenance === "measured") measured.add(f.id);
  for (const id of measured) {
    const states = new Map();
    for (const m of members) states.set(m.rel, factState(m.doc, id) ?? "(missing)");
    if (new Set(states.values()).size > 1) conflicts.push({ key, id, states: [...states] });
  }
}

// ---------------------------------------------------------------- report
if (problems.length) {
  console.error(`✘ ${problems.length} problem(s):`);
  for (const p of problems) console.error("  " + p);
}
const acceptedCount = results.filter((r) => !problems.some((p) => p.startsWith(r.rel + ":"))).length;
console.log(`${acceptedCount} accepted result(s) of ${results.length} parsed, ${conflicts.length} conflict(s)`);
for (const c of conflicts) console.log(`  ⚠ ${c.key} ${c.id}: ${c.states.map(([f, s]) => `${f}=${s}`).join(", ")}`);

// ------------------------------------------------------------- generate
function accepted(r) { return !problems.some((p) => p.startsWith(r.rel + ":")); }
const rows = results.filter(accepted).sort((a, b) =>
  (a.doc.environment.arch + a.doc.device.soc_id + a.doc.device.identity + a.doc.environment.os_build)
    .localeCompare(b.doc.environment.arch + b.doc.device.soc_id + b.doc.device.identity + b.doc.environment.os_build));

function conflictIDs(r) {
  const key = `${r.doc.device.identity}|${r.doc.environment.os_build}`;
  return new Set(conflicts.filter((c) => c.key === key).map((c) => c.id));
}

function measuredTable(rs) {
  const head = ["arch", "SoC", "identity", "OS build", ...MEASURED_COLUMNS.map(([, n]) => n)];
  const lines = ["| " + head.join(" | ") + " |", "|" + head.map(() => "---").join("|") + "|"];
  for (const r of rs) {
    const cids = conflictIDs(r);
    const cells = MEASURED_COLUMNS.map(([id]) => {
      const s = factState(r.doc, id);
      const g = s ? GLYPH[s] ?? s : "·";
      return cids.has(id) ? `⚠${g}` : g;
    });
    const soc = r.doc.device.soc_name_inferred === "unrecognized" ? `${r.doc.device.soc_id ?? "?"} (unmapped)` : `${r.doc.device.soc_name_inferred} (${r.doc.device.soc_id})`;
    lines.push(`| ${r.doc.environment.arch} | ${soc} | ${r.doc.device.identity} | ${r.doc.environment.platform} ${r.doc.environment.os_build} | ${cells.join(" | ")} |`);
  }
  return lines.join("\n");
}

function documentedTable(rs) {
  const head = ["SoC", "identity", "column", ...DOCUMENTED_COLUMNS.map(([, n]) => n), "guide published"];
  const lines = ["| " + head.join(" | ") + " |", "|" + head.map(() => "---").join("|") + "|"];
  const seen = new Set();
  for (const r of rs) {
    const k = `${r.doc.device.soc_id}|${r.doc.device.identity}`;
    if (seen.has(k)) continue;
    seen.add(k);
    const cells = DOCUMENTED_COLUMNS.map(([id]) => GLYPH[factState(r.doc, id)] ?? "·");
    const note = r.doc.facts.find((f) => f.id === "kip")?.source?.note ?? "";
    const column = /column ([A-Za-z0-9-]+)/.exec(note)?.[1] ?? "none";
    const published = r.doc.facts.find((f) => f.id === "kip")?.source?.published ?? "";
    lines.push(`| ${r.doc.device.soc_name_inferred} (${r.doc.device.soc_id ?? "?"}) | ${r.doc.device.identity} | ${column} | ${cells.join(" | ")} | ${published} |`);
  }
  return lines.join("\n");
}

function extras(rs) {
  const lines = [];
  for (const r of rs) {
    const caps = r.doc.capabilities;
    const walk = r.doc.collection.walk_succeeded ? "walk + inventory" : "inventory only";
    const unrec = r.doc.unrecognized_keys.length;
    lines.push(`- **${r.doc.device.identity}** (${r.doc.environment.platform} ${r.doc.environment.os_build}, ${r.rel}): ${walk}; ` +
      (caps ? `caps ${caps.popcount} bits set (${caps.named_bits.length} named, unnamed ${JSON.stringify(caps.unnamed_bits)}), ${caps.mismatches.length} mismatch(es)` : "caps not decoded") +
      (unrec ? `; **${unrec} unrecognized key(s)**: ${r.doc.unrecognized_keys.map((f) => f.raw.key).join(", ")}` : "") +
      `; engine ${r.doc.app_version}, inventory ${r.doc.collection.known_keys_version ?? "unknown"}`);
  }
  return lines.join("\n");
}

const now = new Date().toISOString().slice(0, 10);
const matrix = `# Silicon Audit results matrix

Generated ${now} from ${rows.length} accepted result(s) in \`results/\` by \`Tools/generate-matrix\`. Do not edit by hand.

Legend: ● reported present · ○ reported off · – key absent from that kernel · ⊘ restricted by the sandbox · × not applicable (other architecture) · ! read error · ? unknown · ⚠ conflict between submissions for the same device and build.

**Measured** means the kernel on that device reported it, not that the silicon has it. **Documented** rows are Apple's published table applied through the chip family the app inferred from the kernel target; see each result's own provenance fields.

## Measured security flags

${measuredTable(rows)}

## Apple's documented protections, by chip family

${documentedTable(rows)}

## Per-result notes

${extras(rows) || "_none_"}

## Conflicts

${conflicts.length ? conflicts.map((c) => `- \`${c.key}\` **${c.id}**: ${c.states.map(([f, s]) => `\`${f}\` → ${s}`).join(", ")}`).join("\n") : "_none_"}
`;

function esc(s) { return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function htmlTable(md) {
  const lines = md.split("\n").filter((l) => l.startsWith("|"));
  const cells = (l) => l.slice(1, -1).split(" | ").map((c) => c.trim());
  const head = cells(lines[0]);
  const body = lines.slice(2).map(cells);
  return `<table><thead><tr>${head.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${body.map((r) => `<tr>${r.map((c) => `<td>${esc(c)}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
}
const site = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Silicon Audit results</title>
<style>
:root{color-scheme:light dark;font-family:-apple-system,system-ui,sans-serif;line-height:1.45}
body{margin:0 auto;max-width:1200px;padding:24px}
h1{font-size:1.6rem}h2{font-size:1.2rem;margin-top:2rem}
.scroll{overflow-x:auto}table{border-collapse:collapse;font-size:.9rem;white-space:nowrap}
th,td{border-bottom:1px solid color-mix(in srgb,currentColor 20%,transparent);padding:6px 10px;text-align:left}
th{position:sticky;top:0;background:Canvas}
td:nth-child(n+5){text-align:center;font-size:1.05rem}
.legend{font-size:.9rem;opacity:.85}code{font-size:.9em}
</style></head><body>
<h1>Silicon Audit results</h1>
<p class="legend">Generated ${now} from ${rows.length} accepted result(s). ● reported present · ○ reported off · – key absent · ⊘ restricted · × not applicable · ! error · ? unknown · ⚠ conflict. <strong>Measured</strong> = the kernel on that device reported it. <strong>Documented</strong> = Apple's published table applied through the inferred chip family. Source and contribution guide: <a href="https://github.com/unredacted/apple-silicon-audit">github.com/unredacted/apple-silicon-audit</a>.</p>
<h2>Measured security flags</h2><div class="scroll">${htmlTable(measuredTable(rows))}</div>
<h2>Apple's documented protections, by chip family</h2><div class="scroll">${htmlTable(documentedTable(rows))}</div>
<h2>Per-result notes</h2><ul>${rows.map((r) => `<li>${esc(extras([r]).slice(2))}</li>`).join("")}</ul>
<h2>Conflicts</h2>${conflicts.length ? `<ul>${conflicts.map((c) => `<li><code>${esc(c.key)}</code> <strong>${esc(c.id)}</strong>: ${c.states.map(([f, s]) => `<code>${esc(f)}</code> → ${esc(s)}`).join(", ")}</li>`).join("")}</ul>` : "<p>none</p>"}
</body></html>
`;

if (write) {
  writeFileSync(outMatrix, matrix);
  writeFileSync(outSite, site);
  console.log(`wrote ${outMatrix} and ${outSite}`);
}
process.exit(problems.length ? 1 : 0);
