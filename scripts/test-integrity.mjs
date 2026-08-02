#!/usr/bin/env node
/**
 * test-integrity.mjs — count-based test-deletion / skip-inflation sensor (issue #70)
 *
 * Compares total and skip/todo metrics against a trusted baseline. A drop in
 * total tests or a rise in skip/todo hard-fails with a `test-integrity`
 * diagnosis unless an exact, visible waiver line covers the delta. PR/commit
 * text is inert data: matched as text, never evaluated.
 *
 * Supported summary contract (first match wins when parsing runner output):
 *   1. Explicit line:
 *        GIBSON_TEST_METRICS total=<n> skipped=<n> todo=<n>
 *      or JSON: GIBSON_TEST_METRICS {"total":n,"skipped":n,"todo":n}
 *   2. Vitest-style:  Tests  N passed | M skipped (T)
 *   3. Jest-style:    Tests:  M skipped, N passed, T total
 *   4. node:test:     # tests T / # skip M / # todo K
 *   5. TAP plan:      1..T  plus  # skip / ok N # SKIP
 *
 * Unparseable, negative, or non-integer metrics fail closed (never become 0).
 *
 * Known limit: count-only comparison cannot detect "deleted A, added B of equal
 * count." Prefer named identities in product harnesses that can do that cheaply;
 * this sensor stays vendor-blind and count-based on purpose.
 *
 * CLI:
 *   node scripts/test-integrity.mjs parse  --input FILE [--out FILE]
 *   node scripts/test-integrity.mjs compare --base FILE --head FILE
 *       [--waiver-text STR | --waiver-file FILE] [--trusted-source NAME]
 *   node scripts/test-integrity.mjs journal-append --journal FILE
 *       --old FILE --new FILE --reason STR [--sha STR]
 */

import { readFileSync, writeFileSync, appendFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const RESULT = "test-integrity";

// ---------------------------------------------------------------------------
// Metric validation — fail closed, never coerce garbage to zero
// ---------------------------------------------------------------------------

/**
 * @param {unknown} value
 * @param {string} field
 * @returns {number}
 */
export function parseNonNegInt(value, field) {
  if (typeof value === "number") {
    if (!Number.isFinite(value) || !Number.isInteger(value) || value < 0) {
      throw new Error(
        `${RESULT}: unparseable metric '${field}': ${JSON.stringify(value)} (need non-negative integer)`
      );
    }
    return value;
  }
  if (typeof value === "string") {
    const t = value.trim();
    if (!/^(0|[1-9]\d*)$/.test(t)) {
      throw new Error(
        `${RESULT}: unparseable metric '${field}': ${JSON.stringify(value)} (need non-negative integer)`
      );
    }
    return Number(t);
  }
  throw new Error(
    `${RESULT}: unparseable metric '${field}': ${JSON.stringify(value)} (need non-negative integer)`
  );
}

/**
 * Normalize a metrics object. Requires `total`. `skipped` and `todo` default
 * only when the field is absent (undefined/null), never when present-but-bad.
 * @param {unknown} raw
 * @param {string} [label]
 */
export function normalizeMetrics(raw, label = "metrics") {
  if (raw == null || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error(`${RESULT}: ${label} must be a non-null object`);
  }
  /** @type {Record<string, unknown>} */
  const o = /** @type {Record<string, unknown>} */ (raw);
  const total = parseNonNegInt(o.total, `${label}.total`);
  const skipped =
    o.skipped === undefined || o.skipped === null
      ? 0
      : parseNonNegInt(o.skipped, `${label}.skipped`);
  const todo =
    o.todo === undefined || o.todo === null
      ? 0
      : parseNonNegInt(o.todo, `${label}.todo`);
  // skip_effective = skipped + todo (both hide active coverage)
  const skip_effective = skipped + todo;
  if (skip_effective > total) {
    throw new Error(
      `${RESULT}: ${label} skip+todo (${skip_effective}) exceeds total (${total})`
    );
  }
  return { total, skipped, todo, skip_effective };
}

// ---------------------------------------------------------------------------
// Runner-output parsers
// ---------------------------------------------------------------------------

/**
 * @param {string} text
 * @returns {{ total: number, skipped: number, todo: number, skip_effective: number, source: string }}
 */
export function parseRunnerOutput(text) {
  if (typeof text !== "string") {
    throw new Error(`${RESULT}: runner output must be a string`);
  }

  // 1) Explicit machine line — preferred contract
  const explicitJson = text.match(
    /^\s*GIBSON_TEST_METRICS\s+(\{[\s\S]*?\})\s*$/m
  );
  if (explicitJson) {
    let parsed;
    try {
      parsed = JSON.parse(explicitJson[1]);
    } catch {
      throw new Error(
        `${RESULT}: GIBSON_TEST_METRICS JSON is malformed (fail closed)`
      );
    }
    const m = normalizeMetrics(parsed, "GIBSON_TEST_METRICS");
    return { ...m, source: "GIBSON_TEST_METRICS-json" };
  }

  const explicitKv = text.match(
    /^\s*GIBSON_TEST_METRICS\s+(.+?)\s*$/m
  );
  if (explicitKv) {
    const body = explicitKv[1].trim();
    if (body.startsWith("{")) {
      throw new Error(
        `${RESULT}: GIBSON_TEST_METRICS JSON is malformed (fail closed)`
      );
    }
    /** @type {Record<string, string>} */
    const fields = {};
    for (const part of body.split(/\s+/)) {
      const eq = part.indexOf("=");
      if (eq <= 0) {
        throw new Error(
          `${RESULT}: GIBSON_TEST_METRICS has malformed token ${JSON.stringify(part)}`
        );
      }
      fields[part.slice(0, eq)] = part.slice(eq + 1);
    }
    if (fields.total === undefined) {
      throw new Error(
        `${RESULT}: GIBSON_TEST_METRICS missing required field total=`
      );
    }
    const m = normalizeMetrics(
      {
        total: fields.total,
        skipped: fields.skipped,
        todo: fields.todo,
      },
      "GIBSON_TEST_METRICS"
    );
    return { ...m, source: "GIBSON_TEST_METRICS-kv" };
  }

  // 2) Vitest: "Tests  40 passed | 2 skipped (42)" / with failed/todo variants
  //    Also: "Tests  2 failed | 40 passed (42)"
  {
    const vitestBlocks = [
      ...text.matchAll(
        /Tests\s+([^\n]*?)\((\d+)\)/gi
      ),
    ];
    if (vitestBlocks.length > 0) {
      const last = vitestBlocks[vitestBlocks.length - 1];
      const body = last[1];
      const total = parseNonNegInt(last[2], "vitest.total");
      const num = (re) => {
        const m = body.match(re);
        return m ? parseNonNegInt(m[1], "vitest.part") : 0;
      };
      const skipped = num(/(\d+)\s+skipped/i);
      const todo = num(/(\d+)\s+todo/i);
      const m = normalizeMetrics({ total, skipped, todo }, "vitest");
      return { ...m, source: "vitest-summary" };
    }
  }

  // 3) Jest: "Tests:       2 skipped, 40 passed, 42 total"
  {
    const jest = text.match(
      /Tests:\s*([^\n]+)/i
    );
    if (jest && /\btotal\b/i.test(jest[1])) {
      const body = jest[1];
      const num = (re, field) => {
        const m = body.match(re);
        if (!m) return null;
        return parseNonNegInt(m[1], field);
      };
      const total = num(/(\d+)\s+total/i, "jest.total");
      if (total !== null) {
        const skipped = num(/(\d+)\s+skipped/i, "jest.skipped") ?? 0;
        const todo = num(/(\d+)\s+todo/i, "jest.todo") ?? 0;
        const m = normalizeMetrics({ total, skipped, todo }, "jest");
        return { ...m, source: "jest-summary" };
      }
    }
  }

  // 4) node:test / tap-ish counters
  {
    const testsM = text.match(/^\s*#\s*tests\s+(\d+)\s*$/im);
    if (testsM) {
      const total = parseNonNegInt(testsM[1], "node-test.tests");
      const skipM = text.match(/^\s*#\s*skip\s+(\d+)\s*$/im);
      const todoM = text.match(/^\s*#\s*todo\s+(\d+)\s*$/im);
      const skipped = skipM
        ? parseNonNegInt(skipM[1], "node-test.skip")
        : 0;
      const todo = todoM ? parseNonNegInt(todoM[1], "node-test.todo") : 0;
      const m = normalizeMetrics({ total, skipped, todo }, "node-test");
      return { ...m, source: "node-test" };
    }
  }

  // 5) TAP plan "1..N"
  {
    const plan = text.match(/^\s*1\.\.(\d+)\s*$/m);
    if (plan) {
      const total = parseNonNegInt(plan[1], "tap.plan");
      const skipLines = [
        ...text.matchAll(/^\s*(?:ok|not ok)\s+\d+.*#\s*SKIP\b/gim),
      ];
      const todoLines = [
        ...text.matchAll(/^\s*(?:ok|not ok)\s+\d+.*#\s*TODO\b/gim),
      ];
      const m = normalizeMetrics(
        {
          total,
          skipped: skipLines.length,
          todo: todoLines.length,
        },
        "tap"
      );
      return { ...m, source: "tap-plan" };
    }
  }

  throw new Error(
    `${RESULT}: could not parse test metrics from runner output (fail closed). ` +
      `Emit 'GIBSON_TEST_METRICS total=N skipped=M todo=K' or a supported summary line. ` +
      `See docs/06-quality-gates.md (test-integrity summary contract).`
  );
}

/**
 * Load metrics from a JSON file or a runner-output text file.
 * @param {string} path
 */
export function loadMetricsFile(path) {
  const abs = resolve(path);
  let text;
  try {
    text = readFileSync(abs, "utf8");
  } catch (e) {
    throw new Error(
      `${RESULT}: cannot read ${path}: ${/** @type {Error} */ (e).message}`
    );
  }
  const trimmed = text.trim();
  if (trimmed.startsWith("{")) {
    let raw;
    try {
      raw = JSON.parse(trimmed);
    } catch {
      throw new Error(`${RESULT}: metrics file ${path} is not valid JSON`);
    }
    // Baseline envelope: { test_metrics: { total, ... } } or bare metrics
    if (
      raw &&
      typeof raw === "object" &&
      raw.test_metrics &&
      typeof raw.test_metrics === "object"
    ) {
      const m = normalizeMetrics(raw.test_metrics, `${path}.test_metrics`);
      return { ...m, source: raw.test_metrics.source || "baseline-envelope" };
    }
    const m = normalizeMetrics(raw, path);
    return { ...m, source: raw.source || "metrics-json" };
  }
  return parseRunnerOutput(text);
}

// ---------------------------------------------------------------------------
// Waiver parsing — visible text only; inert; exact deltas
// ---------------------------------------------------------------------------

/**
 * Strip HTML comments so a waiver hidden in <!-- ... --> cannot authorize.
 * Unclosed comments consume to EOF (fail closed for hidden content).
 * @param {string} body
 */
export function visibleText(body) {
  return String(body ?? "").replace(/<!--[\s\S]*?(?:-->|$)/g, "");
}

/**
 * Parse waiver lines from inert PR/commit text.
 *
 * Exact accepted forms (optional leading "- "):
 *   Test-integrity: removed <n> for <reason>
 *   Test-integrity: skip +<n> for <reason>
 *   Test-integrity: removed <n>, skip +<m> for <reason>
 *
 * Near-matches (wrong label, missing for-reason, wrong sign, non-integer) are
 * reported as present-but-invalid — never as a silent miss that skips the check.
 *
 * @param {string} body
 */
export function parseWaiver(body) {
  const visible = visibleText(body);
  const lines = visible.split(/\r?\n/);

  /** @type {{ removed: number | null, skipDelta: number | null, reason: string, raw: string, valid: boolean, error?: string }[]} */
  const found = [];

  // Near-match detector: looks like a test-integrity attempt but is wrong
  const nearLabel = /^\s*-?\s*test[\s_-]*integrity\s*:/i;

  for (const line of lines) {
    if (!nearLabel.test(line)) continue;

    // Exact label required: "Test-integrity:" (case-sensitive), optional "- "
    const exact = line.match(
      /^\s*(?:-\s+)?Test-integrity:\s*(.+?)\s*$/
    );
    if (!exact) {
      found.push({
        removed: null,
        skipDelta: null,
        reason: "",
        raw: line.trim(),
        valid: false,
        error:
          "waiver label must be exactly 'Test-integrity:' (visible, case-sensitive)",
      });
      continue;
    }

    const rest = exact[1];

    // Combined: removed N, skip +M for reason
    let m = rest.match(
      /^removed\s+(0|[1-9]\d*)\s*,\s*skip\s+\+(0|[1-9]\d*)\s+for\s+(\S.*)$/
    );
    if (m) {
      found.push({
        removed: Number(m[1]),
        skipDelta: Number(m[2]),
        reason: m[3].trim(),
        raw: line.trim(),
        valid: true,
      });
      continue;
    }

    // removed N for reason
    m = rest.match(/^removed\s+(0|[1-9]\d*)\s+for\s+(\S.*)$/);
    if (m) {
      found.push({
        removed: Number(m[1]),
        skipDelta: null,
        reason: m[2].trim(),
        raw: line.trim(),
        valid: true,
      });
      continue;
    }

    // skip +N for reason
    m = rest.match(/^skip\s+\+(0|[1-9]\d*)\s+for\s+(\S.*)$/);
    if (m) {
      found.push({
        removed: null,
        skipDelta: Number(m[1]),
        reason: m[2].trim(),
        raw: line.trim(),
        valid: true,
      });
      continue;
    }

    // Present but malformed — capture common wrong-delta / near forms
    found.push({
      removed: null,
      skipDelta: null,
      reason: "",
      raw: line.trim(),
      valid: false,
      error:
        "waiver must match 'Test-integrity: removed <n> for <reason>' and/or " +
        "'Test-integrity: skip +<n> for <reason>' (exact non-negative integers, nonempty reason)",
    });
  }

  return found;
}

/**
 * Merge waiver lines into a single claim of removed + skipDelta coverage.
 * @param {ReturnType<typeof parseWaiver>} waivers
 */
export function mergeWaivers(waivers) {
  if (waivers.length === 0) {
    return {
      present: false,
      valid: false,
      removed: 0,
      skipDelta: 0,
      reasons: /** @type {string[]} */ ([]),
      raw: /** @type {string[]} */ ([]),
      errors: /** @type {string[]} */ ([]),
    };
  }
  const errors = waivers.filter((w) => !w.valid).map((w) => w.error || "invalid waiver");
  if (errors.length > 0) {
    return {
      present: true,
      valid: false,
      removed: 0,
      skipDelta: 0,
      reasons: [],
      raw: waivers.map((w) => w.raw),
      errors,
    };
  }
  let removed = 0;
  let skipDelta = 0;
  const reasons = [];
  for (const w of waivers) {
    if (w.removed != null) removed += w.removed;
    if (w.skipDelta != null) skipDelta += w.skipDelta;
    if (w.reason) reasons.push(w.reason);
  }
  // Zero-delta "waiver" with empty coverage is present but useless
  if (removed === 0 && skipDelta === 0) {
    return {
      present: true,
      valid: false,
      removed: 0,
      skipDelta: 0,
      reasons,
      raw: waivers.map((w) => w.raw),
      errors: ["waiver claims zero removed and zero skip delta"],
    };
  }
  return {
    present: true,
    valid: true,
    removed,
    skipDelta,
    reasons,
    raw: waivers.map((w) => w.raw),
    errors: [],
  };
}

// ---------------------------------------------------------------------------
// Compare
// ---------------------------------------------------------------------------

/**
 * @param {{
 *   base: { total: number, skipped?: number, todo?: number, skip_effective?: number },
 *   head: { total: number, skipped?: number, todo?: number, skip_effective?: number },
 *   waiverText?: string,
 *   trustedSource?: string,
 * }} args
 */
export function compareIntegrity({
  base,
  head,
  waiverText = "",
  trustedSource = "baseline",
}) {
  const b = normalizeMetrics(base, "base");
  const h = normalizeMetrics(head, "head");

  const removedDelta = b.total - h.total; // >0 means tests disappeared
  const skipDelta = h.skip_effective - b.skip_effective; // >0 means more hides

  const waivers = parseWaiver(waiverText);
  const waiver = mergeWaivers(waivers);

  /** @type {string[]} */
  const blockers = [];
  /** @type {string[]} */
  const notices = [];

  if (removedDelta > 0) {
    if (!waiver.valid || waiver.removed !== removedDelta) {
      if (waiver.present && !waiver.valid) {
        blockers.push(
          `${RESULT}: test total dropped by ${removedDelta} ` +
            `(${b.total} → ${h.total}) vs ${trustedSource}, but waiver is invalid: ${waiver.errors.join("; ")}`
        );
      } else if (waiver.valid && waiver.removed !== removedDelta) {
        blockers.push(
          `${RESULT}: test total dropped by ${removedDelta} ` +
            `(${b.total} → ${h.total}) vs ${trustedSource}, but waiver covers removed=${waiver.removed} (wrong delta)`
        );
      } else {
        blockers.push(
          `${RESULT}: test total dropped by ${removedDelta} ` +
            `(${b.total} → ${h.total}) vs ${trustedSource}. ` +
            `Restore the tests or add a visible waiver: ` +
            `'Test-integrity: removed ${removedDelta} for <reason>'`
        );
      }
    } else {
      notices.push(
        `${RESULT}: WAIVER accepted for removed ${removedDelta} ` +
          `(${b.total} → ${h.total}): ${waiver.reasons.join("; ")}`
      );
    }
  }

  if (skipDelta > 0) {
    if (!waiver.valid || waiver.skipDelta !== skipDelta) {
      if (waiver.present && !waiver.valid) {
        blockers.push(
          `${RESULT}: skip/todo rose by ${skipDelta} ` +
            `(${b.skip_effective} → ${h.skip_effective}) vs ${trustedSource}, but waiver is invalid: ${waiver.errors.join("; ")}`
        );
      } else if (waiver.valid && waiver.skipDelta !== skipDelta) {
        blockers.push(
          `${RESULT}: skip/todo rose by ${skipDelta} ` +
            `(${b.skip_effective} → ${h.skip_effective}) vs ${trustedSource}, but waiver covers skip=+${waiver.skipDelta} (wrong delta)`
        );
      } else {
        blockers.push(
          `${RESULT}: skip/todo rose by ${skipDelta} ` +
            `(${b.skip_effective} → ${h.skip_effective}) vs ${trustedSource}. ` +
            `Unskip the tests or add a visible waiver: ` +
            `'Test-integrity: skip +${skipDelta} for <reason>'`
        );
      }
    } else {
      notices.push(
        `${RESULT}: WAIVER accepted for skip +${skipDelta} ` +
          `(${b.skip_effective} → ${h.skip_effective}): ${waiver.reasons.join("; ")}`
      );
    }
  }

  // Malformed waiver present even when no reduction — still fail closed so
  // authors learn the format and cannot hide a future reduction behind noise.
  if (waiver.present && !waiver.valid && blockers.length === 0) {
    blockers.push(
      `${RESULT}: malformed waiver present (fail closed): ${waiver.errors.join("; ")}`
    );
  }

  // Improvements (added tests / reduced skips) always pass
  if (removedDelta < 0) {
    notices.push(
      `${RESULT}: test total rose by ${-removedDelta} (${b.total} → ${h.total}) — ok`
    );
  }
  if (skipDelta < 0) {
    notices.push(
      `${RESULT}: skip/todo fell by ${-skipDelta} (${b.skip_effective} → ${h.skip_effective}) — ok`
    );
  }
  if (removedDelta === 0 && skipDelta === 0 && blockers.length === 0) {
    notices.push(
      `${RESULT}: metrics unchanged (total=${h.total}, skip_effective=${h.skip_effective}) vs ${trustedSource}`
    );
  }

  const passed = blockers.length === 0;
  return {
    result: RESULT,
    passed,
    base: b,
    head: h,
    removedDelta: Math.max(0, removedDelta),
    skipDelta: Math.max(0, skipDelta),
    rawRemovedDelta: removedDelta,
    rawSkipDelta: skipDelta,
    waiver,
    blockers,
    notices,
    trustedSource,
  };
}

// ---------------------------------------------------------------------------
// Journal (append-only baseline regeneration audit)
// ---------------------------------------------------------------------------

/**
 * @param {{
 *   journalPath: string,
 *   oldMetrics: object,
 *   newMetrics: object,
 *   reason: string,
 *   sha?: string,
 *   timestamp?: string,
 * }} args
 */
export function appendJournal({
  journalPath,
  oldMetrics,
  newMetrics,
  reason,
  sha = "unknown",
  timestamp,
}) {
  const r = String(reason ?? "").trim();
  if (!r) {
    throw new Error(
      `${RESULT}: regeneration requires a nonempty --reason (fail closed)`
    );
  }
  const oldM = normalizeMetrics(oldMetrics, "journal.old");
  const newM = normalizeMetrics(newMetrics, "journal.new");
  const entry = {
    timestamp: timestamp || new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    sha: String(sha),
    reason: r,
    old: {
      total: oldM.total,
      skipped: oldM.skipped,
      todo: oldM.todo,
      skip_effective: oldM.skip_effective,
    },
    new: {
      total: newM.total,
      skipped: newM.skipped,
      todo: newM.todo,
      skip_effective: newM.skip_effective,
    },
  };
  const line = JSON.stringify(entry);
  const abs = resolve(journalPath);
  mkdirSync(dirname(abs), { recursive: true });
  appendFileSync(abs, line + "\n", "utf8");
  return entry;
}

/**
 * Decide whether rewriting a baseline needs an explicit regenerate flag.
 * @param {object | null} oldMetrics
 * @param {object} newMetrics
 */
export function needsRegenerateFlag(oldMetrics, newMetrics) {
  if (oldMetrics == null) return false;
  let oldM;
  try {
    oldM = normalizeMetrics(oldMetrics, "old");
  } catch {
    // Corrupt old metrics: require regenerate to overwrite deliberately
    return true;
  }
  const newM = normalizeMetrics(newMetrics, "new");
  return (
    newM.total < oldM.total || newM.skip_effective > oldM.skip_effective
  );
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function usage(exit = 2) {
  const text = `test-integrity.mjs — count-based test deletion/skip sensor (issue #70)

USAGE
  node scripts/test-integrity.mjs parse --input FILE [--out FILE]
  node scripts/test-integrity.mjs compare --base FILE --head FILE
      [--waiver-text STR | --waiver-file FILE] [--trusted-source NAME] [--json]
  node scripts/test-integrity.mjs journal-append --journal FILE
      --old FILE --new FILE --reason STR [--sha STR]

  PR/commit text is inert data. Never pass it to eval/shell.

EXAMPLES
  node scripts/test-integrity.mjs parse --input test-output.txt --out metrics.json
  node scripts/test-integrity.mjs compare --base base.json --head head.json \\
    --waiver-text 'Test-integrity: removed 2 for obsolete fixtures' \\
    --trusted-source merge-base
`;
  console.error(text);
  process.exit(exit);
}

function readFlag(args, name) {
  const i = args.indexOf(name);
  if (i < 0) return null;
  if (i + 1 >= args.length) {
    console.error(`${RESULT}: ${name} requires a value`);
    process.exit(2);
  }
  return args[i + 1];
}

function hasFlag(args, name) {
  return args.includes(name);
}

function main(argv) {
  const args = argv.slice(2);
  if (args.length === 0 || args[0] === "-h" || args[0] === "--help") {
    usage(0);
  }
  const cmd = args[0];

  try {
    if (cmd === "parse") {
      const input = readFlag(args, "--input");
      if (!input) usage();
      const out = readFlag(args, "--out");
      const text = readFileSync(resolve(input), "utf8");
      const metrics = parseRunnerOutput(text);
      const payload = JSON.stringify(metrics, null, 2) + "\n";
      if (out) writeFileSync(resolve(out), payload, "utf8");
      else process.stdout.write(payload);
      return;
    }

    if (cmd === "compare") {
      const basePath = readFlag(args, "--base");
      const headPath = readFlag(args, "--head");
      if (!basePath || !headPath) usage();
      let waiverText = readFlag(args, "--waiver-text") ?? "";
      const waiverFile = readFlag(args, "--waiver-file");
      if (waiverFile) {
        waiverText = readFileSync(resolve(waiverFile), "utf8");
      }
      const trustedSource =
        readFlag(args, "--trusted-source") || "baseline";
      const base = loadMetricsFile(basePath);
      const head = loadMetricsFile(headPath);
      const result = compareIntegrity({
        base,
        head,
        waiverText,
        trustedSource,
      });
      if (hasFlag(args, "--json")) {
        process.stdout.write(JSON.stringify(result, null, 2) + "\n");
      } else {
        for (const n of result.notices) console.log(n);
        for (const b of result.blockers) console.error(b);
        if (result.waiver.present && result.waiver.valid) {
          console.log(
            `${RESULT}: waiver lines: ${result.waiver.raw.join(" | ")}`
          );
        }
        console.log(
          `${RESULT}: ${result.passed ? "PASS" : "FAIL"} ` +
            `(total ${result.base.total}→${result.head.total}, ` +
            `skip_effective ${result.base.skip_effective}→${result.head.skip_effective}, ` +
            `source=${result.trustedSource})`
        );
      }
      process.exitCode = result.passed ? 0 : 1;
      return;
    }

    if (cmd === "journal-append") {
      const journal = readFlag(args, "--journal");
      const oldPath = readFlag(args, "--old");
      const newPath = readFlag(args, "--new");
      const reason = readFlag(args, "--reason");
      const sha = readFlag(args, "--sha") || "unknown";
      if (!journal || !oldPath || !newPath || reason == null) usage();
      const oldM = loadMetricsFile(oldPath);
      const newM = loadMetricsFile(newPath);
      const entry = appendJournal({
        journalPath: journal,
        oldMetrics: oldM,
        newMetrics: newM,
        reason,
        sha,
      });
      process.stdout.write(JSON.stringify(entry) + "\n");
      return;
    }

    console.error(`${RESULT}: unknown command ${JSON.stringify(cmd)}`);
    usage();
  } catch (e) {
    console.error(/** @type {Error} */ (e).message || String(e));
    process.exitCode = 1;
  }
}

const isMain =
  Boolean(process.argv[1]) &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  main(process.argv);
}
