#!/usr/bin/env node
/**
 * scope-recheck.mjs — push-time collision guards for a claimed PR (#568)
 *
 * WHAT IT DOES
 *   Three read-only checks that prepush.sh runs before a push:
 *     scope         compare the files this branch changed (stdin, one per line)
 *                   to the PR's `Claim scope`. A file outside the scope fails
 *                   with the list and the instruction to amend the claim. A
 *                   changed file inside the scope of another LIVE claim with a
 *                   LOWER PR number fails with wait/rebase/coordinate.
 *     docs-numbers  fail when a `docs/NN-` number is claimed by two different
 *                   new files across main and the open PRs.
 *     workflows     fail when a checked-in `.github/workflows/*.yml` has no
 *                   policy in config/sensor-health-observation.v1.json (the
 *                   same join sensor-health runs in CI, run locally).
 *
 * WHY
 *   A claim declares its scope before the work, and scope-overlap.mjs
 *   --admit-pr checks it once, at claim time. Scope that grows afterwards was
 *   invisible until merge. Admission stays the source of truth: this only
 *   re-asks the same question (lower PR number wins) when the file set is known.
 *
 * RISKS
 *   - Report-only and read-only: it changes nothing, GitHub or local. CI and
 *     admission stay the authority.
 *   - Containment here is exact path, `dir/**`, `dir/*` (one level) or a bare
 *     directory prefix. It is stricter than scope-overlap's overlap kernel on
 *     purpose: "inside the claim" must not be answered by "might touch".
 *   - `gh pr list --json files` returns at most 100 files per PR.
 *   - Any GitHub read that fails exits 2 (NOT RUN), never a pass.
 *
 * USAGE
 *   git diff --name-only BASE | node scripts/scope-recheck.mjs scope [--repo O/N] [--pr N] [--json]
 *   node scripts/scope-recheck.mjs docs-numbers --base REF [--repo O/N] [--pr N] [--mine]
 *   node scripts/scope-recheck.mjs workflows
 *   node scripts/scope-recheck.mjs --help
 *
 * EXIT
 *   0 clear   1 finding   2 usage, or a read failed (NOT RUN)   4 skipped (reason on line 1)
 */
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, "..");

function usage() {
  console.log(`scope-recheck.mjs — push-time scope, docs-number and workflow-registration guards (#568)

WHAT IT DOES
  scope         changed files (stdin) vs the PR's Claim scope, and vs live claims
                on lower PR numbers
  docs-numbers  a docs/NN- number used by two different new files across main
                and open PRs
  workflows     a checked-in workflow with no sensor-health policy

WHY
  Claim scope is declared before the work and admitted once. Growth after the
  claim only surfaced as a merge conflict. See issue #568.

RISKS
  Read-only and report-only; admission (scope-overlap.mjs --admit-pr) stays the
  source of truth. A failed GitHub read is NOT RUN (exit 2), never a pass.

USAGE
  git diff --name-only BASE | node scripts/scope-recheck.mjs scope [--repo O/N] [--pr N]
  node scripts/scope-recheck.mjs docs-numbers --base REF [--repo O/N] [--pr N]
  node scripts/scope-recheck.mjs workflows
  node scripts/scope-recheck.mjs --help

EXIT
  0 clear   1 finding   2 usage or unreadable evidence   4 skipped`);
}

function die(code, msg) {
  console.error(msg);
  process.exit(code);
}

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: "utf8", cwd: REPO_ROOT, maxBuffer: 64 * 1024 * 1024, ...opts });
  return { rc: r.status ?? 2, out: r.stdout ?? "", err: r.stderr ?? "" };
}

function parseArgs(argv) {
  const o = { cmd: argv[0], repo: "", pr: "", base: "origin/main", json: false, mine: false };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--json") {
      o.json = true;
    } else if (a === "--mine") {
      o.mine = true;
    } else if (a === "--repo" || a === "--pr" || a === "--base") {
      if (i + 1 >= argv.length) die(2, `scope-recheck: ${a} requires a value`);
      o[a.slice(2)] = argv[++i];
    } else {
      die(2, `scope-recheck: unknown flag: ${a}`);
    }
  }
  return o;
}

function resolveRepo(o) {
  if (o.repo) {
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(o.repo)) die(2, `scope-recheck: --repo must be owner/name, got '${o.repo}'`);
    return o.repo;
  }
  const url = run("git", ["config", "--get", "remote.origin.url"]).out.trim();
  const host = (process.env.GH_HOST || "github.com").replace(/[.]/g, "\\.");
  const re = new RegExp(`^(?:https://${host}/|git@${host}:|ssh://git@${host}/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\\.git)?/?$`);
  const m = re.exec(url);
  if (!m) {
    console.log(`origin '${url || "<none>"}' is not a ${process.env.GH_HOST || "github.com"} repository; claims are GitHub-only, nothing to re-check (zero gh calls)`);
    process.exit(4);
  }
  return m[1];
}

function currentPr(o, repo) {
  if (o.pr) {
    if (!/^[0-9]+$/.test(o.pr)) die(2, `scope-recheck: --pr must be a number, got '${o.pr}'`);
    return Number(o.pr);
  }
  const branch = run("git", ["branch", "--show-current"]).out.trim();
  if (!branch) {
    console.log("detached HEAD; no branch to look up a claim PR for");
    process.exit(4);
  }
  const r = run("gh", ["pr", "view", branch, "--repo", repo, "--json", "number"]);
  if (r.rc !== 0) {
    if (/no pull requests? found/i.test(r.err)) {
      console.log("no pull request for this branch yet; nothing to re-check until it has a claim PR");
      process.exit(4);
    }
    die(2, `scope-recheck: cannot read the current pull request: ${r.err.trim().split("\n").pop()}`);
  }
  let n;
  try { n = JSON.parse(r.out).number; } catch { n = null; }
  if (!Number.isInteger(n)) die(2, "scope-recheck: gh pr view returned no pull-request number");
  return n;
}

/** True when `file` is inside the claim scope `token` (containment, not overlap). */
function inScope(file, token) {
  if (token === "**") return true;
  if (token.endsWith("/**")) return file.startsWith(token.slice(0, -2));
  if (token.endsWith("/*")) {
    const dir = token.slice(0, -1);
    return file.startsWith(dir) && !file.slice(dir.length).includes("/");
  }
  if (token.includes("*")) return false;
  return file === token || file.startsWith(token + "/");
}

/** Print findings (text, or JSON when --json) and exit 1; or print the clear line and return. */
function report(o, findings, text, clearLine) {
  if (o.json) console.log(JSON.stringify({ ok: findings.length === 0, findings }));
  else console.log(findings.length ? text : clearLine);
  if (findings.length) process.exit(1);
}

/**
 * True when `file` collides with claim scope `token` under the authoritative kernel in
 * scope-overlap.mjs (--pair): prefix/stem overlap, fail-closed on tokens it cannot classify.
 * Containment is the cheap, certain case and skips the spawn.
 */
function collides(file, token) {
  if (inScope(file, token)) return true;
  const r = run("node", [join(SCRIPT_DIR, "scope-overlap.mjs"), "--pair", file, token]);
  if (r.rc === 1 && r.out.trim() === "overlap") return true;
  if (r.rc === 0 && r.out.trim() === "disjoint") return false;
  die(2, `scope-recheck: scope-overlap --pair failed for '${file}' vs '${token}': ${r.err.trim().split("\n").pop()}`);
}

function readStdinLines() {
  let raw = "";
  try { raw = readFileSync(0, "utf8"); } catch { raw = ""; }
  return [...new Set(raw.split("\n").map((s) => s.trim()).filter(Boolean))];
}

function liveClaims(repo) {
  const r = run("bash", [join(SCRIPT_DIR, "pr-claims.sh"), "list", repo]);
  if (r.rc !== 0) die(2, `scope-recheck: pr-claims.sh list failed: ${r.err.trim().split("\n").pop()}`);
  const rows = [];
  for (const line of r.out.split("\n")) {
    if (!line) continue;
    const f = line.split("\t");
    if (f.length < 3 || !/^[0-9]+$/.test(f[0]) || !f[2]) die(2, `scope-recheck: malformed claim row: ${line.slice(0, 80)}`);
    rows.push({ number: Number(f[0]), id: f[1], tokens: f[2].split(/\s+/).filter(Boolean) });
  }
  return rows;
}

function cmdScope(o) {
  const repo = resolveRepo(o);
  const files = readStdinLines();
  const pr = currentPr(o, repo);
  const claims = liveClaims(repo);
  const mine = claims.find((c) => c.number === pr);
  if (!mine) die(2, `scope-recheck: PR #${pr} has no live Active-work claim row; cannot compare its scope`);
  const findings = [];
  const texts = [];
  const outside = files.filter((f) => !mine.tokens.some((t) => inScope(f, t)));
  if (outside.length) {
    findings.push({ kind: "outside-scope", pr, claim: mine.id, files: outside });
    texts.push(
      `files changed outside the claim scope of PR #${pr} (${mine.id}):\n` +
        outside.map((f) => `    ${f}`).join("\n") +
        `\n  Amend the claim: add them to the '- Claim scope:' line in the PR body. Amending re-runs\n` +
        `  overlap admission against the other open claims (lower PR number wins), so do it before pushing.`
    );
  }
  for (const other of claims) {
    if (other.number >= pr) continue;
    const hit = files.filter((f) => other.tokens.some((t) => collides(f, t)));
    if (!hit.length) continue;
    findings.push({ kind: "lower-numbered-claim", pr: other.number, claim: other.id, files: hit });
    texts.push(
      `files changed that sit in the scope of live claim PR #${other.number} (${other.id}, lower number, it wins):\n` +
        hit.map((f) => `    ${f}`).join("\n") +
        `\n  Do not push. Wait for that PR to merge and rebase, or coordinate scope with its owner.`
    );
  }
  report(o, findings, texts.join("\n"), `${files.length} changed file(s) all inside PR #${pr} scope; no lower-numbered live claim holds any of them`);
}

const DOCS_RE = /^docs\/([0-9]{2})-[^/]+$/;

function cmdDocsNumbers(o) {
  const repo = resolveRepo(o);
  const tree = run("git", ["ls-tree", "--name-only", o.base, "docs/"]);
  if (tree.rc !== 0) die(2, `scope-recheck: cannot list docs/ at ${o.base}: ${tree.err.trim()}`);
  const mainPaths = new Set(tree.out.split("\n").filter(Boolean));
  // number -> Map(party -> Set(paths)); main is one party however many files share its number.
  const byNum = new Map();
  const add = (num, party, path) => {
    if (!byNum.has(num)) byNum.set(num, new Map());
    const parties = byNum.get(num);
    if (!parties.has(party)) parties.set(party, new Set());
    parties.get(party).add(path);
  };
  for (const p of mainPaths) {
    const m = DOCS_RE.exec(p);
    if (m) add(m[1], "main", p);
  }
  let me = o.pr ? Number(o.pr) : null;
  if (me === null) {
    // This branch's pushed files are judged from the local tree, never twice (a rename of a pushed doc).
    const branch = run("git", ["branch", "--show-current"]).out.trim();
    const v = branch ? run("gh", ["pr", "view", branch, "--repo", repo, "--json", "number"]) : { rc: 1, out: "" };
    try { if (v.rc === 0 && Number.isInteger(JSON.parse(v.out).number)) me = JSON.parse(v.out).number; } catch { /* no PR yet */ }
  }
  const lp = run("gh", ["pr", "list", "--repo", repo, "--state", "open", "--limit", "500", "--json", "number,files"]);
  if (lp.rc !== 0) die(2, `scope-recheck: cannot list open pull requests: ${lp.err.trim().split("\n").pop()}`);
  let prs;
  try { prs = JSON.parse(lp.out); } catch { prs = null; }
  if (!Array.isArray(prs)) die(2, "scope-recheck: gh pr list returned malformed JSON");
  for (const p of prs) {
    if (!Number.isInteger(p?.number) || !Array.isArray(p?.files)) die(2, "scope-recheck: gh pr list row has no number/files");
    if (me !== null && p.number === me) continue;
    for (const f of p.files) {
      const m = typeof f?.path === "string" ? DOCS_RE.exec(f.path) : null;
      if (m && !mainPaths.has(f.path)) add(m[1], `PR #${p.number}`, f.path);
    }
  }
  // This branch's own new docs, from the local diff against the base.
  const mineNums = new Set();
  for (const f of readStdinLines()) {
    const m = DOCS_RE.exec(f);
    if (m && !mainPaths.has(f)) mineNums.add(m[1]);
    if (!m || mainPaths.has(f)) continue;
    // Pushed already: the open-PR list carries this same path under its own number.
    const seen = [...(byNum.get(m[1])?.values() ?? [])].some((paths) => paths.has(f));
    if (!seen) add(m[1], me !== null ? `PR #${me}` : "this branch", f);
  }
  // --mine (prepush): fail only on a number this branch adds a file under, so a lane is not
  // blocked by two OTHER pull requests colliding; those are printed as a note, not a failure.
  const reused = (parties) => parties.size > 1 || [...parties].some(([k, v]) => k !== "main" && v.size > 1);
  const allDups = [...byNum].filter(([, parties]) => reused(parties)).sort(([x], [y]) => x.localeCompare(y));
  const dups = o.mine ? allDups.filter(([num]) => mineNums.has(num)) : allDups;
  if (o.mine && !o.json) {
    for (const [num, parties] of allDups.filter(([n]) => !mineNums.has(n)))
      console.log(`note: docs/${num}- is also claimed by ${[...parties.keys()].join(" and ")} (not this branch)`);
  }
  const findings = dups.map(([number, parties]) => ({
    kind: "docs-number-reused",
    number,
    parties: Object.fromEntries([...parties].map(([k, v]) => [k, [...v].sort()])),
  }));
  const text = dups
    .map(([num, parties]) =>
      [`docs/${num}- is claimed by ${parties.size} part${parties.size === 1 ? "y with several files" : "ies"}; take the next free number:`,
        ...[...parties].map(([party, paths]) => `    ${party}: ${[...paths].sort().join(", ")}`)].join("\n"))
    .join("\n");
  report(o, findings, text, `no docs/NN- number is used twice across ${o.base} and ${prs.length} open pull request(s)`);
}

async function cmdWorkflows(o) {
  const registry = join(REPO_ROOT, "config/sensor-health-observation.v1.json");
  const wfDir = join(REPO_ROOT, ".github/workflows");
  const lib = join(SCRIPT_DIR, "sensor-health-lib.mjs");
  if (!existsSync(registry) && !existsSync(wfDir)) {
    console.log("no sensor-health registry and no .github/workflows here; nothing to register");
    process.exit(4);
  }
  if (!existsSync(lib)) die(2, "scope-recheck: scripts/sensor-health-lib.mjs is missing; cannot run the registration join");
  let m, reg, joined;
  try {
    m = await import(lib);
    reg = m.loadRegistryFile(REPO_ROOT);
    joined = m.inventoryCheckedInWorkflows({ checkedInPaths: m.discoverCheckedInWorkflows(REPO_ROOT), policies: reg.policies });
  } catch (err) {
    die(2, `scope-recheck: registration join failed: ${err.message}`);
  }
  const rows = Array.isArray(joined?.rows) ? joined.rows : null;
  if (!rows) die(2, `scope-recheck: registration join returned no rows (${joined?.error ?? "unknown"})`);
  const bad = rows.filter((r) => r.joinError);
  report(
    o,
    bad.map((r) => ({ kind: "unregistered-workflow", path: r.path || r.name, reason: r.joinError })),
    bad.map((r) => `${r.path || r.name}: ${r.joinError} — register it in config/sensor-health-observation.v1.json (and the scripts/sensor-health.test.mjs fixtures)`).join("\n"),
    `${rows.length} checked-in workflow(s), all registered in the sensor-health registry`
  );
}

const argv = process.argv.slice(2);
if (argv.length === 0 || argv.includes("-h") || argv.includes("--help")) {
  usage();
  process.exit(argv.length === 0 ? 2 : 0);
}
const opt = parseArgs(argv);
if (opt.cmd === "scope") cmdScope(opt);
else if (opt.cmd === "docs-numbers") cmdDocsNumbers(opt);
else if (opt.cmd === "workflows") await cmdWorkflows(opt);
else die(2, opt.cmd.startsWith("-") ? `unknown flag: ${opt.cmd}` : `unknown command: ${opt.cmd}`);
