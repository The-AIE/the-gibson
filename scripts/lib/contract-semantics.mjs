/**
 * Semantic helpers for contract-authority.mjs (#208).
 *
 * Parses YAML-ish playbook frontmatter lists, AGENTS.md enumerations, and
 * obligation polarity/modal/topic shapes. Comparison is set-equality of
 * normalized objects — not substring `includes()` of keywords.
 */

export const FRONTMATTER_RE = /^---\r?\n([\s\S]*?)\r?\n---/;

const STOP = new Set([
  "a",
  "an",
  "the",
  "and",
  "or",
  "of",
  "to",
  "for",
  "in",
  "on",
  "at",
  "as",
  "by",
  "with",
  "from",
  "vs",
  "per",
  "via",
]);

const NEGATION_RE =
  /\b(never|not|no|without|don't|do not|must not|cannot|can't|skip|skipping|except)\b/g;

export function collapseWs(s) {
  return String(s).replace(/\s+/g, " ").trim();
}

export function parseFrontmatter(text) {
  const m = FRONTMATTER_RE.exec(text);
  if (!m) return { hasFrontmatter: false, body: text, raw: "" };
  return { hasFrontmatter: true, body: text.slice(m[0].length), raw: m[1] };
}

export function frontmatterHasOperativeKeys(fmRaw) {
  return /^(gates|forbidden|outputs)\s*:/m.test(fmRaw);
}

/**
 * Parse a top-level YAML sequence under `key:` into string items.
 * Supports `- item`, quoted items, and indented continuations.
 */
export function parseYamlList(fmRaw, key) {
  if (typeof fmRaw !== "string" || !key) return [];
  const lines = fmRaw.split(/\r?\n/);
  const items = [];
  let inKey = false;
  const keyRe = new RegExp(`^${key}\\s*:\\s*(.*)$`);
  for (const line of lines) {
    const top = /^[A-Za-z0-9_-]+\s*:/.test(line);
    if (top) {
      const km = keyRe.exec(line);
      inKey = Boolean(km);
      if (inKey) {
        const rest = km[1].trim();
        if (rest.startsWith("[") && rest.endsWith("]")) {
          const inner = rest.slice(1, -1);
          for (const part of inner.split(",")) {
            const v = unquote(part.trim());
            if (v) items.push(v);
          }
        } else if (rest && rest !== "|" && rest !== ">") {
          items.push(unquote(rest));
        }
      }
      continue;
    }
    if (!inKey) continue;
    const dash = /^\s+-\s+(.*)$/.exec(line);
    if (dash) {
      items.push(unquote(dash[1].trim()));
      continue;
    }
    if (/^\s+\S/.test(line) && items.length) {
      items[items.length - 1] = collapseWs(
        `${items[items.length - 1]} ${line.trim()}`
      );
    }
  }
  return items.filter((s) => s.length > 0);
}

function unquote(s) {
  if (
    (s.startsWith('"') && s.endsWith('"')) ||
    (s.startsWith("'") && s.endsWith("'"))
  ) {
    return s.slice(1, -1);
  }
  return s;
}

export function normalizeObligation(s) {
  return collapseWs(String(s))
    .replace(/[`*_]/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/\(docs\/[^)]*\)/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

export function contentTokens(normalized) {
  return normalized
    .replace(/[^a-z0-9\s/+.-]/g, " ")
    .split(/\s+/)
    .map((w) => w.trim())
    .filter((w) => w.length > 1 && !STOP.has(w) && !isNegationWord(w) && !isModalWord(w));
}

function isNegationWord(w) {
  return /^(never|not|no|without|don't|cannot|can't|skip|skipping|except)$/.test(w);
}

function isModalWord(w) {
  return /^(must|shall|required|always|should|prefer|recommended|may|optional|ideally)$/.test(
    w
  );
}

export function countNegations(normalized) {
  const m = String(normalized).match(NEGATION_RE);
  return m ? m.length : 0;
}

export function detectModal(normalized) {
  const n = String(normalized);
  if (/\b(must not|must|shall|required|always|hard fail|blocks?)\b/.test(n)) {
    return "must";
  }
  if (/\b(should|prefer|recommended)\b/.test(n)) return "should";
  if (/\b(may|optional|try to|when possible|ideally)\b/.test(n)) return "may";
  return "none";
}

const MODAL_RANK = { must: 3, none: 2, should: 1, may: 0 };

export function semanticShape(text, bucket) {
  const normalized = normalizeObligation(text);
  const tokens = contentTokens(normalized);
  const negCount = countNegations(normalized);
  const bucketPolarity = bucket === "forbidden" ? 1 : 0;
  const polarity = (bucketPolarity + negCount) % 2 === 1 ? "prohibit" : "require";
  const modal = detectModal(normalized);
  return {
    normalized,
    polarity,
    modal,
    topic: tokens.slice().sort().join(" "),
    tokens,
  };
}

export function topicOverlap(aTokens, bTokens) {
  if (!aTokens.length || !bTokens.length) return 0;
  const a = new Set(aTokens);
  const b = new Set(bTokens);
  let inter = 0;
  for (const t of a) if (b.has(t)) inter += 1;
  const union = new Set([...a, ...b]).size;
  return union === 0 ? 0 : inter / union;
}

/**
 * Compare authority vs playbook obligation lists for one bucket.
 * Returns structured findings; empty array means exact semantic parity.
 */
export function diffObligationLists(role, bucket, authorityItems, playbookItems) {
  const findings = [];
  const auth = (authorityItems || []).map((text, i) => ({
    i,
    text,
    shape: semanticShape(text, bucket),
  }));
  const pb = (playbookItems || []).map((text, i) => ({
    i,
    text,
    shape: semanticShape(text, bucket),
  }));

  const authNorm = new Map();
  for (const item of auth) {
    if (authNorm.has(item.shape.normalized)) {
      findings.push({
        code: "E_ROLE_DUPLICATE",
        message: `${role} ${bucket}: duplicate authority obligation: ${item.text}`,
      });
    }
    authNorm.set(item.shape.normalized, item);
  }
  const pbNorm = new Map();
  for (const item of pb) {
    if (pbNorm.has(item.shape.normalized)) {
      findings.push({
        code: "E_ROLE_DUPLICATE",
        message: `${role} ${bucket}: duplicate playbook obligation: ${item.text}`,
      });
    }
    pbNorm.set(item.shape.normalized, item);
  }

  const matchedPb = new Set();
  const matchedAuth = new Set();

  for (const [norm, aItem] of authNorm) {
    if (pbNorm.has(norm)) {
      matchedPb.add(norm);
      matchedAuth.add(norm);
      const pItem = pbNorm.get(norm);
      if (aItem.shape.polarity !== pItem.shape.polarity) {
        findings.push({
          code: "E_ROLE_NEGATION",
          message: `${role} ${bucket}: polarity flipped for "${aItem.text}"`,
        });
      }
      if (MODAL_RANK[pItem.shape.modal] < MODAL_RANK[aItem.shape.modal]) {
        findings.push({
          code: "E_ROLE_WEAKENING",
          message: `${role} ${bucket}: modal weakened for "${aItem.text}" (${aItem.shape.modal} → ${pItem.shape.modal})`,
        });
      }
    }
  }

  const unmatchedAuth = [...authNorm.values()].filter(
    (x) => !matchedAuth.has(x.shape.normalized)
  );
  const unmatchedPb = [...pbNorm.values()].filter(
    (x) => !matchedPb.has(x.shape.normalized)
  );

  for (const aItem of unmatchedAuth) {
    let best = null;
    let bestScore = 0;
    for (const pItem of unmatchedPb) {
      const score = topicOverlap(aItem.shape.tokens, pItem.shape.tokens);
      if (score > bestScore) {
        bestScore = score;
        best = pItem;
      }
    }
    if (best && bestScore >= 0.45) {
      const skipFlip =
        /\bskip(?:ping)?\b/.test(best.shape.normalized) !==
        /\bskip(?:ping)?\b/.test(aItem.shape.normalized);
      if (aItem.shape.polarity !== best.shape.polarity || skipFlip) {
        findings.push({
          code: "E_ROLE_NEGATION",
          message: `${role} ${bucket}: obligation negated while retaining topic ("${aItem.text}" vs "${best.text}")`,
        });
      } else if (MODAL_RANK[best.shape.modal] < MODAL_RANK[aItem.shape.modal]) {
        findings.push({
          code: "E_ROLE_WEAKENING",
          message: `${role} ${bucket}: obligation weakened while retaining topic ("${aItem.text}" vs "${best.text}")`,
        });
      } else {
        findings.push({
          code: "E_ROLE_RENAME",
          message: `${role} ${bucket}: obligation renamed ("${aItem.text}" vs "${best.text}")`,
        });
      }
      unmatchedPb.splice(unmatchedPb.indexOf(best), 1);
    } else {
      findings.push({
        code: "E_ROLE_OMISSION",
        message: `${role} ${bucket}: playbook omits authority obligation: ${aItem.text}`,
        text: aItem.text,
      });
    }
  }
  for (const pItem of unmatchedPb) {
    findings.push({
      code: "E_ROLE_ADDITION",
      message: `${role} ${bucket}: playbook adds obligation absent from authority: ${pItem.text}`,
      text: pItem.text,
    });
  }
  return findings;
}

export function extractMarkdownTable(text, headerCells) {
  const lines = String(text).split(/\r?\n/);
  const want = headerCells.map((h) => h.toLowerCase());
  for (let i = 0; i < lines.length - 1; i++) {
    if (!lines[i].includes("|")) continue;
    const cells = splitTableRow(lines[i]);
    if (cells.length !== want.length) continue;
    const got = cells.map((c) => c.toLowerCase());
    if (got.every((c, idx) => c === want[idx])) {
      const rows = [];
      for (let j = i + 2; j < lines.length; j++) {
        if (!lines[j].includes("|")) break;
        const row = splitTableRow(lines[j]);
        if (row.length === 0) break;
        rows.push(row);
      }
      return rows;
    }
  }
  return [];
}

function splitTableRow(line) {
  const t = line.trim();
  if (!t.startsWith("|")) return [];
  return t
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((c) => collapseWs(c));
}

export function extractSection(text, heading) {
  const re = new RegExp(`^##\\s+${escapeRe(heading)}\\s*$`, "m");
  const m = re.exec(text);
  if (!m) return "";
  const start = m.index + m[0].length;
  const rest = text.slice(start);
  const next = rest.search(/^##\s+/m);
  return next === -1 ? rest : rest.slice(0, next);
}

function escapeRe(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function extractNumberedItems(sectionText) {
  const out = [];
  const re = /^\s*\d+\.\s+\*\*([^*]+)\*\*/gm;
  let m;
  while ((m = re.exec(sectionText)) !== null) {
    out.push(m[1].trim());
  }
  return out;
}

export const EXPECTED_GATE_IDS = Array.from({ length: 16 }, (_, i) => `G${i + 1}`);
export const EXPECTED_ROLES = [
  "planner",
  "decomposer",
  "builder",
  "test-engineer",
  "reviewer",
  "ux-evaluator",
  "security",
  "release",
  "historian",
];
export const EXPECTED_TIERS = ["A", "B", "C"];
export const EXPECTED_STAGES = [
  "PLAN",
  "DECOMPOSE",
  "BUILD",
  "TEST",
  "REVIEW",
  "UX-EVAL",
  "SECURITY",
  "MERGE",
  "DEPLOY+VERIFY",
  "RETRO",
];
export const EXPECTED_PAIRS = [
  ["builder", "reviewer"],
  ["builder", "ux-evaluator"],
  ["reviewer", "ux-evaluator"],
];
export const EXPECTED_LENSES = [
  "Correctness",
  "Security",
  "Consent / PII",
  "Money",
  "Performance",
  "Maintainability",
];
export const EXPECTED_SECURITY_LAYERS = [
  "Secrets",
  "SAST",
  "Supply chain",
  "AuthZ matrix",
  "DAST",
  "Adversarial review",
  "AI-surface / injection review",
  "Runtime posture",
];
export const EXPECTED_ASK_FIELDS = [
  "What I'm asking",
  "What it does",
  "Why it should be done",
  "The risks",
];
export const EXPECTED_DELIVERY_STEPS = ["audit", "dry-run", "explicit human apply"];
export const EXPECTED_SELF_MOD_CONTROLS = [
  "human gates",
  "Tier definitions",
  "hard-fail security layers",
];

/**
 * Operative G-number list entries in the Human gates section.
 * Matches common Markdown list forms (unordered, numbered, bold/plain,
 * em-dash/colon/hyphen separators). Narrative mentions of G-numbers in
 * running prose or table cells are not entries.
 */
const OPERATIVE_GATE_LINE_RE =
  /^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?(?:\*\*|__|`)?(G\d+)(?:\*\*|__|`)?(?:[ \t]*⛔)?[ \t]*(?:[—–:−-][ \t]*)?(.*)$/;

/**
 * Structural closed-list parse of human-gate list entries. Multiplicity
 * is preserved; unexpected IDs such as G17 are visible; duplicates are
 * not collapsed. Order is the document order of operative entries.
 */
export function parseHumanGateEntries(agentsText) {
  const section = extractSection(agentsText, "Human gates (the ONLY reasons to stop)");
  const hay = section || agentsText;
  const entries = [];
  for (const line of String(hay).split(/\r?\n/)) {
    const m = OPERATIVE_GATE_LINE_RE.exec(line);
    if (!m) continue;
    entries.push({
      id: m[1],
      summary: collapseWs(m[2] || ""),
      index: entries.length,
    });
  }
  return entries;
}

/** Authoritative role table (`| Role | Out | Forbidden |`). */
export function parseRoleTable(agentsText) {
  return parseRoleTableContracts(agentsText).map((r) => r.role);
}

/** Exact AGENTS.md role-table summaries for comparison with the activated mirror. */
export function parseRoleTableContracts(agentsText) {
  const rows = extractMarkdownTable(agentsText, ["Role", "Out", "Forbidden"]);
  return rows
    .map((r) => ({
      role: collapseWs(String(r[0] || "").replace(/[`*]/g, "")),
      out: collapseWs(String(r[1] || "").replace(/[`*]/g, "")),
      forbidden: collapseWs(String(r[2] || "").replace(/[`*]/g, "")),
    }))
    .filter((r) => r.role);
}

/** First-wins Map for callers that only need id → summary. Prefer parseHumanGateEntries. */
export function extractGateSummaries(agentsText) {
  const out = new Map();
  for (const e of parseHumanGateEntries(agentsText)) {
    if (!out.has(e.id)) out.set(e.id, e.summary);
  }
  return out;
}

export function parseRoleEnumeration(agentsText) {
  const section = extractSection(agentsText, "Your role this session") || agentsText;
  const marker = "You are exactly one of:";
  const idx = section.indexOf(marker);
  const slice = idx === -1 ? section : section.slice(idx + marker.length);
  const rest = String(slice).replace(/^\s+/, "");
  const para = rest.split(/\n\n/)[0] || "";
  return [...para.matchAll(/`([a-z][a-z0-9-]*)`/g)].map((x) => x[1]);
}

export function parseRiskTiers(agentsText) {
  const rows = extractMarkdownTable(agentsText, ["Tier", "Definition", "Treatment"]);
  return rows.map((r) => ({
    id: String(r[0] || "")
      .replace(/\*/g, "")
      .trim(),
    definition: collapseWs(r[1] || ""),
    treatment: collapseWs(r[2] || ""),
  }));
}

export function parseTenStagesList(agentsText) {
  const m = /Ten stages\s*\(([\s\S]*?)\)/.exec(agentsText);
  if (!m) return [];
  return [...m[1].matchAll(/`([^`]+)`/g)].map((x) => x[1].trim()).filter(Boolean);
}

export function parseForbiddenPairs(agentsText) {
  const section = extractSection(agentsText, "Your role this session") || agentsText;
  const m = /\*\*Forbidden pairs[\s\S]*?(?:\n\n|$)/.exec(section);
  const block = m ? m[0] : section;
  const pairs = [...block.matchAll(/`([a-z-]+)`\s*≠\s*`([a-z-]+)`/g)].map((x) => ({
    a: x[1],
    b: x[2],
  }));
  const symmetric = /\(\s*symmetric\s*\)/i.test(block);
  return { pairs, symmetric, block };
}

export function parseSecurityLayers(agentsText) {
  const section = extractSection(agentsText, "Security layers (binding)");
  if (!section) return [];
  const flat = collapseWs(section);
  const start = flat.search(/\d+\.\s+/);
  const numbered = start >= 0 ? flat.slice(start) : flat;
  const layers = [];
  for (const part of numbered.split(/\s*·\s*/)) {
    const m = /(\d+)\.\s+(.+)/.exec(part.trim());
    if (!m) continue;
    const raw = collapseWs(m[2]).replace(/[.;]+$/, "");
    const name = collapseWs(raw.split(/\s+[—(]/)[0]);
    layers.push({ n: Number(m[1]), name, raw });
  }
  return layers;
}

export function parseDeliveryControlSteps(agentsText) {
  const section = extractSection(agentsText, "Delivery control (binding)");
  if (!section) return { section: "", steps: [] };
  const flat = collapseWs(section);
  const steps = [];
  for (const step of EXPECTED_DELIVERY_STEPS) {
    if (new RegExp(`\\b${escapeRe(step)}\\b`, "i").test(flat)) steps.push(step);
  }
  const ordered = [];
  const audit = /\baudit\b/i.exec(flat);
  const dry = /\bdry-run\b/i.exec(flat);
  const apply = /\bexplicit human apply\b/i.exec(flat);
  if (audit) ordered.push({ step: "audit", index: audit.index });
  if (dry) ordered.push({ step: "dry-run", index: dry.index });
  if (apply) ordered.push({ step: "explicit human apply", index: apply.index });
  ordered.sort((a, b) => a.index - b.index);
  return { section, steps: ordered.map((s) => s.step), text: flat };
}

export function parseSelfModificationControls(agentsText) {
  const section = extractSection(agentsText, "Self-modification bounds (binding)");
  if (!section) return { section: "", controls: [], text: "" };
  const flat = collapseWs(section);
  const controls = EXPECTED_SELF_MOD_CONTROLS.filter((c) =>
    new RegExp(escapeRe(c), "i").test(flat)
  );
  return { section, controls, text: flat };
}

function countMap(items) {
  const m = new Map();
  for (const x of items) m.set(x, (m.get(x) || 0) + 1);
  return m;
}

function pairKey(a, b) {
  return a < b ? `${a}|${b}` : `${b}|${a}`;
}

/**
 * Closed-sequence comparison: addition, omission, duplicate, rename.
 * `unexpectedCode` is used for extras when the expected set is a closed ID list
 * (gates); otherwise extras are ADDITION.
 */
export function diffClosedSequence(prefix, actual, expected, opts = {}) {
  const findings = [];
  const unexpectedCode = opts.unexpectedCode || `E_${prefix}_ADDITION`;
  const actualCounts = countMap(actual);
  const expectedCounts = countMap(expected);
  const omitted = [];
  const extra = [];
  for (const id of expected) {
    const got = actualCounts.get(id) || 0;
    const want = expectedCounts.get(id) || 0;
    if (got === 0 && !omitted.includes(id)) {
      omitted.push(id);
      findings.push({
        code: `E_${prefix}_OMISSION`,
        message: `${prefix.toLowerCase()} list omits ${id}`,
        item: id,
      });
    }
    if (got > want) {
      findings.push({
        code: `E_${prefix}_DUPLICATE`,
        message: `${prefix.toLowerCase()} list duplicates ${id} (${got} times)`,
        item: id,
      });
    }
  }
  for (const id of actual) {
    if (!expectedCounts.has(id) && !extra.includes(id)) {
      extra.push(id);
      findings.push({
        code: unexpectedCode,
        message: `${prefix.toLowerCase()} list has unexpected ${id}`,
        item: id,
      });
    }
  }
  if (opts.renameCode && omitted.length === 1 && extra.length === 1) {
    return [
      {
        code: opts.renameCode,
        message: `${prefix.toLowerCase()} ${omitted[0]} renamed to ${extra[0]}`,
        item: omitted[0],
        other: extra[0],
      },
      ...findings.filter(
        (f) =>
          f.code !== `E_${prefix}_OMISSION` &&
          f.code !== unexpectedCode &&
          f.code !== `E_${prefix}_ADDITION`
      ),
    ];
  }
  const countsOk =
    omitted.length === 0 &&
    extra.length === 0 &&
    expected.every(
      (id) => (actualCounts.get(id) || 0) === (expectedCounts.get(id) || 0)
    );
  if (opts.checkOrder !== false && countsOk) {
    const actualExpected = actual.filter((id) => expectedCounts.has(id));
    if (actualExpected.some((id, i) => id !== expected[i])) {
      findings.push({
        code: `E_${prefix}_ORDER`,
        message: `${prefix.toLowerCase()} list is out of canonical order`,
      });
    }
  }
  return findings;
}

export function diffGateClosedList(entries) {
  const ids = entries.map((e) => e.id);
  return diffClosedSequence("GATE", ids, EXPECTED_GATE_IDS, {
    unexpectedCode: "E_GATE_UNEXPECTED",
  });
}

export function diffGateSummariesAgainstCandidate(entries, candidateGates) {
  const findings = [];
  const candById = new Map();
  const candIds = [];
  for (const g of Array.isArray(candidateGates) ? candidateGates : []) {
    if (!g || typeof g.id !== "string") continue;
    candIds.push(g.id);
    candById.set(g.id, g);
  }
  const byId = new Map();
  for (const e of entries) {
    if (!byId.has(e.id)) byId.set(e.id, e);
  }
  for (const id of EXPECTED_GATE_IDS) {
    const entry = byId.get(id);
    const cand = candById.get(id);
    if (!entry || !cand) continue;
    const summary = typeof cand.summary === "string" ? collapseWs(cand.summary) : "";
    if (!summary) continue;
    if (entry.summary === summary) continue;
    const a = semanticShape(entry.summary, "gates");
    const b = semanticShape(summary, "gates");
    if (a.polarity !== b.polarity) {
      findings.push({
        code: "E_GATE_NEGATION",
        message: `AGENTS.md ${id} summary polarity drifts from report-only candidate`,
        item: id,
      });
    } else if (MODAL_RANK[a.modal] < MODAL_RANK[b.modal]) {
      findings.push({
        code: "E_GATE_WEAKENING",
        message: `AGENTS.md ${id} summary modal weakened vs report-only candidate (${b.modal} → ${a.modal})`,
        item: id,
      });
    } else if (MODAL_RANK[b.modal] < MODAL_RANK[a.modal]) {
      findings.push({
        code: "E_GATE_WEAKENING",
        message: `report-only candidate ${id} summary modal weakened vs AGENTS.md (${a.modal} → ${b.modal})`,
        item: id,
      });
    } else {
      findings.push({
        code: "E_MIRROR_DRIFT",
        message: `report-only candidate ${id} summary drifts from AGENTS.md authority`,
        item: id,
      });
    }
  }
  return findings;
}

export function diffForbiddenPairs(parsed, expectedPairs = EXPECTED_PAIRS) {
  const findings = [];
  const expected = new Set(expectedPairs.map(([a, b]) => pairKey(a, b)));
  const actual = new Set();
  const directed = [];
  for (const p of parsed.pairs || []) {
    const key = pairKey(p.a, p.b);
    if (actual.has(key)) {
      findings.push({
        code: "E_PAIR_DUPLICATE",
        message: `forbidden pair duplicated: ${p.a} ≠ ${p.b}`,
        item: key,
      });
    }
    actual.add(key);
    directed.push(`${p.a}|${p.b}`);
  }
  for (const key of expected) {
    if (!actual.has(key)) {
      findings.push({
        code: "E_PAIR_OMISSION",
        message: `forbidden pair omitted: ${key.replace("|", " ≠ ")}`,
        item: key,
      });
    }
  }
  for (const key of actual) {
    if (!expected.has(key)) {
      findings.push({
        code: "E_PAIR_ADDITION",
        message: `forbidden pair added: ${key.replace("|", " ≠ ")}`,
        item: key,
      });
    }
  }
  if (parsed.pairs && parsed.pairs.length && parsed.symmetric === false) {
    findings.push({
      code: "E_PAIR_ASYMMETRY",
      message: "forbidden pairs declaration is not marked symmetric",
    });
  }
  return findings;
}

function sectionSentences(section) {
  return String(section || "")
    .split(/(?<=[.!?])\s+/)
    .map((s) => collapseWs(s))
    .filter((s) => s.length > 8);
}

function bestSentenceMatch(expectedText, section) {
  const want = semanticShape(expectedText, "gates");
  let best = null;
  let bestScore = 0;
  for (const s of sectionSentences(section)) {
    const got = semanticShape(s, "gates");
    const score = topicOverlap(want.tokens, got.tokens);
    if (score > bestScore) {
      bestScore = score;
      best = { text: s, shape: got };
    }
  }
  return bestScore >= 0.35 ? { ...best, score: bestScore, want } : null;
}

/** Neutralize the "not just" idiom without discarding the remainder. */
export function neutralizeNotJust(text) {
  return String(text || "").replace(/\bnot just\b/gi, " ");
}

/**
 * Enclosing sentence or table-row units. Prose wrapping is collapsed so a
 * protected phrase and a later weakener in the same sentence stay together;
 * a later sentence cannot hide behind a decoy occurrence.
 */
export function polarityUnits(section) {
  const units = [];
  const lines = String(section || "").split(/\r?\n/);
  const prose = [];
  for (const line of lines) {
    if (line.includes("|")) {
      const cell = collapseWs(line);
      if (cell) units.push(cell);
      continue;
    }
    prose.push(line);
  }
  const flat = collapseWs(prose.join(" "));
  if (flat) {
    for (const sent of flat.split(/(?<=[.!?])\s+/)) {
      const t = sent.trim();
      if (t) units.push(t);
    }
  }
  return units;
}

function unitContainsPhrase(unit, phrase) {
  return unit.toLowerCase().includes(String(phrase).toLowerCase());
}

/**
 * Removal verbs: skipping/waiving/bypassing the protected obligation.
 * Longer forms first so "skipped" is not read as "skip" + junk.
 */
const REMOVAL_VERB_SRC =
  "(?:skipped|skipping|skips|skip|waived|waiving|waives|waive|bypassed|bypassing|bypasses|bypass|omitted|omitting|omits|omit|ignored|ignoring|ignores|ignore)";
const REMOVAL_VERB_RE = new RegExp(`\\b${REMOVAL_VERB_SRC}\\b`, "i");
const OBLIGATION_PRED_SRC =
  "(?:required|mandatory|enforced|necessary|(?<!non-)binding|obligatory|needed|recommended|advisory)";
/**
 * Bounded adverb/adverbial slot around a negator and the obligation
 * predicate. 0–4 tokens (including a short hyphenated token) so a
 * generalized modifier or short prepositional filler can sit before or
 * after the negator without a closed word list. Slot tokens are not
 * themselves negators or obligation predicates, so the negator is not
 * swallowed. Punctuation around the slot is normalized first. Negated
 * softeners ("not merely recommended") are stripped before this slot
 * is applied.
 */
const OBLIGATION_NEGATOR_TOKEN_SRC = "(?:not|never|no)";
const OBLIGATION_ADVERBIAL_SLOT = `(?:(?!(?:${OBLIGATION_PRED_SRC}|${OBLIGATION_NEGATOR_TOKEN_SRC})\\b)[A-Za-z]+(?:-[A-Za-z]+)?\\s+){0,4}`;
/**
 * Independent-clause separators that can introduce a new subject.
 * Coordinating `and` is intentionally omitted: ellipsis after `and`
 * ("required and should never be skipped") stays in the same clause.
 * Bounded punctuation/connective set: comma, semicolon, colon+space
 * (so `file:line` is not a boundary), slash, em/en-dash, ASCII `--`,
 * opening `(`, and `or`/`while`/`plus`. Opening `(` truncates local
 * strengthening here and is not a polarized splitter, so a short
 * parenthetical adverb stays in the same negation clause.
 */
const NEW_SUBJECT_BOUNDARY_RE =
  /(?:[,;:]\s+|\s+\/\s+|\s*[\u2014\u2013]\s+|\s+--+\s+|\s*\(\s*|\s+(?:or|while|plus)\s+)/i;
const POLARIZED_COORD_RE =
  /(?:[,;:]\s+|\s+\/\s+|\s*[\u2014\u2013]\s+|\s+--+\s+|(?:,\s+|\s+)(?:and|or|while|plus)\s+)/gi;
const STRENGTHENING_REMOVAL_RE = new RegExp(
  `\\b(?:(?:must|may|shall|should)\\s+not|cannot|can't|should\\s+never|never|not|don't|do not|without)\\s+(?:be\\s+)?${REMOVAL_VERB_SRC}\\b`,
  "i"
);

function normalizeApostrophes(text) {
  return String(text || "").replace(/[\u2018\u2019]/g, "'");
}

/**
 * Unwrap wrapping commas, parentheses, and dash punctuation around an
 * adverbial slot so "not, technically, required" and "not (technically)
 * required" match the same generalized token slot. Does not split
 * clauses — callers that need a new-subject boundary use
 * NEW_SUBJECT_BOUNDARY_RE instead.
 */
function normalizeAdverbialPunctuation(text) {
  return collapseWs(
    String(text || "")
      .replace(/[\u2014\u2013]/g, " ")
      .replace(/--+/g, " ")
      .replace(/[(),]/g, " ")
  );
}

/**
 * Consume strengthening idioms that name a softener in order to reject it.
 * Bare "is recommended" / "is optional" must still weaken. Bare
 * "not recommended" / "not advisory" / "not binding" are obligation
 * negation, not softeners.
 */
function neutralizeNegatedSofteners(text) {
  return String(text || "")
    .replace(/\bnot\s+(?:just|merely)\s+recommended\b/gi, " ")
    .replace(
      /\brather\s+than\s+(?:optional|elective|advisory|non-binding|recommended)\b/gi,
      " "
    )
    .replace(
      /\bnot\s+(?:merely\s+)?(?:optional|elective|non-binding)\b/gi,
      " "
    );
}

function stripMdEmphasis(s) {
  return String(s || "").replace(/[`*_]+/g, " ");
}

function maskPreservingNewlines(text) {
  return String(text || "").replace(/[^\r\n]/g, " ");
}

/**
 * Remove inert Markdown regions before authority-claim scanning while
 * preserving offsets. Fenced examples are inert. HTML comments remain
 * scan-visible because agent harnesses ingest them as prompt context. Inline
 * Markdown delimiters become spaces so ordinary emphasis and code spans
 * cannot evade a matcher.
 */
function authorityClaimHaystack(text) {
  const original = String(text || "");
  const lines = original.match(/.*(?:\r?\n|$)/g) || [];
  let fence = null;
  let fenceStart = -1;
  let masked = "";
  for (const line of lines) {
    if (!line) continue;
    const marker = /^[ \t]*(`{3,}|~{3,})/.exec(line);
    if (!fence && marker) {
      fence = { char: marker[1][0], length: marker[1].length };
      fenceStart = masked.length;
      masked += maskPreservingNewlines(line);
      continue;
    }
    if (fence) {
      masked += maskPreservingNewlines(line);
      const delimiter = fence.char === "`" ? "`" : "~";
      const close = new RegExp(
        `^[ \\t]*${delimiter}{${fence.length},}[ \\t]*(?:\\r?\\n)?$`
      );
      if (close.test(line)) {
        fence = null;
        fenceStart = -1;
      }
      continue;
    }
    masked += line;
  }
  // Malformed, unclosed inert regions fail closed: scan their contents rather
  // than letting one opener hide the remainder of the file.
  if (fence && fenceStart >= 0) {
    masked = masked.slice(0, fenceStart) + original.slice(fenceStart);
  }
  return masked.replace(/[`*_]/g, " ");
}

function splitAroundPhrase(unit, phrase) {
  const neutralized = collapseWs(
    stripMdEmphasis(neutralizeNotJust(collapseWs(unit)))
  );
  const needle = collapseWs(stripMdEmphasis(String(phrase || "")));
  if (!needle) {
    return { before: neutralized, after: "", full: neutralized, idx: -1 };
  }
  const idx = neutralized.toLowerCase().indexOf(needle.toLowerCase());
  if (idx < 0) return null;
  return {
    before: neutralized.slice(0, idx),
    after: neutralized.slice(idx + needle.length),
    full: neutralized,
    idx,
  };
}

/**
 * True when THIS clause prohibits removing the obligation (never skip X,
 * X must not be skipped, without bypassing X). That is strengthening of
 * the clause only — callers must not treat it as covering later independent
 * clauses or phrase occurrences in the same unit.
 */
export function prohibitsObligationRemoval(clause, phrase = "") {
  const parts = splitAroundPhrase(normalizeApostrophes(clause), phrase);
  if (!parts) return false;
  const { before, after } = parts;
  if (
    new RegExp(
      `\\b(?:never|not|no longer|without|don't|do not|must not|may not|cannot|can't|shall not|should not)\\s+(?:\\w+\\s+){0,3}${REMOVAL_VERB_SRC}(?:\\s+(?:the|this|that|a|an))*\\s*$`,
      "i"
    ).test(before)
  ) {
    return true;
  }
  if (
    new RegExp(
      `^\\s*(?:must not|may not|cannot|can't|shall not|should not|should never|is not to|are not to)\\s+(?:be\\s+)?${REMOVAL_VERB_SRC}\\b`,
      "i"
    ).test(after)
  ) {
    return true;
  }
  // Strengthening is clause-local to the protected phrase. An unrelated
  // "cannot be skipped" after a new-subject boundary belongs to that
  // later subject and must not cover this phrase.
  if (STRENGTHENING_REMOVAL_RE.test(clauseLocalAfter(after))) {
    return true;
  }
  return false;
}

function clauseLocalAfter(after) {
  const s = String(after || "");
  const m = NEW_SUBJECT_BOUNDARY_RE.exec(s);
  return collapseWs(m ? s.slice(0, m.index) : s);
}

function remainderAfterLastNegation(before) {
  const m = String(before || "").match(
    /.*\b(never|not|no longer|without|don't)\b(.*)$/i
  );
  return m ? m[2] : null;
}

/**
 * Contrastive/adversative clause boundaries. "unless" stays on the
 * following clause so convenience matchers still see it.
 */
const CLAUSE_BOUNDARY_RE =
  /(?:;+\s*(?:however|nevertheless|nonetheless)?,?\s*)|(?:,\s*(?:but|however|although|though|whereas|nevertheless|nonetheless|yet)\s+)|(?:\s+(?:but|however|although|though|whereas|nevertheless|nonetheless|yet)\s+)|(?:(?:,\s+|\s+)(?=unless\b))/gi;

function splitAdversativeClauses(text) {
  const src = collapseWs(text);
  if (!src) return [];
  const parts = [];
  let last = 0;
  const re = new RegExp(CLAUSE_BOUNDARY_RE.source, "gi");
  let m;
  while ((m = re.exec(src)) !== null) {
    if (m.index < last) continue;
    const left = collapseWs(src.slice(last, m.index));
    if (left) parts.push(left);
    last = m.index + m[0].length;
    if (last === m.index) last = m.index + 1;
  }
  const tail = collapseWs(
    src.slice(last).replace(
      /^(?:however|nevertheless|nonetheless|although|though|whereas|but|yet)\b[,:\s]*/i,
      ""
    )
  );
  if (tail) parts.push(tail);
  return parts.length ? parts : [src];
}

function splitStrengtheningPrefix(text, phrase) {
  if (!phrase) return [text];
  const m = /[,;]\s+/.exec(text);
  if (!m) return [text];
  const left = collapseWs(text.slice(0, m.index));
  const right = collapseWs(text.slice(m.index + m[0].length));
  if (
    left &&
    right &&
    unitContainsPhrase(left, phrase) &&
    prohibitsObligationRemoval(left, phrase)
  ) {
    return [left, right];
  }
  return [text];
}

function clauseHasIndependentNegationOrWeakening(clause, phrase) {
  const bound = unitContainsPhrase(clause, phrase)
    ? clause
    : collapseWs(`${phrase} ${clause}`);
  if (prohibitsObligationRemoval(bound, phrase)) return false;
  if (obligationNegatedAtClause(bound, phrase)) return true;
  if (clauseWeakensAtClause(bound, phrase)) return true;
  return false;
}

/**
 * Split coordinating separators when either side independently negates or
 * weakens the obligation, even if the other side is strengthening. A
 * strengthening predicate may neutralize only its own clause. Covers
 * `and`/`or`/`while`/`plus`, comma, semicolon, colon+space, slash, and
 * em/en/ASCII dashes so "is optional, Unit tests cannot be skipped"
 * and "is optional / Unit tests cannot be skipped" keep the optionality.
 * Harmless "mandatory and cannot be skipped" stays one clause because
 * neither side independently negates or weakens. Opening `(` is not a
 * splitter (parenthetical adverbs stay attached to the negator).
 */
function splitAndWhenRhsPolarized(text, phrase) {
  const src = collapseWs(normalizeApostrophes(text));
  if (!phrase || !src) return [src];
  const re = new RegExp(POLARIZED_COORD_RE.source, "gi");
  const parts = [];
  let last = 0;
  let m;
  while ((m = re.exec(src)) !== null) {
    if (m.index < last) continue;
    const left = collapseWs(src.slice(last, m.index));
    const right = collapseWs(src.slice(m.index + m[0].length));
    if (
      left &&
      right &&
      (clauseHasIndependentNegationOrWeakening(left, phrase) ||
        clauseHasIndependentNegationOrWeakening(right, phrase))
    ) {
      parts.push(left);
      last = m.index + m[0].length;
    }
  }
  const tail = collapseWs(src.slice(last));
  if (tail) parts.push(tail);
  return parts.length ? parts : [src];
}

function splitPhraseOccurrences(text, phrase) {
  const needle = collapseWs(stripMdEmphasis(String(phrase || "")));
  if (!needle) return [text];
  const lower = text.toLowerCase();
  const n = needle.toLowerCase();
  const idxs = [];
  let from = 0;
  while (from <= lower.length - n.length) {
    const i = lower.indexOf(n, from);
    if (i < 0) break;
    idxs.push(i);
    from = i + Math.max(n.length, 1);
  }
  if (idxs.length <= 1) return [text];
  const parts = [];
  for (let k = 0; k < idxs.length; k++) {
    const start = k === 0 ? 0 : idxs[k];
    const end = k + 1 < idxs.length ? idxs[k + 1] : text.length;
    const chunk = collapseWs(text.slice(start, end));
    if (chunk) parts.push(chunk);
  }
  return parts.length ? parts : [text];
}

/**
 * Independent grammatical clauses / phrase occurrences inside one unit.
 * A strengthening prohibition covers only the clause it appears in;
 * earlier or later optionality, obligation-negation, convenience, or
 * another removal verb is analyzed on its own, including after
 * coordinating `and`/`or`/`while`/`plus`/`yet`, comma, colon, slash, or
 * dash when either side independently negates or weakens. Pronoun/ellipsis
 * remainders after a seen phrase are bound back to that phrase.
 */
function polarityClauses(unit, phrase) {
  const text = collapseWs(
    stripMdEmphasis(neutralizeNotJust(neutralizeNegatedSofteners(unit)))
  );
  if (!text) return [];
  if (!phrase) return [text];
  const expanded = [];
  for (const adv of splitAdversativeClauses(text)) {
    for (const andPart of splitAndWhenRhsPolarized(adv, phrase)) {
      for (const pref of splitStrengtheningPrefix(andPart, phrase)) {
        for (const occ of splitPhraseOccurrences(pref, phrase)) {
          if (occ) expanded.push(occ);
        }
      }
    }
  }
  const bound = [];
  let seen = false;
  for (const clause of expanded) {
    const has = unitContainsPhrase(clause, phrase);
    if (has) seen = true;
    if (!has && !seen) continue;
    bound.push(has ? clause : `${phrase} ${clause}`);
  }
  return bound.length ? bound : [text];
}

/**
 * True when the grammatical target is the obligation itself (X is not
 * required / X isn't mandatory / X is never required / X doesn't need to
 * happen / do not require X), not a skip/waive/bypass verb.
 * Strengthening a removal verb in one clause does not suppress a later
 * independent negation in the same unit. Negated softeners ("not optional")
 * are not obligation-negation.
 */
export function obligationNegated(unit, phrase) {
  for (const clause of polarityClauses(unit, phrase)) {
    if (obligationNegatedAtClause(clause, phrase)) return true;
  }
  return false;
}

function afterNegatesObligation(after) {
  const a = normalizeAdverbialPunctuation(
    neutralizeNegatedSofteners(normalizeApostrophes(after))
  );
  if (
    new RegExp(
      `\\b(?:is|are|was|were)\\s+${OBLIGATION_ADVERBIAL_SLOT}(?:not|never|no longer)\\s+${OBLIGATION_ADVERBIAL_SLOT}${OBLIGATION_PRED_SRC}\\b`,
      "i"
    ).test(a)
  ) {
    return true;
  }
  if (
    new RegExp(
      `\\b(?:isn't|aren't|wasn't|weren't)\\s+${OBLIGATION_ADVERBIAL_SLOT}${OBLIGATION_PRED_SRC}\\b`,
      "i"
    ).test(a)
  ) {
    return true;
  }
  if (
    /\bneed(?:\s+not|n't)\s+(?:happen|occur|apply|be|exist)\b/i.test(a) ||
    /\bneed(?:\s+not|n't)\b/i.test(a)
  ) {
    return true;
  }
  if (
    /\b(?:does(?:n't|\s+not)|do(?:n't|\s+not))\s+need(?:s)?(?:\s+to)?\s+(?:happen|occur|apply|be|exist)\b/i.test(
      a
    )
  ) {
    return true;
  }
  if (
    /\bnever\s+needs?(?:\s+to)?\s+(?:happen|occur|apply|be|exist)\b/i.test(a)
  ) {
    return true;
  }
  if (
    /\b(?:does(?:n't|\s+not)|do(?:n't|\s+not))\s+have\s+to\s+(?:happen|occur|apply|be|exist)\b/i.test(
      a
    )
  ) {
    return true;
  }
  // "cannot be required" negates the obligation. "cannot be skipped" is a
  // strengthening removal predicate and must not match OBLIGATION_PRED_SRC.
  if (
    new RegExp(
      `\\b(?:cannot|can't|can not)\\s+be\\s+${OBLIGATION_ADVERBIAL_SLOT}${OBLIGATION_PRED_SRC}\\b`,
      "i"
    ).test(a)
  ) {
    return true;
  }
  return false;
}

function obligationNegatedAtClause(clause, phrase) {
  const normalized = normalizeApostrophes(clause);
  const parts = splitAroundPhrase(normalized, phrase);
  if (!parts) return false;
  if (prohibitsObligationRemoval(normalized, phrase)) return false;
  const { before, after } = parts;
  if (afterNegatesObligation(after)) return true;
  if (
    /\b(?:do not|don't|does not|doesn't|never|must not)\s+(?:require|enforce|mandate)\s*$/i.test(
      before
    )
  ) {
    return true;
  }
  if (!/\b(never|not|no longer|without|don't)\b/i.test(before)) return false;
  const rest = remainderAfterLastNegation(before);
  if (rest == null) return false;
  return !REMOVAL_VERB_RE.test(rest);
}

/**
 * Class of obligation hedges: optionality, convenience/practicality,
 * modal softeners (may/should/recommended), and skip/waive/bypass of the
 * protected phrase. Inspects each grammatical clause after neutralizing
 * "not just" and negated-softener strengthening ("not optional",
 * "not merely recommended", "rather than recommended"). Valid
 * "never skip X" / "X must not be skipped" prohibitions neutralize only
 * their own clause, not a later independent weakener.
 */
export function clauseWeakensBinding(clause, phrase = "") {
  if (!phrase) return clauseWeakensAtClause(clause, phrase);
  for (const part of polarityClauses(clause, phrase)) {
    if (clauseWeakensAtClause(part, phrase)) return true;
  }
  return false;
}

function clauseWeakensAtClause(clause, phrase = "") {
  if (prohibitsObligationRemoval(clause, phrase)) return false;
  const raw = neutralizeNotJust(neutralizeNegatedSofteners(clause));
  const stripped = phrase
    ? raw.replace(new RegExp(escapeRe(phrase), "ig"), " ")
    : raw;
  // Unrelated "cannot be skipped" about another subject is not a weakener
  // of this phrase; strip those strengthening idioms before the remnant
  // is scanned for optionality or a leftover removal verb.
  const c = String(stripped).replace(
    new RegExp(STRENGTHENING_REMOVAL_RE.source, "gi"),
    " "
  );
  if (
    /\b(?:only\s+)?(?:when|unless|if)\s+(?:\w+\s+){0,4}(?:convenient|practical|desired|wanted|easy)\b/i.test(
      c
    )
  ) {
    return true;
  }
  if (/\b(?:which|that)\s+is\s+optional\b|\bis\s+optional\b/i.test(c)) {
    return true;
  }
  if (/\b(?<!non-)optional\b|\belective\b|\badvisory\b|\bnon-binding\b/i.test(c)) {
    return true;
  }
  if (/\b(?:may|should|might|could)(?!\s+not)\b/i.test(c)) {
    return true;
  }
  if (/\bis recommended\b|\brecommended\b/i.test(c)) {
    return true;
  }
  if (
    /\b(?:may|can|could|should|might)\s+(?:be\s+)?(?:skipped|waived|bypassed|omitted|ignored)\b/i.test(
      c
    )
  ) {
    return true;
  }
  if (REMOVAL_VERB_RE.test(c)) {
    return true;
  }
  return false;
}

export function diffBindingPhrase(familyId, phrase, section, opts = {}) {
  const findings = [];
  const units = polarityUnits(section || "");
  const hits = units.filter((u) => unitContainsPhrase(u, phrase));
  if (!hits.length) {
    findings.push({
      code: "E_BINDING_FAMILY",
      message: `AGENTS.md binding-family ${familyId} omits required statement: ${phrase}`,
    });
    return findings;
  }
  for (const unit of hits) {
    if (obligationNegated(unit, phrase)) {
      findings.push({
        code: "E_BINDING_NEGATION",
        message: `AGENTS.md binding-family ${familyId} negated around "${phrase}"`,
      });
      continue;
    }
    if (opts.requireMust !== false && clauseWeakensBinding(unit, phrase)) {
      findings.push({
        code: "E_BINDING_WEAKENING",
        message: `AGENTS.md binding-family ${familyId} weakened around "${phrase}"`,
      });
    }
  }
  return findings;
}

/**
 * Tier A/B/C treatment semantics — IDs alone are not enough. Tier C
 * must keep fan-out + adversarial review + G12 human merge strength.
 */
export function diffTierTreatments(tiers) {
  const findings = [];
  const byId = new Map();
  for (const t of Array.isArray(tiers) ? tiers : []) {
    const id = String(t.id || "")
      .replace(/\*/g, "")
      .trim();
    if (id) byId.set(id, t);
  }
  const tierA = byId.get("A");
  if (tierA && !/independent review/i.test(tierA.treatment || "")) {
    findings.push({
      code: "E_TIER_WEAKENING",
      message: "Tier A treatment missing independent review",
    });
  }
  const tierB = byId.get("B");
  if (tierB && !/full-lens review/i.test(tierB.treatment || "")) {
    findings.push({
      code: "E_TIER_WEAKENING",
      message: "Tier B treatment missing full-lens review",
    });
  }
  const tierC = byId.get("C");
  if (tierC) {
    const treat = collapseWs(tierC.treatment || "");
    const lower = treat.toLowerCase();
    const hasG12 = /\bg12\b/i.test(treat);
    const hasHumanMerge = /human merge/.test(lower);
    const hasAdversarial = /adversarial review/.test(lower);
    const hasFanout = /fan-out|fan out/.test(lower);
    if (!hasG12 || !hasHumanMerge || !hasAdversarial || !hasFanout) {
      findings.push({
        code: "E_TIER_WEAKENING",
        message:
          "Tier C treatment missing required human merge / adversarial review strength",
      });
    } else if (
      obligationNegated(treat, "human merge") ||
      obligationNegated(treat, "adversarial review") ||
      obligationNegated(treat, "fan-out") ||
      clauseWeakensBinding(treat, "human merge") ||
      clauseWeakensBinding(treat, "adversarial review") ||
      clauseWeakensBinding(treat)
    ) {
      findings.push({
        code: "E_TIER_WEAKENING",
        message: "Tier C treatment weakens human merge / adversarial review",
      });
    }
  }
  return findings;
}

export function diffBindingSentence(familyId, expectedText, section) {
  return diffBindingPhrase(familyId, expectedText, section);
}

export const BINDING_FAMILY_SENTENCES = {
  "six-lens-review": ["file:line"],
  "tier-c-adversarial-tests": ["adversarial cases required"],
  "no-destructive-prod-testing": ["destructive production testing"],
  "eight-security-layers": [
    "hard-fail blocks merge/release",
    "never destructive payloads against production",
  ],
  "self-modification-gates": ["themselves Tier C"],
  "delivery-control": ["explicit human apply"],
};

/**
 * Presence-only scans used to prove a mutant is green without the repaired
 * structured check. These deliberately collapse duplicates and ignore extras
 * outside the expected token set.
 */
export function legacyPresenceOnly(agentsText) {
  const presentGates = new Set();
  const re = /\*\*G([1-9]|1[0-6])\*\*/g;
  let m;
  while ((m = re.exec(agentsText)) !== null) presentGates.add(`G${m[1]}`);
  const missingGates = EXPECTED_GATE_IDS.filter((id) => !presentGates.has(id));
  const secFlat = collapseWs(
    extractSection(agentsText, "Security layers (binding)") || agentsText
  );
  const missingLayers = EXPECTED_SECURITY_LAYERS.filter((l) => !secFlat.includes(l));
  const delivery = extractSection(agentsText, "Delivery control (binding)") || "";
  const selfMod = extractSection(agentsText, "Self-modification bounds (binding)") || "";
  const pipeline = extractSection(agentsText, "The pipeline you are inside") || agentsText;
  const missingStages = EXPECTED_STAGES.filter((s) => !pipeline.includes(s) && !agentsText.includes(s));
  const tierSection = extractSection(agentsText, "Risk tiers") || agentsText;
  const missingTiers = EXPECTED_TIERS.filter((t) => !new RegExp(`\\*\\*${t}\\*\\*`).test(tierSection));
  const roleFlat = collapseWs(
    extractSection(agentsText, "Your role this session") || agentsText
  );
  const missingPairs = EXPECTED_PAIRS.filter(
    ([a, b]) => !roleFlat.includes("`" + a + "` ≠ `" + b + "`")
  );
  return {
    missingGates,
    missingLayers,
    hasDeliveryTokens:
      /\baudit\b/.test(delivery) &&
      /\bdry-run\b/.test(delivery) &&
      /explicit human apply/.test(delivery),
    hasSelfModTokens:
      /human gates/.test(selfMod) &&
      /Tier definitions/.test(selfMod) &&
      /hard-fail security layers/.test(selfMod),
    missingStages,
    missingTiers,
    missingPairs,
  };
}

export function structuredAgentsEnumerationFindings(agentsText, candidate) {
  const findings = [];
  const gates = parseHumanGateEntries(agentsText);
  findings.push(...diffGateClosedList(gates));
  if (candidate && Array.isArray(candidate.humanGates)) {
    findings.push(...diffGateSummariesAgainstCandidate(gates, candidate.humanGates));
    const candIds = candidate.humanGates
      .map((g) => (g && g.id ? g.id : null))
      .filter(Boolean);
    for (const id of EXPECTED_GATE_IDS) {
      if (!candIds.includes(id) && gates.some((g) => g.id === id)) {
        findings.push({
          code: "E_MIRROR_DRIFT",
          message: `AGENTS.md has ${id} missing from report-only candidate mirror`,
        });
      }
    }
    for (const id of candIds) {
      if (!EXPECTED_GATE_IDS.includes(id)) {
        findings.push({
          code: "E_MIRROR_DRIFT",
          message: `report-only candidate has ${id} absent from AGENTS.md authority`,
        });
      }
    }
  }

  const roles = parseRoleEnumeration(agentsText);
  findings.push(
    ...diffClosedSequence("ROLE_ENUM", roles, EXPECTED_ROLES, {
      renameCode: "E_ROLE_ENUM_RENAME",
      unexpectedCode: "E_ROLE_ENUM_ADDITION",
    }).map((f) => {
      if (f.code === "E_ROLE_ENUM_OMISSION") {
        return { ...f, message: `AGENTS.md role enumeration omits ${f.item}` };
      }
      return f;
    })
  );

  const tableRoles = parseRoleTable(agentsText);
  findings.push(
    ...diffClosedSequence("ROLE_TABLE", tableRoles, EXPECTED_ROLES, {
      renameCode: "E_ROLE_TABLE_RENAME",
      unexpectedCode: "E_ROLE_TABLE_ADDITION",
    }).map((f) => {
      if (f.code === "E_ROLE_TABLE_OMISSION") {
        return { ...f, message: `AGENTS.md role table omits ${f.item}` };
      }
      return f;
    })
  );
  if (
    tableRoles.length &&
    roles.length &&
    (tableRoles.length !== roles.length || tableRoles.some((id, i) => id !== roles[i]))
  ) {
    const tableSet = new Set(tableRoles);
    const enumSet = new Set(roles);
    if ([...tableSet].some((id) => !enumSet.has(id)) || [...enumSet].some((id) => !tableSet.has(id))) {
      findings.push({
        code: "E_ROLE_TABLE_ADDITION",
        message:
          "AGENTS.md role table disagrees with the expected role enumeration",
      });
    }
  }

  const tierRows = parseRiskTiers(agentsText);
  const tiers = tierRows.map((t) => t.id);
  findings.push(...diffClosedSequence("TIER", tiers, EXPECTED_TIERS));
  findings.push(...diffTierTreatments(tierRows));

  const stages = parseTenStagesList(agentsText);
  findings.push(...diffClosedSequence("STAGE", stages, EXPECTED_STAGES));

  const pairs = parseForbiddenPairs(agentsText);
  findings.push(...diffForbiddenPairs(pairs));

  const layers = parseSecurityLayers(agentsText);
  const layerNames = layers.map((l) => l.name);
  findings.push(
    ...diffClosedSequence("BINDING", layerNames, EXPECTED_SECURITY_LAYERS).map((f) => ({
      ...f,
      code:
        f.code === "E_BINDING_OMISSION"
          ? "E_BINDING_FAMILY"
          : f.code === "E_BINDING_ADDITION"
            ? "E_BINDING_FAMILY"
            : f.code === "E_BINDING_DUPLICATE"
              ? "E_BINDING_FAMILY"
              : f.code,
      message:
        f.code === "E_BINDING_OMISSION"
          ? `AGENTS.md missing binding-family eight-security-layers item: ${f.item}`
          : f.message,
    }))
  );

  const delivery = parseDeliveryControlSteps(agentsText);
  if (!listEq(delivery.steps, EXPECTED_DELIVERY_STEPS)) {
    findings.push({
      code: "E_BINDING_FAMILY",
      message: `AGENTS.md missing binding-family delivery-control structured requirements`,
    });
  }
  const selfMod = parseSelfModificationControls(agentsText);
  if (!listEq(selfMod.controls, EXPECTED_SELF_MOD_CONTROLS)) {
    findings.push({
      code: "E_BINDING_FAMILY",
      message: "AGENTS.md missing binding-family self-modification-gates",
    });
  }

  for (const [familyId, sentences] of Object.entries(BINDING_FAMILY_SENTENCES)) {
    let section = agentsText;
    if (familyId === "six-lens-review") {
      section = extractSection(agentsText, "Review lenses (binding)");
    } else if (familyId === "eight-security-layers") {
      section = extractSection(agentsText, "Security layers (binding)");
    } else if (familyId === "self-modification-gates") {
      section = extractSection(agentsText, "Self-modification bounds (binding)");
    } else if (familyId === "delivery-control") {
      section = extractSection(agentsText, "Delivery control (binding)");
    } else if (
      familyId === "tier-c-adversarial-tests" ||
      familyId === "no-destructive-prod-testing"
    ) {
      const rows = extractMarkdownTable(agentsText, ["Role", "Out", "Forbidden"]);
      section = rows.map((r) => r.join(" | ")).join("\n");
    }
    for (const sentence of sentences) {
      findings.push(...diffBindingSentence(familyId, sentence, section));
    }
  }

  const lensSection = extractSection(agentsText, "Review lenses (binding)");
  const lensItems = extractNumberedItems(lensSection);
  if (!listEq(lensItems, EXPECTED_LENSES)) {
    findings.push({
      code: "E_BINDING_FAMILY",
      message: "AGENTS.md missing binding-family six-lens-review structured list",
    });
  }

  return findings;
}

export function listEq(actual, expected) {
  if (!Array.isArray(actual) || actual.length !== expected.length) return false;
  return actual.every((v, i) => v === expected[i]);
}

export function remapRoleCodesToJob(findings) {
  return findings.map((f) => ({
    ...f,
    code: String(f.code || "").replace(/^E_ROLE_/, "E_JOB_"),
    message: String(f.message || "").replace(/^(\S+) (outputs|gates|forbidden):/, "job $1 $2:"),
  }));
}

export function diffObligationMatrix(id, authByBucket, pbByBucket) {
  const buckets = ["outputs", "gates", "forbidden"];
  const per = {};
  for (const b of buckets) {
    per[b] = diffObligationLists(
      id,
      b,
      Array.isArray(authByBucket[b]) ? authByBucket[b] : [],
      Array.isArray(pbByBucket[b]) ? pbByBucket[b] : []
    );
  }
  const omissions = [];
  const additions = [];
  for (const b of buckets) {
    for (const f of per[b]) {
      if (f.code === "E_ROLE_OMISSION") omissions.push({ bucket: b, f });
      if (f.code === "E_ROLE_ADDITION") additions.push({ bucket: b, f });
    }
  }
  const drop = new Set();
  const extra = [];
  for (const om of omissions) {
    const omText =
      typeof om.f.text === "string"
        ? om.f.text
        : String(om.f.message || "").replace(/^.*omits authority obligation:\s*/, "");
    const omShape = semanticShape(omText, om.bucket);
    let best = null;
    let bestScore = 0;
    for (const ad of additions) {
      if (ad.bucket === om.bucket) continue;
      const adText =
        typeof ad.f.text === "string"
          ? ad.f.text
          : String(ad.f.message || "").replace(
              /^.*adds obligation absent from authority:\s*/,
              ""
            );
      const score = topicOverlap(omShape.tokens, semanticShape(adText, ad.bucket).tokens);
      if (score > bestScore) {
        bestScore = score;
        best = ad;
      }
    }
    if (best && bestScore >= 0.45) {
      drop.add(om.f);
      drop.add(best.f);
      extra.push({
        code: "E_ROLE_CROSS_BUCKET",
        message: `${id} moved obligation across buckets ("${omText}" from ${om.bucket} to ${best.bucket})`,
      });
      additions.splice(additions.indexOf(best), 1);
    }
  }
  const out = [];
  for (const b of buckets) {
    for (const f of per[b]) {
      if (!drop.has(f)) out.push(f);
    }
  }
  out.push(...extra);
  return out;
}

// Candidate matchers consume only the relation verb. That makes every verb
// occurrence independently classifiable: a benign noun/citation occurrence
// cannot swallow a later live claim in the same sentence.
const AGENTS_PRIORITY_VERB_RE =
  /\b(?:overrid(?:e|es|ing|den)|overrode|trump(?:s|ed|ing)?|prevail(?:s|ed|ing)?\s+over|(?:take|takes|took|taking|has|had)\s+(?:precedence|priority)\s+over|(?:win|wins|won|winning)\s+over|rank(?:s|ed|ing)?\s+above|(?:is|was|are|were)\s+superior\s+to)\b/i;
const AGENTS_SUPERSEDE_VERB_RE = /\bsupersed(?:e|es|ing|ed)\b/i;
const AGENTS_OUTRANK_VERB_RE = /\boutrank(?:s|ed|ing)?\b/i;
const AUTHORITY_SELF_NOUN_SRC =
  "(?:file|document|chapter|playbook|adapter|guide|addendum|overlay|recipe|appendix|section)";
const AUTHORITY_SELF_SUBJECT_RE = new RegExp(
  `\\b(?:(?:this|the|our|that)\\s+(?:(?:[A-Za-z][A-Za-z'-]*)\\s+){0,2}${AUTHORITY_SELF_NOUN_SRC}|it|this)\\s*$`,
  "i"
);
const SELF_AUTHORITATIVE_RE = new RegExp(
  `\\b(?:this|the|our|that)\\s+(?:(?:[A-Za-z][A-Za-z'-]*)\\s+){0,2}${AUTHORITY_SELF_NOUN_SRC}\\s+is\\s+(?:the\\s+)?(?:(?:authoritative\\b(?!\\s+(?:walkthrough|guide|history|explanation|overview|reference|documentation)\\b))|binding contract|source of truth|canonical source)\\b`,
  "i"
);
const AGENTS_SUBORDINATE_RE = /\bAGENTS\.md\s+is\s+subordinate\b/i;
const AUTHORITY_RELATION_PATTERNS = [
  AGENTS_PRIORITY_VERB_RE,
  AGENTS_SUPERSEDE_VERB_RE,
  AGENTS_OUTRANK_VERB_RE,
];
const AUTHORITY_RELATION_CLAIM_IDS = new Set([
  "priority-over-agents",
  "supersedes-agents",
  "outranks-agents",
]);

/**
 * Distinguish a direct AGENTS.md authority object from ordinary citations.
 * The candidate regex stays deliberately broad enough for hard-wrapped and
 * coordinated noun phrases; this classifier supplies the precision boundary.
 */
function priorityMatchDirectlyTargetsAgents(para, matchIdx, matchLen) {
  const src = String(para || "");
  const relationEnd = matchIdx + matchLen;
  const { end: sentenceEnd } = sentenceBounds(src, matchIdx, matchLen);
  const searchEnd = Math.min(sentenceEnd, relationEnd + 320);
  const { before } = localClaimSpan(src, matchIdx, matchLen);
  const subject = collapseWs(authorityClaimHaystack(before));
  const selfAuthoritySubject = AUTHORITY_SELF_SUBJECT_RE.test(subject);
  const agentsRe = /\bAGENTS\.md\b/gi;
  agentsRe.lastIndex = relationEnd;
  let agents;
  while ((agents = agentsRe.exec(src)) !== null && agents.index < searchEnd) {
    const rawGap = src.slice(relationEnd, agents.index);
    if (/\r?\n[ \t]*\r?\n/.test(rawGap)) break;
    const gap = collapseWs(authorityClaimHaystack(rawGap));
    if (
      /\b(?:not|never|nothing|except|excluding|rather\s+than|anything\s+but)\b/i.test(
        gap
      ) ||
      /\|/.test(gap) ||
      /\b(?:as\s+(?:described|documented|stated|shown|recorded)|according\s+to|see|refer(?:red)?\s+to|pointer\s+to|summariz(?:e|es|ed|ing)|alongside)\b/i.test(
        gap
      ) ||
      /(?:^|,\s*)per\s+(?:the\s+)?(?:rules?|guidance|contract|AGENTS)\b/i.test(
        gap
      ) ||
      /\b(?:and|or)\s+(?:(?:the|this|that|our|its)\s+)?(?:agent|fleet|runner|reader|document|file|playbook|adapter|it|they|we)\s+(?:loads?|reads?|follows?|consults?|uses?|opens?|points?)\b/i.test(
        gap
      )
    ) {
      continue;
    }
    // Noun uses: "Vendor overrides live ..." / "Config overrides are ...".
    if (
      /^(?:(?:[A-Za-z][A-Za-z'-]*)\s+){0,3}(?:live|are|is|was|were|remain|remains|exist|exists|apply|applies|occur|occurs|happen|happens|get|gets|become|becomes|serve|serves)\b/i.test(
        gap
      )
    ) {
      continue;
    }
    // Restrictive participles are ambiguous for a generic subject and are
    // treated as citations. A self-authority subject remains fail-closed.
    if (
      !selfAuthoritySubject &&
      /\b(?:recorded|stated|shown|documented|required)\s+in\s*$/i.test(gap)
    ) {
      continue;
    }
    return true;
  }
  return false;
}

function paragraphHasLiveAuthorityRelation(para) {
  const src = String(para || "");
  for (const pattern of AUTHORITY_RELATION_PATTERNS) {
    const flags = pattern.flags.includes("g") ? pattern.flags : `${pattern.flags}g`;
    const re = new RegExp(pattern.source, flags);
    let match;
    while ((match = re.exec(src)) !== null) {
      if (!match[0]) {
        re.lastIndex += 1;
        continue;
      }
      if (!priorityMatchDirectlyTargetsAgents(src, match.index, match[0].length)) {
        continue;
      }
      if (
        matchNegatesOperativeClaim(
          src,
          "priority-over-agents",
          match.index,
          match[0].length
        )
      ) {
        continue;
      }
      const local = localClaimUnit(src, match.index, match[0].length);
      if (isRetractedHistorical(local)) continue;
      return true;
    }
  }
  return false;
}

const OPERATIVE_CLAIM_PATTERNS = [
  {
    id: "closed-list",
    re: /\bthis list is\s+closed\b/i,
  },
  {
    id: "authoritative-stops-in-docs",
    re: /\bauthoritative stops\b[\s\S]{0,80}docs\/14/i,
  },
  {
    id: "only-reasons-to-stop",
    re: /\bthe only reasons an agent may stop\b/i,
  },
  {
    id: "complete-list-of-stops",
    re: /\bcomplete list of\s+(mandatory\s+)?stops\b[\s\S]{0,80}docs\/14/i,
  },
  {
    id: "their-contracts-docs-03",
    re: /docs\/03-roles\.md[\s\S]{0,80}their contracts/i,
  },
  {
    id: "gate-list-in-docs-14",
    re: /\bgate list in docs\/14\b/i,
  },
  {
    id: "docs-14-authoritative",
    re: /\bdocs\/14 remains authoritative\b/i,
  },
  {
    id: "g1-g16-in-docs-14",
    re: /\bG1[–-]G16 in docs\/14\b/i,
  },
  {
    id: "human-gates-in-docs-14",
    re: /\bhuman gates in docs\/14\b/i,
  },
  {
    id: "role-is-a-contract",
    re: /\ba role is a\s+contract\b/i,
  },
  {
    id: "principle-wins-over-agents",
    re: /\bthe principle wins\b/i,
  },
  {
    id: "outranks-agents",
    re: AGENTS_OUTRANK_VERB_RE,
  },
  {
    id: "supersedes-agents",
    re: AGENTS_SUPERSEDE_VERB_RE,
  },
  {
    id: "priority-over-agents",
    re: AGENTS_PRIORITY_VERB_RE,
  },
  {
    id: "agents-subordinate",
    re: AGENTS_SUBORDINATE_RE,
  },
  {
    id: "self-authoritative",
    re: SELF_AUTHORITATIVE_RE,
  },
  {
    id: "docs-01-19-are-the-spec",
    re: /\bdesign docs \(01[–-]19\) are the spec\b/i,
  },
  {
    id: "do-not-contradict-docs-01-19",
    re: /\bnever contradict docs 01[–-]19\b/i,
  },
  {
    id: "playbooks-source-of-truth",
    re: /\bprose playbooks\b[\s\S]{0,120}\bhuman-readable source of truth\b/i,
  },
];

function isHistoricalFraming(para) {
  return /\b(historically|historical note|earlier draft|used to|previously|before #\d+|once claimed|no longer(?: true)?|that claim is retired|now live only in)\b/i.test(
    para
  );
}

function paragraphExplicitlyDefersToAgents(para) {
  return (
    /\bbinding(?: commit\/PR\/merge)? rules live(?: only)? in\b[\s\S]{0,60}\bAGENTS\.md\b/i.test(
      para
    ) ||
    /\b(?:follow|defer(?:s|red)? to)\s+\[?`?AGENTS\.md/i.test(para) ||
    /\bAGENTS\.md\b[\s\S]{0,60}\bis the (?:sole |operative |always-mandatory )?(?:human-readable )?contract/i.test(
      para
    ) ||
    /\bmust not add, drop, or weaken\b/i.test(para) ||
    /\b(?:closed (?:stop )?list|stop list) (?:lives|remain(?:s)?(?: the closed list)?) in\b[\s\S]{0,40}\bAGENTS\.md\b/i.test(
      para
    ) ||
    /\blives in\b[\s\S]{0,40}\bAGENTS\.md\b/i.test(para)
  );
}

function paragraphConflictsWithAgents(para) {
  const p = collapseWs(authorityClaimHaystack(para));
  return (
    paragraphHasLiveAuthorityRelation(para) ||
    AGENTS_SUBORDINATE_RE.test(p) ||
    SELF_AUTHORITATIVE_RE.test(p)
  );
}

function claimAttributedToAgents(para, claimId) {
  if (claimId !== "closed-list") return false;
  return /\b(?:closed (?:stop )?list|stop list) (?:lives|remain(?:s)?(?: the closed list)?) in\b[\s\S]{0,40}\bAGENTS\.md\b/i.test(
    para
  );
}

function isRetractedHistorical(para) {
  if (!isHistoricalFraming(para)) return false;
  const retirement = historicalRetirementPolarity(para);
  if (retirement.affirmative) return true;
  // An explicit denial of retirement keeps the historical authority claim
  // live even when the paragraph also contains a generic AGENTS.md deferral.
  if (retirement.denied) return false;
  return (
    /\b(?:no longer true|now live|now (?:the )?contract|do not follow)\b/i.test(
      para
    ) || paragraphExplicitlyDefersToAgents(para)
  );
}

/**
 * Sentence bounds around a match. File-extension dots (`.md`) are not
 * boundaries because they are not followed by whitespace; a sentence
 * period after `AGENTS.md` is.
 */
function sentenceBounds(text, idx, matchLen) {
  const src = String(text || "");
  const matchEnd = Math.max(idx, 0) + Math.max(matchLen, 0);
  let start = 0;
  const startRe = /[.!?][ \t\r\n]+/g;
  let m;
  while ((m = startRe.exec(src)) !== null) {
    if (m.index + m[0].length <= idx) start = m.index + m[0].length;
    else break;
  }
  let end = src.length;
  // A period is a sentence boundary only at whitespace/end. In particular,
  // the dot inside `AGENTS.md` must not truncate the historical/retraction
  // context that follows the direct object.
  const endRe = /(?:[!?]|\.(?=[ \t\r\n]|$))/g;
  endRe.lastIndex = matchEnd;
  const em = endRe.exec(src);
  if (em) end = em.index + em[0].length;
  return { start, end };
}

/**
 * Independent-clause split for retraction/negation locality. Adversative
 * `but` plus coordinating `and`/`or`/`while`/`plus`, semicolon/comma/colon,
 * slashes, and em/en/ASCII dashes. A later active "this file supersedes
 * AGENTS.md" after "that claim is retired —" is its own clause.
 */
const RETRACTION_CLAUSE_BOUNDARY_RE = new RegExp(
  `(?:${CLAUSE_BOUNDARY_RE.source})|(?:(?:,\\s+|\\s+)(?:and|or|while|plus)\\s+)|(?:\\s+\\/\\s+)|(?::\\s+)|(?:\\s*[\\u2014\\u2013]\\s*)|(?:\\s+--+\\s+)`,
  "gi"
);

function localClaimSpan(para, matchIdx, matchLen) {
  const src = String(para || "");
  if (matchIdx == null || matchIdx < 0 || matchIdx > src.length) {
    return { clause: src, before: src, after: "" };
  }
  const { start, end } = sentenceBounds(src, matchIdx, matchLen);
  const sentence = src.slice(start, end);
  const relIdx = matchIdx - start;
  const re = new RegExp(RETRACTION_CLAUSE_BOUNDARY_RE.source, "gi");
  let last = 0;
  let clauseStart = 0;
  let clauseEnd = sentence.length;
  let m;
  while ((m = re.exec(sentence)) !== null) {
    if (m.index < last) continue;
    if (relIdx < m.index) {
      clauseStart = last;
      clauseEnd = m.index;
      break;
    }
    last = m.index + m[0].length;
    clauseStart = last;
    clauseEnd = sentence.length;
  }
  const clause = sentence.slice(clauseStart, clauseEnd);
  const before = sentence.slice(clauseStart, Math.max(relIdx, clauseStart));
  const after = sentence.slice(relIdx + matchLen, clauseEnd);
  return { clause, before, after };
}

/**
 * Match/clause-local unit for historical retraction. A later or earlier
 * active "This file supersedes AGENTS.md" in the same paragraph or after
 * dash/`and` punctuation is not covered by a neighboring retraction.
 */
function localClaimUnit(para, matchIdx, matchLen) {
  const src = String(para || "");
  const { clause } = localClaimSpan(para, matchIdx, matchLen);
  return collapseWs(clause) || collapseWs(src);
}

const NEGATABLE_OPERATIVE_CLAIMS = new Set([
  "supersedes-agents",
  "outranks-agents",
  "priority-over-agents",
  "principle-wins-over-agents",
]);

/**
 * Correlative/evidential "not"/"no" that affirms the following predicate.
 * Stripped before asking whether THIS verb is negated.
 */
function neutralizeAffirmativeNotIdioms(text) {
  return String(text || "")
    .replace(/\b(?:does|do|did)\s+not\s+fail\s+to\b/gi, " ")
    .replace(/\b(?:is|are|was|were)\s+not\s+unable\s+to\b/gi, " ")
    .replace(/\b(?:cannot|can't)\s+fail\s+to\b/gi, " ")
    .replace(/\bnever\s+fail(?:s|ed)?\s+to\b/gi, " ")
    .replace(/\bno\s+doubt\b/gi, " ")
    .replace(/\bno\s+question\b/gi, " ")
    .replace(/\bwithout\s+(?:a\s+)?doubt\b/gi, " ")
    .replace(/\bnot\s+only\b/gi, " ")
    .replace(/\bnot\s+merely\b/gi, " ")
    .replace(/\bnot\s+just\b/gi, " ")
    .replace(/\bnot\s+simply\b/gi, " ");
}

/**
 * Classify explicit uses of "retired" by their local polarity. Generic
 * AGENTS.md deferral must not turn "not/never retired" or "do not treat
 * ... as retired" into a retraction.
 */
function historicalRetirementPolarity(text) {
  const src = collapseWs(normalizeApostrophes(text));
  let affirmative = false;
  let denied = false;
  const re = /\bretired\b/gi;
  let m;
  while ((m = re.exec(src)) !== null) {
    const before = collapseWs(src.slice(Math.max(0, m.index - 120), m.index));
    const polarityBefore = collapseWs(
      neutralizeAffirmativeNotIdioms(normalizeAdverbialPunctuation(before))
    );
    if (
      /\bdo\s+not\s+treat(?:\s+[A-Za-z][A-Za-z'-]*){0,8}\s+as\s*$/i.test(
        polarityBefore
      ) ||
      /\b(?:not|never|no\s+longer)(?:\s+[A-Za-z][A-Za-z'-]*){0,4}\s*$/i.test(
        polarityBefore
      )
    ) {
      denied = true;
    } else {
      affirmative = true;
    }
  }
  return { affirmative, denied };
}

function matchNegatesOperativeClaim(para, claimId, matchIdx, matchLen) {
  if (!NEGATABLE_OPERATIVE_CLAIMS.has(claimId)) return false;
  const { before } = localClaimSpan(para, matchIdx, matchLen);
  const stripped = collapseWs(
    neutralizeAffirmativeNotIdioms(
      normalizeAdverbialPunctuation(normalizeApostrophes(before))
    )
  );
  if (!stripped) return false;
  // Predicate-attached: the negator precedes this verb through a bounded
  // adverbial modifier (including comma-wrapped modifiers).
  if (
    /\b(?:never|not|cannot|can't|does\s+not|doesn't|do\s+not|don't|did\s+not|didn't|no\s+longer)(?:\s+[A-Za-z][A-Za-z'-]*){0,5}\s*$/i.test(
      stripped
    )
  ) {
    return true;
  }
  // The entire pre-verbal span is a negative subject NP (No document /
  // Nothing / Nobody), not an earlier unrelated "no"/"not".
  if (
    /^(?:no|nothing|nobody|none|neither)(?:\s+[A-Za-z][A-Za-z'-]*){0,9}$/i.test(
      stripped
    )
  ) {
    return true;
  }
  return false;
}

function matchRetractedHistorical(para, matchIdx, matchLen, liveConflict = false) {
  const { start, end } = sentenceBounds(para, matchIdx, matchLen);
  const sentence = para.slice(start, end);
  const local = localClaimUnit(para, matchIdx, matchLen);
  if (isRetractedHistorical(local)) return true;
  if (!isRetractedHistorical(sentence)) return false;
  // Same-sentence later/earlier active conflict is live unless that
  // clause is itself the historically framed claim being retracted.
  if (
    (liveConflict || paragraphConflictsWithAgents(local)) &&
    !isHistoricalFraming(local)
  ) {
    return false;
  }
  return true;
}

function agentsConflictRelation(value) {
  const text = collapseWs(authorityClaimHaystack(value));
  const participant =
    "(?:(?:this|the|our|that|a)\\s+)?(?:playbook|file|document|chapter|principles?|rules?|guidance|text|guide)";
  const conflict = "(?:conflicts?|disagrees?|clashes?|contradicts?)";
  return (
    new RegExp(
      `\\b${participant}\\b[^.!?;]{0,120}\\band\\s+AGENTS\\.md\\b[^.!?;]{0,120}\\b${conflict}\\b`,
      "i"
    ).test(text) ||
    new RegExp(
      `\\bAGENTS\\.md\\b[^.!?;]{0,120}\\band\\s+${participant}\\b[^.!?;]{0,120}\\b${conflict}\\b`,
      "i"
    ).test(text) ||
    new RegExp(
      `\\b${participant}\\b[^.!?;]{0,120}\\b${conflict}\\b[^.!?;]{0,120}\\bAGENTS\\.md\\b`,
      "i"
    ).test(text) ||
    new RegExp(
      `\\bAGENTS\\.md\\b[^.!?;]{0,120}\\b${conflict}\\b[^.!?;]{0,120}\\b${participant}\\b`,
      "i"
    ).test(text)
  );
}

function principleClaimConflictsWithAgents(para, matchIdx, matchLen) {
  const { start, end } = sentenceBounds(para, matchIdx, matchLen);
  const sentence = collapseWs(authorityClaimHaystack(para.slice(start, end)));
  if (agentsConflictRelation(sentence)) return true;

  // A tightly linked follow-up sentence preserves the preceding conflict's
  // referent without joining unrelated sentences in the paragraph.
  if (
    !/^(?:in\s+that\s+case|in\s+such\s+cases|where\s+they\s+do|when\s+they\s+do|if\s+so|then)\b/i.test(
      sentence
    )
  ) {
    return false;
  }
  const prefix = String(para || "").slice(0, start).trimEnd();
  if (!prefix) return false;
  const withoutTerminator = /[.!?]$/.test(prefix) ? prefix.slice(0, -1) : prefix;
  let previousStart = 0;
  const boundary = /[.!?][ \t\r\n]+/g;
  let m;
  while ((m = boundary.exec(withoutTerminator)) !== null) {
    previousStart = m.index + m[0].length;
  }
  const previous = collapseWs(
    authorityClaimHaystack(prefix.slice(previousStart))
  );
  return agentsConflictRelation(previous);
}

function paragraphDefersToAgents(para, claimId, matchIdx, matchLen) {
  const relationClaim = AUTHORITY_RELATION_CLAIM_IDS.has(claimId);
  const directRelation =
    relationClaim &&
    priorityMatchDirectlyTargetsAgents(para, matchIdx, matchLen);
  if (relationClaim && !directRelation) return true;
  if (matchRetractedHistorical(para, matchIdx, matchLen, directRelation)) {
    return true;
  }
  if (matchNegatesOperativeClaim(para, claimId, matchIdx, matchLen)) return true;
  if (claimAttributedToAgents(para, claimId)) return true;
  if (relationClaim) return false;
  if (
    claimId === "principle-wins-over-agents" &&
    principleClaimConflictsWithAgents(para, matchIdx, matchLen)
  ) {
    return false;
  }
  // Explicit operative conflict wins over a generic Follow-AGENTS
  // sentence in the same paragraph.
  if (paragraphConflictsWithAgents(para)) return false;
  if (claimId === "closed-list" || claimId === "self-authoritative") {
    return false;
  }
  return paragraphExplicitlyDefersToAgents(para);
}

function paragraphAt(text, idx, matchLen) {
  const found = text.lastIndexOf("\n\n", idx);
  const start = found === -1 ? 0 : found;
  const end = text.indexOf("\n\n", idx + matchLen);
  return {
    text: text.slice(start, end === -1 ? text.length : end),
    start,
  };
}

export function findOperativeClaims(text) {
  const hits = [];
  const original = String(text || "");
  const hay = authorityClaimHaystack(original);
  for (const pat of OPERATIVE_CLAIM_PATTERNS) {
    const flags = pat.re.flags.includes("g") ? pat.re.flags : `${pat.re.flags}g`;
    const re = new RegExp(pat.re.source, flags);
    let m;
    while ((m = re.exec(hay)) !== null) {
      if (!m[0] || m[0].length === 0) {
        re.lastIndex += 1;
        continue;
      }
      const idx = m.index;
      const para = paragraphAt(hay, idx, m[0].length);
      hits.push({
        id: pat.id,
        snippet: collapseWs(original.slice(idx, idx + m[0].length)).slice(0, 160),
        defersToAgents: paragraphDefersToAgents(
          para.text,
          pat.id,
          idx - para.start,
          m[0].length
        ),
        index: idx,
      });
    }
  }
  return hits;
}

/**
 * A non-normative file that asserts a closed/authoritative/operative list.
 * The complete file is evaluated: a live claim before the marker still
 * counts, and a generic AGENTS.md deferral does not erase an explicit
 * conflict unless that exact claim is historically retracted.
 */
export function findNonNormativeOperativeContradiction(text, nonNormativeMarker) {
  if (!text.includes(nonNormativeMarker)) return [];
  return findDocsAuthorityClaims(text);
}

export function findDocsAuthorityClaims(text) {
  return findOperativeClaims(text).filter((h) => !h.defersToAgents);
}

export const PROVENANCE_FORBIDDEN_ROLES = new Set([
  "canonical-doctrine",
  "compatibility-doctrine",
]);
export const PROVENANCE_ALLOWED_ROLES = new Set([
  "human-readable-contract",
  "explanatory-history",
  "supporting",
]);

/**
 * Path-bound provenance roles. Cross-field: exactly one AGENTS.md source
 * with role human-readable-contract; every docs/** source is
 * explanatory-history; human-readable-contract is forbidden on any other path.
 */
export function provenanceRoleFindings(sources) {
  const findings = [];
  const list = Array.isArray(sources) ? sources : [];
  const agentsSources = [];
  const contractSources = [];
  list.forEach((src, i) => {
    if (!src || typeof src !== "object") return;
    const path = typeof src.path === "string" ? src.path : "";
    const role = src.role;
    const loc = `provenance.sources[${i}]`;
    if (PROVENANCE_FORBIDDEN_ROLES.has(role) || role === "canonical-doctrine") {
      findings.push({
        code: "E_PROVENANCE_ROLE",
        message: `${path || loc} uses retired/forbidden provenance role ${role}`,
        path: loc,
      });
    } else if (role && !PROVENANCE_ALLOWED_ROLES.has(role)) {
      findings.push({
        code: "E_PROVENANCE_ROLE",
        message: `report-only candidate provenance role unknown: ${role}`,
        path: loc,
      });
    }
    if (path === "AGENTS.md") agentsSources.push({ src, loc, role });
    if (role === "human-readable-contract") contractSources.push({ src, loc, path });
    if (path === "AGENTS.md" && role && role !== "human-readable-contract") {
      findings.push({
        code: "E_PROVENANCE_ROLE",
        message: `AGENTS.md provenance source must use role human-readable-contract (got ${role})`,
        path: loc,
      });
    }
    if (path && path !== "AGENTS.md" && role === "human-readable-contract") {
      findings.push({
        code: "E_PROVENANCE_ROLE",
        message: `human-readable-contract is forbidden on ${path} (only AGENTS.md)`,
        path: loc,
      });
    }
    if (path.startsWith("docs/") && role && role !== "explanatory-history") {
      findings.push({
        code: "E_PROVENANCE_ROLE",
        message: `docs/ path ${path} must use explanatory-history (got ${role})`,
        path: loc,
      });
    }
  });
  if (agentsSources.length === 0) {
    findings.push({
      code: "E_PROVENANCE_ROLE",
      message:
        "exactly one provenance source must have path AGENTS.md and role human-readable-contract",
      path: "provenance.sources",
    });
  } else if (agentsSources.length > 1) {
    findings.push({
      code: "E_PROVENANCE_ROLE",
      message: "duplicate AGENTS.md provenance source",
      path: "provenance.sources",
    });
  }
  const agentsContract = agentsSources.filter((s) => s.role === "human-readable-contract");
  if (agentsSources.length === 1 && agentsContract.length !== 1) {
    findings.push({
      code: "E_PROVENANCE_ROLE",
      message: "AGENTS.md provenance source is not labeled human-readable-contract",
      path: agentsSources[0].loc,
    });
  }
  return findings;
}
