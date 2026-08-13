#!/usr/bin/env node
/**
 * test-integrity.mjs — count-based test-deletion / skip-inflation sensor (issue #70)
 *
 * Compares total and skip/todo metrics against a trusted baseline. A drop in
 * total tests or a rise in skip/todo hard-fails with a `test-integrity`
 * diagnosis unless an exact, visible waiver line covers the delta. PR/commit
 * text is inert data: matched as text, never evaluated.
 *
 * Supported summary contract (runner output may carry several sources):
 *   1. Explicit line:
 *        GIBSON_TEST_METRICS total=<n> skipped=<n> todo=<n>
 *      or JSON: GIBSON_TEST_METRICS {"total":n,"skipped":n,"todo":n}
 *   2. Vitest-style:  Tests  N passed | M skipped (T)
 *   3. Jest-style:    Tests:  M skipped, N passed, T total
 *   4. node:test:     # tests T / # skip M or # skipped M / # todo K
 *   5. TAP plan:      1..T  (top-level only) plus ok N # SKIP / # TODO
 *
 * Explicit lines do **not** outrank runner summaries. Every explicit line
 * (KV or JSON) and every matching native summary block/plan/counter is
 * collected — never first-match or last-match only. If any two sources
 * disagree on total/skipped/todo the parse fails closed so stdout cannot
 * self-authorize head metrics (fake total=N then honest total=M; conflicting
 * repeated Jest/Vitest/node:test/TAP summaries). Counters from different
 * repeated native blocks are never mixed. Within one node:test `# tests`
 * region every `# skip` / `# todo` counter is collected (identical may agree;
 * any disagreement fails closed — never first-match). TAP SKIP/TODO result
 * lines bind to the owning **top-level** plan region (plan-at-end: since
 * previous plan through current plan; plan-at-start when no pre-plan results);
 * indented nested plans (node:test `describe` subtests) are not whole-run
 * totals. Hierarchical TAP (any indented plan) skips TAP plan metrics so
 * leaf counts come from `# tests` / explicit lines. Ambiguous ownership fails
 * closed rather than inventing a metric. A single source (explicit alone or
 * summary alone) is fine; identical multi-line metrics agree and pass.
 *
 * Unparseable, negative, non-integer, or non-safe-integer metrics fail closed
 * (never become 0; values beyond Number.MAX_SAFE_INTEGER are rejected).
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

import {
  readFileSync,
  writeFileSync,
  appendFileSync,
  mkdirSync,
  realpathSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// inlined from lib/args.mjs — this file must stay single-file (vendored by gibson-gate.yml sparse-checkout)
function dieUsage(msg) {
  console.error(msg);
  process.exit(2);
}

function unknownFlag(flag) {
  dieUsage(`unknown flag: ${flag}`);
}

function readFlag(args, name) {
  const i = args.indexOf(name);
  if (i < 0) return null;
  if (i + 1 >= args.length) {
    dieUsage(`${name} requires a value`);
  }
  // Consume the next token verbatim — a value may look like a flag
  // (`--waiver-text '--documented waiver'`). Missing only when i+1 >= length.
  return args[i + 1];
}

function hasFlag(args, name) {
  return args.includes(name);
}

function rejectUnknownFlags(argv, allowed, opts = {}) {
  const allow = new Set(allowed);
  const valueFlags = new Set(
    opts.valueFlags ||
      [...allow].filter((f) => f !== "-h" && f !== "--help" && f !== "--json")
  );
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--") break;
    if (a.startsWith("-") && a !== "-") {
      if (!allow.has(a)) unknownFlag(a);
      if (valueFlags.has(a) && i + 1 < argv.length) {
        i += 1;
      }
    }
  }
}

/** Resolve symlinks so isMain works when the helper is copied into /tmp (macOS /var → /private/var). */
function realpathOrResolve(p) {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
}

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
    // Reject non-integers, negatives, and values outside the safe-integer range
    // so precision loss cannot mask a real delta (e.g. 2^53+1 → 2^53).
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error(
        `${RESULT}: unparseable metric '${field}': ${JSON.stringify(value)} ` +
          `(need non-negative Number.isSafeInteger; values beyond ±2^53-1 lose precision)`
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
    // BigInt round-trip rejects strings that JS Number cannot represent exactly
    // (e.g. "9007199254740993" → Number would collapse to 9007199254740992).
    let bi;
    try {
      bi = BigInt(t);
    } catch {
      throw new Error(
        `${RESULT}: unparseable metric '${field}': ${JSON.stringify(value)} (need non-negative integer)`
      );
    }
    if (bi < 0n || bi > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new Error(
        `${RESULT}: unparseable metric '${field}': ${JSON.stringify(value)} ` +
          `(exceeds Number.MAX_SAFE_INTEGER; safe integer required to avoid precision loss)`
      );
    }
    return Number(bi);
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
 * Fingerprint metrics for multi-source agreement (total/skipped/todo only).
 * @param {{ total: number, skipped: number, todo: number }} m
 */
function metricsKey(m) {
  return `${m.total}|${m.skipped}|${m.todo}`;
}

/**
 * Collect every counter match in a text region. Absent → 0. Identical values
 * may agree; any disagreement fails closed (never first-match / last-match).
 * @param {string} block
 * @param {RegExp} re  must be global; capture group 1 is the integer
 * @param {string} field  label for errors (e.g. node-test#1.skip)
 * @returns {number}
 */
function collectAgreeingCounter(block, re, field) {
  const matches = [...block.matchAll(re)];
  if (matches.length === 0) return 0;
  /** @type {number[]} */
  const values = [];
  for (let i = 0; i < matches.length; i++) {
    values.push(parseNonNegInt(matches[i][1], `${field}#${i + 1}`));
  }
  const uniq = new Set(values);
  if (uniq.size > 1) {
    throw new Error(
      `${RESULT}: conflicting ${field} counters in runner output (fail closed; ` +
        `never first-match): ${[...uniq].join(" vs ")}. ` +
        `Every counter in a summary region must agree.`
    );
  }
  return values[0];
}

/** @param {{ index?: number, 0: string }} m */
function matchEnd(m) {
  return (m.index ?? 0) + m[0].length;
}

/**
 * Count TAP result lines carrying # SKIP / # TODO inside [start, end).
 * @param {string} text
 * @param {number} start
 * @param {number} end
 * @param {'SKIP' | 'TODO'} kind
 */
function countTapDirectivesInRange(text, start, end, kind) {
  const region = text.slice(start, end);
  const re =
    kind === "SKIP"
      ? /^\s*(?:ok|not ok)\s+\d+.*#\s*SKIP\b/gim
      : /^\s*(?:ok|not ok)\s+\d+.*#\s*TODO\b/gim;
  return [...region.matchAll(re)].length;
}

/**
 * True when any TAP result line (ok/not ok N) falls in [start, end).
 * @param {string} text
 * @param {number} start
 * @param {number} end
 */
function hasTapResultInRange(text, start, end) {
  const region = text.slice(start, end);
  return /^\s*(?:ok|not ok)\s+\d+/im.test(region);
}

/**
 * Parse one explicit GIBSON_TEST_METRICS body (KV or JSON).
 * @param {string} body
 * @param {number} index 1-based line index among explicit lines
 * @returns {{ total: number, skipped: number, todo: number, skip_effective: number, source: string }}
 */
function parseExplicitMetricsBody(body, index) {
  const label = `GIBSON_TEST_METRICS#${index}`;
  const trimmed = body.trim();
  if (trimmed.startsWith("{")) {
    let parsed;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      throw new Error(
        `${RESULT}: GIBSON_TEST_METRICS JSON is malformed (fail closed)`
      );
    }
    const m = normalizeMetrics(parsed, label);
    return { ...m, source: `GIBSON_TEST_METRICS-json#${index}` };
  }
  /** @type {Record<string, string>} */
  const fields = {};
  for (const part of trimmed.split(/\s+/)) {
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
    label
  );
  return { ...m, source: `GIBSON_TEST_METRICS-kv#${index}` };
}

/**
 * Parse every recognized metric source from runner output. **Every** explicit
 * GIBSON_TEST_METRICS line (KV or JSON) **and every** Vitest/Jest/node:test/TAP
 * summary block/plan/counter is collected — none is privileged, and first/last
 * match is never used for natives either. If two sources disagree on
 * total/skipped/todo the parse fails closed so stdout cannot self-authorize
 * head metrics (e.g. fake total=10 followed by honest total=7 must not parse
 * as 10; repeated Jest/Vitest/node:test/TAP summaries that conflict likewise).
 * Counters from different repeated native blocks are never mixed into one
 * fabricated metric. node:test regions collect every `# skip`/`# todo` (not
 * first-match); TAP SKIP/TODO bind to the owning top-level plan region.
 * Indented nested TAP plans are never whole-run totals (node:test describe).
 *
 * @param {string} text
 * @returns {{ total: number, skipped: number, todo: number, skip_effective: number, source: string }}
 */
export function parseRunnerOutput(text) {
  if (typeof text !== "string") {
    throw new Error(`${RESULT}: runner output must be a string`);
  }

  /** @type {{ total: number, skipped: number, todo: number, skip_effective: number, source: string }[]} */
  const found = [];

  // 1) Every explicit machine line — vendor-blind contract, not privileged.
  //    Collect all matches (never first-only): duplicate/conflicting lines are
  //    reconciled by multi-source agreement below.
  {
    const explicitLines = [
      ...text.matchAll(/^\s*GIBSON_TEST_METRICS\s+(.+?)\s*$/gm),
    ];
    let idx = 0;
    for (const match of explicitLines) {
      idx += 1;
      found.push(parseExplicitMetricsBody(match[1], idx));
    }
  }

  // 2) Vitest: "Tests  40 passed | 2 skipped (42)" / with failed/todo variants
  //    Also: "Tests  2 failed | 40 passed (42)"
  //    Collect every block (never last-only): a fake trailing summary must not
  //    hide an honest earlier total, and vice versa.
  {
    const vitestBlocks = [
      ...text.matchAll(/Tests\s+([^\n]*?)\((\d+)\)/gi),
    ];
    let idx = 0;
    for (const block of vitestBlocks) {
      idx += 1;
      const body = block[1];
      const total = parseNonNegInt(block[2], `vitest#${idx}.total`);
      const num = (re, field) => {
        const m = body.match(re);
        return m ? parseNonNegInt(m[1], field) : 0;
      };
      const skipped = num(/(\d+)\s+skipped/i, `vitest#${idx}.skipped`);
      const todo = num(/(\d+)\s+todo/i, `vitest#${idx}.todo`);
      const m = normalizeMetrics({ total, skipped, todo }, `vitest#${idx}`);
      found.push({
        ...m,
        source: vitestBlocks.length === 1 ? "vitest-summary" : `vitest-summary#${idx}`,
      });
    }
  }

  // 3) Jest: "Tests:       2 skipped, 40 passed, 42 total"
  //    Collect every summary line with a total (never first-only).
  {
    const jestLines = [...text.matchAll(/Tests:\s*([^\n]+)/gi)].filter((j) =>
      /\btotal\b/i.test(j[1])
    );
    let idx = 0;
    for (const jest of jestLines) {
      idx += 1;
      const body = jest[1];
      const label = `jest#${idx}`;
      const num = (re, field) => {
        const m = body.match(re);
        if (!m) return null;
        return parseNonNegInt(m[1], field);
      };
      const total = num(/(\d+)\s+total/i, `${label}.total`);
      if (total === null) continue;
      const skipped = num(/(\d+)\s+skipped/i, `${label}.skipped`) ?? 0;
      const todo = num(/(\d+)\s+todo/i, `${label}.todo`) ?? 0;
      const m = normalizeMetrics({ total, skipped, todo }, label);
      found.push({
        ...m,
        source:
          jestLines.length === 1 ? "jest-summary" : `jest-summary#${idx}`,
      });
    }
  }

  // 4) node:test counters — every `# tests N` region, not first-only.
  //    Associate `# skip` / `# todo` with the enclosing `# tests` block so
  //    counters from different repeated blocks are never mixed into one metric.
  //    Within a region, collect *every* `# skip` / `# todo` line: identical
  //    values may agree; any disagreement fails closed (never first-match).
  {
    const testsMatches = [
      ...text.matchAll(/^\s*#\s*tests\s+(\d+)\s*$/gim),
    ];
    if (testsMatches.length > 0) {
      for (let i = 0; i < testsMatches.length; i++) {
        const testsM = testsMatches[i];
        const blockStart = testsM.index ?? 0;
        const blockEnd =
          i + 1 < testsMatches.length
            ? (testsMatches[i + 1].index ?? text.length)
            : text.length;
        const block = text.slice(blockStart, blockEnd);
        const label = `node-test#${i + 1}`;
        const total = parseNonNegInt(testsM[1], `${label}.tests`);
        // Node's TAP reporter prints `# skipped N`; fixtures may use `# skip N`.
        // Use (?:ped)? — plain `skipped?` is only `skippe` + optional `d`.
        const skipped = collectAgreeingCounter(
          block,
          /^\s*#\s*skip(?:ped)?\s+(\d+)\s*$/gim,
          `${label}.skip`
        );
        const todo = collectAgreeingCounter(
          block,
          /^\s*#\s*todo\s+(\d+)\s*$/gim,
          `${label}.todo`
        );
        const m = normalizeMetrics({ total, skipped, todo }, label);
        found.push({
          ...m,
          source:
            testsMatches.length === 1 ? "node-test" : `node-test#${i + 1}`,
        });
      }
    }
  }

  // 5) TAP plan "1..N" — only **top-level** plans (column 0; no leading
  //    whitespace) are whole-run metrics. Indented nested plans (Node's
  //    describe() subtests: `    1..2` under a suite) are structural and must
  //    not be collected as run totals — otherwise nested `1..2` + top-level
  //    `1..1` + node:test `# tests 2` falsely conflicts.
  //
  //    Hierarchical TAP (any indented plan present): skip TAP plan metrics
  //    entirely. Leaf totals come from node:test `# tests` / `# skip` /
  //    `# todo` (or explicit GIBSON_TEST_METRICS). Top-level-only streams
  //    still collect every repeated top-level plan (identical agree; conflict
  //    fail closed). SKIP/TODO bind to the owning top-level plan region
  //    (plan-at-end / plan-at-start / ambiguous fails closed) as before.
  {
    const hasNestedPlans = /^[ \t]+1\.\.\d+\s*$/m.test(text);
    const plans = hasNestedPlans
      ? []
      : [...text.matchAll(/^1\.\.(\d+)\s*$/gm)];
    if (plans.length > 0) {
      /** @type {{ start: number, end: number }[]} */
      let regions;
      if (plans.length === 1) {
        regions = [{ start: 0, end: text.length }];
      } else {
        const firstStart = plans[0].index ?? 0;
        const lastEnd = matchEnd(plans[plans.length - 1]);
        const resultsBeforeFirst = hasTapResultInRange(text, 0, firstStart);
        const resultsAfterLast = hasTapResultInRange(
          text,
          lastEnd,
          text.length
        );
        if (resultsBeforeFirst && resultsAfterLast) {
          throw new Error(
            `${RESULT}: ambiguous TAP plan-region ownership (fail closed; ` +
              `result lines both before the first plan and after the last). ` +
              `Cannot bind SKIP/TODO without inventing a metric.`
          );
        }
        // Plan-at-end when any result precedes the first plan; otherwise
        // plan-at-start (results after each plan until the next / EOF).
        const planAtEnd = resultsBeforeFirst;
        regions = plans.map((plan, i) => {
          if (planAtEnd) {
            const start = i === 0 ? 0 : matchEnd(plans[i - 1]);
            const end = matchEnd(plan);
            return { start, end };
          }
          const start = plan.index ?? 0;
          const end =
            i + 1 < plans.length
              ? (plans[i + 1].index ?? text.length)
              : text.length;
          return { start, end };
        });
      }
      for (let i = 0; i < plans.length; i++) {
        const plan = plans[i];
        const label = `tap#${i + 1}`;
        const total = parseNonNegInt(plan[1], `${label}.plan`);
        const { start, end } = regions[i];
        const skipped = countTapDirectivesInRange(text, start, end, "SKIP");
        const todo = countTapDirectivesInRange(text, start, end, "TODO");
        const m = normalizeMetrics({ total, skipped, todo }, label);
        found.push({
          ...m,
          source: plans.length === 1 ? "tap-plan" : `tap-plan#${i + 1}`,
        });
      }
    }
  }

  if (found.length === 0) {
    throw new Error(
      `${RESULT}: could not parse test metrics from runner output (fail closed). ` +
        `Emit 'GIBSON_TEST_METRICS total=N skipped=M todo=K' or a supported summary line. ` +
        `See docs/06-quality-gates.md (test-integrity summary contract).`
    );
  }

  // Multi-source agreement: a test's stdout must never self-authorize head
  // metrics by printing a fake GIBSON_TEST_METRICS line next to a real summary,
  // or by repeating conflicting native runner summaries (first/last-only parsers
  // would hide a real drop under a future trusted grader).
  const keys = new Map();
  for (const m of found) {
    const k = metricsKey(m);
    if (!keys.has(k)) keys.set(k, []);
    keys.get(k).push(m.source);
  }
  if (keys.size > 1) {
    const detail = [...keys.entries()]
      .map(([k, sources]) => {
        const [total, skipped, todo] = k.split("|");
        return `${sources.join("+")}→total=${total} skipped=${skipped} todo=${todo}`;
      })
      .join("; ");
    throw new Error(
      `${RESULT}: conflicting metric sources in runner output (fail closed; ` +
        `untrusted explicit lines do not outrank runner summaries; ` +
        `repeated native summaries must agree): ${detail}. ` +
        `A test's stdout must not self-authorize head metrics.`
    );
  }

  const primary = found[0];
  if (found.length > 1) {
    // Agreeing sources: label them so the audit trail shows multi-source consensus
    const sources = found.map((m) => m.source).join("+");
    return { ...primary, source: sources };
  }
  return primary;
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
  // Claimed waiver dimensions must equal max(actual_delta, 0) on BOTH axes.
  // Overclaiming the unused axis (e.g. skip +999 when skip did not rise) fails.
  const actualRemoved = Math.max(0, removedDelta);
  const actualSkip = Math.max(0, skipDelta);

  const waivers = parseWaiver(waiverText);
  const waiver = mergeWaivers(waivers);

  /** @type {string[]} */
  const blockers = [];
  /** @type {string[]} */
  const notices = [];

  if (actualRemoved === 0 && actualSkip === 0) {
    // No integrity reduction (totals did not drop; skips did not rise).
    // A waiver that claims a reduction is noise / gaming and fails closed.
    if (waiver.present && !waiver.valid) {
      blockers.push(
        `${RESULT}: malformed waiver present (fail closed): ${waiver.errors.join("; ")}`
      );
    } else if (waiver.present && waiver.valid) {
      blockers.push(
        `${RESULT}: waiver claims removed=${waiver.removed}, skip=+${waiver.skipDelta} ` +
          `but there is no integrity reduction (total ${b.total}→${h.total}, ` +
          `skip_effective ${b.skip_effective}→${h.skip_effective}) ` +
          `vs ${trustedSource} — waiver with no integrity reduction fails`
      );
    } else if (removedDelta === 0 && skipDelta === 0) {
      notices.push(
        `${RESULT}: metrics unchanged (total=${h.total}, skip_effective=${h.skip_effective}) vs ${trustedSource}`
      );
    }
    // Improvements (added tests / reduced skips) are noticed below.
  } else if (!waiver.present) {
    if (actualRemoved > 0) {
      blockers.push(
        `${RESULT}: test total dropped by ${actualRemoved} ` +
          `(${b.total} → ${h.total}) vs ${trustedSource}. ` +
          `Restore the tests or add a visible waiver: ` +
          `'Test-integrity: removed ${actualRemoved} for <reason>'`
      );
    }
    if (actualSkip > 0) {
      blockers.push(
        `${RESULT}: skip/todo rose by ${actualSkip} ` +
          `(${b.skip_effective} → ${h.skip_effective}) vs ${trustedSource}. ` +
          `Unskip the tests or add a visible waiver: ` +
          `'Test-integrity: skip +${actualSkip} for <reason>'`
      );
    }
  } else if (!waiver.valid) {
    if (actualRemoved > 0) {
      blockers.push(
        `${RESULT}: test total dropped by ${actualRemoved} ` +
          `(${b.total} → ${h.total}) vs ${trustedSource}, but waiver is invalid: ${waiver.errors.join("; ")}`
      );
    }
    if (actualSkip > 0) {
      blockers.push(
        `${RESULT}: skip/todo rose by ${actualSkip} ` +
          `(${b.skip_effective} → ${h.skip_effective}) vs ${trustedSource}, but waiver is invalid: ${waiver.errors.join("; ")}`
      );
    }
    if (blockers.length === 0) {
      blockers.push(
        `${RESULT}: malformed waiver present (fail closed): ${waiver.errors.join("; ")}`
      );
    }
  } else {
    // Valid waiver present: both claimed dimensions must equal max(actual, 0).
    if (waiver.removed !== actualRemoved) {
      blockers.push(
        `${RESULT}: test total dropped by ${actualRemoved} ` +
          `(${b.total} → ${h.total}) vs ${trustedSource}, but waiver covers removed=${waiver.removed} (wrong delta)`
      );
    } else if (actualRemoved > 0) {
      notices.push(
        `${RESULT}: WAIVER accepted for removed ${actualRemoved} ` +
          `(${b.total} → ${h.total}): ${waiver.reasons.join("; ")}`
      );
    }
    if (waiver.skipDelta !== actualSkip) {
      blockers.push(
        `${RESULT}: skip/todo rose by ${actualSkip} ` +
          `(${b.skip_effective} → ${h.skip_effective}) vs ${trustedSource}, but waiver covers skip=+${waiver.skipDelta} (wrong delta)`
      );
    } else if (actualSkip > 0) {
      notices.push(
        `${RESULT}: WAIVER accepted for skip +${actualSkip} ` +
          `(${b.skip_effective} → ${h.skip_effective}): ${waiver.reasons.join("; ")}`
      );
    }
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

  const passed = blockers.length === 0;
  return {
    result: RESULT,
    passed,
    base: b,
    head: h,
    removedDelta: actualRemoved,
    skipDelta: actualSkip,
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

function main(argv) {
  const args = argv.slice(2);
  if (args.length === 0 || args[0] === "-h" || args[0] === "--help") {
    usage(0);
  }
  const cmd = args[0];

  try {
    if (cmd === "parse") {
      rejectUnknownFlags(args, ["--input", "--out", "-h", "--help"]);
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
      rejectUnknownFlags(args, [
        "--base",
        "--head",
        "--waiver-text",
        "--waiver-file",
        "--trusted-source",
        "--json",
        "-h",
        "--help",
      ]);
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
      rejectUnknownFlags(args, [
        "--journal",
        "--old",
        "--new",
        "--reason",
        "--sha",
        "-h",
        "--help",
      ]);
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

    // Unknown command — if it looks like a flag, say so (#192).
    if (cmd.startsWith("-")) {
      console.error(`unknown flag: ${cmd}`);
      process.exit(2);
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
  realpathOrResolve(process.argv[1]) ===
    realpathOrResolve(fileURLToPath(import.meta.url));

if (isMain) {
  main(process.argv);
}
