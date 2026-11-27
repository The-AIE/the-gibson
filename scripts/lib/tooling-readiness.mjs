// Tooling evidence for gibson-verify; execution uses its existing run helper.
// Local receipts are evidence, never branch-protection or merge authority.
import { existsSync, readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import { join, sep } from "node:path";
import { createHash } from "node:crypto";

const CONTRACT = ".agents/gate.json";
const SCHEMA = "gibson.tooling/v1";
const PROFILES = {
  javascript: /\.[cm]?[jt]sx?$/,
  python: /\.py$/,
  shell: /\.(?:sh|bash)$/,
  actions: /^\.github\/workflows\/[^/]+\.ya?ml$/,
  formatting: /\.(?:[cm]?[jt]sx?|py|sh|bash|json|md|ya?ml)$/,
};
const hash = (x) => createHash("sha256").update(x).digest("hex");
const argv = (x) => Array.isArray(x) && x.length > 0 && x.every((s) => typeof s === "string" && s.length > 0 && !s.includes("\0"));
const relative = (p) => typeof p === "string" && p.length > 0 && !p.startsWith("/") && !p.split("/").some((s) => s === ".." || s === ".") && !/[\0*?\[\]\\]/.test(p);

export function inspectTooling({ repo, base = "origin/main", adoption = false, run, git }) {
  base = base || "origin/main"; // parseFlags uses null for an omitted string flag.
  const findings = [];
  const add = (profile, status, detail) => findings.push({ profile, status, detail });
  let config = null;
  let baseRequired = false;
  let baseAvailable = false;
  try {
    // Policy follows the trusted base tip, including an opt-in merged after
    // this branch forked. Product diff/diagnostic baselines remain merge-base.
    const point = git(repo, ["rev-parse", "--verify", `${base}^{commit}`]);
    baseAvailable = true;
    const raw = run("git", ["-C", repo, "show", `${point}:${CONTRACT}`]);
    if (raw.code === 0) baseRequired = JSON.parse(raw.stdout).tooling?.mode === "required";
  } catch { /* Legacy repositories may not yet have a remote base. */ }
  try {
    if (existsSync(join(repo, CONTRACT))) config = JSON.parse(readFileSync(join(repo, CONTRACT), "utf8")).tooling;
  } catch (e) { add("contract", "missing", `invalid ${CONTRACT}: ${e.message}`); }
  const required = adoption || baseRequired || config?.mode === "required";
  const result = { schema: SCHEMA, required, mode: config?.mode || "legacy-audit", findings, profiles: [], configured: false, fingerprint: null };
  if (!config) {
    add("contract", "missing", "no tooling contract; bootstrap/repair may create it, but adoption is not ready");
    return result;
  }
  if (config.schema !== SCHEMA || !["audit", "required"].includes(config.mode) || !config.profiles || typeof config.profiles !== "object" || Array.isArray(config.profiles)) {
    add("contract", "missing", "expected gibson.tooling/v1, audit|required mode and profiles object");
    return result;
  }
  if (required && !baseAvailable) add("contract", "unavailable", `cannot resolve trusted base ${base}`);
  if ((adoption || baseRequired) && config.mode !== "required") add("contract", "missing", "adoption/previously required tooling cannot be downgraded to audit");
  let tracked;
  try { tracked = git(repo, ["ls-files", "-z"]).split("\0").filter(Boolean); }
  catch { add("contract", "unavailable", "cannot inventory tracked source files"); return result; }
  const trackedSet = new Set(tracked);
  const inputs = new Map();
  const file = (p) => {
    if (!relative(p) || !trackedSet.has(p)) throw new Error(`input must be a tracked relative file: ${p}`);
    const full = join(repo, p);
    if (!realpathSync(full).startsWith(`${realpathSync(repo)}${sep}`) || !statSync(full).isFile()) throw new Error(`input escapes repository or is not a file: ${p}`);
    const data = readFileSync(full);
    inputs.set(p, { sha256: hash(data), executable: statSync(full).mode & 0o111 });
    return data;
  };
  try { file(CONTRACT); } catch (e) { add("contract", "missing", e.message); }
  // Standard dependency/config inputs invalidate proof even when an adopter
  // forgets to list one. Custom wrappers/config must be listed explicitly.
  for (const p of tracked.filter((p) => /(?:^|\/)(?:package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|uv\.lock|poetry\.lock|pyproject\.toml|requirements[^/]*\.txt|\.?(?:ruff|eslint|prettier)[^/]*|\.shellcheckrc|\.actionlint\.ya?ml)$/.test(p))) {
    try { file(p); } catch (e) { add("contract", "missing", e.message); }
  }
  for (const name of Object.keys(config.profiles)) {
    if (!Object.hasOwn(PROFILES, name)) add(name, "missing", "unknown profile");
  }
  for (const [name, pattern] of Object.entries(PROFILES)) {
    const profile = config.profiles[name];
    const detected = tracked.filter((p) => !p.startsWith(".agents/tooling-controls/") && pattern.test(p));
    if (profile?.not_applicable) {
      if (typeof profile.not_applicable !== "string" || !profile.not_applicable.trim() || detected.length) add(name, "missing", `not-applicable needs a reason and no detected sources (${detected.length} found)`);
      else add(name, "not-applicable", profile.not_applicable);
      continue;
    }
    try {
      if (!profile || !argv(profile.command) || profile.command.filter((s) => s === "{file}").length !== 1) throw new Error("command must be an argv array with exactly one {file} argument");
      if (!argv(profile.version?.command) || typeof profile.version.expected !== "string" || !profile.version.expected.trim()) throw new Error("exact expected version and version argv required");
      if (!Array.isArray(profile.config) || !profile.config.length) throw new Error("tracked config/pin/input files required");
      profile.config.forEach(file);
      // Local wrappers/binaries are evidence inputs too; installed dependency binaries
      // are version-checked instead, with their lockfile declared in config.
      for (const arg of [...profile.command, ...profile.version.command]) {
        if (trackedSet.has(arg.replace(/^\.\//, ""))) file(arg.replace(/^\.\//, ""));
      }
      if (!Array.isArray(profile.sources) || !profile.sources.length || !profile.sources.every(relative)) throw new Error("sources must be explicit tracked files or directory prefixes ending in / (no globs)");
      const selected = tracked.filter((p) => profile.sources.some((s) => s.endsWith("/") ? p.startsWith(s) : p === s));
      if (!selected.length) throw new Error("source scope matches zero tracked files");
      if (detected.some((p) => !selected.includes(p))) throw new Error(`source scope omits detected ${name} files`);
      const c = profile.controls;
      if (!c || c.positive === c.negative || !Number.isInteger(c.exit) || c.exit < 1 || c.exit > 125 || typeof c.diagnostic !== "string" || !c.diagnostic.trim()) throw new Error("distinct positive/negative controls, expected negative exit (1..125) and diagnostic required");
      const positive = file(c.positive); const negative = file(c.negative);
      if (positive.equals(negative)) throw new Error("positive and negative controls have identical bytes");
      const version = run(profile.version.command[0], profile.version.command.slice(1), { cwd: repo, timeout: 15000 });
      if (version.code !== 0) { add(name, "unavailable", `version command exit ${version.code}`); continue; }
      if ((version.stdout + version.stderr).trim() !== profile.version.expected) throw new Error(`version mismatch: expected ${profile.version.expected}`);
      result.profiles.push({ name, ...profile, observed_version: profile.version.expected, source_count: selected.length });
      add(name, "configured-unverified", `${selected.length} tracked files declared; configuration is not executed coverage`);
    } catch (e) { add(name, "missing", e.message); }
  }
  result.configured = findings.every((f) => ["configured-unverified", "not-applicable"].includes(f.status));
  if (result.configured) {
    // Bind proof to the verifier that interpreted it, not just its schema.
    const verifier = hash(Buffer.concat([
      readFileSync(new URL(import.meta.url)),
      readFileSync(new URL("../gibson-verify.mjs", import.meta.url)),
    ]));
    result.fingerprint = hash(JSON.stringify({ config, verifier, inputs: [...inputs].sort(), versions: result.profiles.map((p) => [p.name, p.observed_version]) }));
  }
  return result;
}

export function cachedTooling(repo, plan, head, adoption = false) {
  if (!plan.configured) return null;
  const dir = join(repo, ".gibson-receipts");
  let names;
  try { names = readdirSync(dir).filter((n) => /^[0-9a-f]{40}\.json$/.test(n)); } catch { return null; }
  for (const name of names) {
    try {
      const r = JSON.parse(readFileSync(join(dir, name), "utf8"));
      const p = r.tooling;
      if (r.schema !== "gibson.verify-receipt.v1" || (adoption && r.head !== head) || !p || p.schema !== SCHEMA || p.fingerprint !== plan.fingerprint || p.verified !== true) continue;
      // Never accept a success bit alone, an empty list, or a generic nonzero.
      if (p.controls?.length !== plan.profiles.length || !plan.profiles.every((profile) => p.controls.some((c) => c.profile === profile.name && c.positive?.exit === 0 && c.negative?.exit === profile.controls.exit && c.negative?.diagnostic === profile.controls.diagnostic && c.negative?.matched === true))) continue;
      return { ...p, reused_from: r.head };
    } catch { /* A malformed receipt is not evidence. */ }
  }
  return null;
}

export function proveTooling(repo, plan, run) {
  const controls = plan.profiles.map((p) => {
    const execute = (path) => {
      const command = p.command.map((arg) => arg === "{file}" ? path : arg);
      const r = run(command[0], command.slice(1), { cwd: repo, timeout: 30000 });
      const output = r.stdout + r.stderr;
      return { exit: r.code, output_sha256: hash(output), output };
    };
    const positive = execute(p.controls.positive);
    const negative = execute(p.controls.negative);
    const matched = negative.output.includes(p.controls.diagnostic);
    // Keep bounded evidence, never convert a timeout/signal/spawn failure into
    // the expected diagnostic exit. The shared run helper marks those 127.
    delete positive.output; delete negative.output;
    return { profile: p.name, positive, negative: { ...negative, diagnostic: p.controls.diagnostic, matched }, ok: positive.exit === 0 && negative.exit === p.controls.exit && matched };
  });
  return { schema: SCHEMA, fingerprint: plan.fingerprint, verified: plan.configured && controls.every((c) => c.ok), controls };
}
