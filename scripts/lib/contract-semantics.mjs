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
// A self-authority subject is a bounded determiner phrase, not a closed noun
// list. Repositories use labels such as README, page, manual, runbook, policy,
// and note; enumerating those labels creates a fail-open vocabulary boundary.
const AUTHORITY_SELF_SUBJECT_RE =
  /\b(?:(?:this|that|our|the)\b[^\n,;:.!?\u2014]{0,120}|it)\s*$/i;
const SELF_AUTHORITATIVE_RE = new RegExp(
  String.raw`\b(?:this|that|our)\s+[^\s\n,;:.!?\u2014]+[^\n,;:.!?\u2014]{0,110}?\s+is\s+(?:the\s+)?(?:(?:authoritative\b(?!\s+(?:walkthrough|guide|history|explanation|overview|reference|documentation)\b))|binding contract|source of truth|canonical source)\b`,
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
  const { start: sentenceStart, end: sentenceEnd } = sentenceBounds(
    src,
    matchIdx,
    matchLen
  );
  const searchEnd = Math.min(sentenceEnd, relationEnd + 320);
  const { before } = localClaimSpan(src, matchIdx, matchLen);
  const subject = collapseWs(authorityClaimHaystack(before));
  const selfAuthoritySubject = AUTHORITY_SELF_SUBJECT_RE.test(subject);
  const passivePrefix = collapseWs(
    authorityClaimHaystack(src.slice(sentenceStart, matchIdx))
  );
  const passiveSuffix = collapseWs(
    authorityClaimHaystack(src.slice(relationEnd, sentenceEnd))
  );
  if (
    /\bAGENTS\.md\s+(?:(?:is|was|are|were|be|been|being)|(?:has|had|will|can|could|may|might|must|should|would)\s+be(?:en)?)(?:\s+[A-Za-z][A-Za-z'-]*){0,2}\s*$/i.test(
      passivePrefix
    ) && /^by\b/i.test(passiveSuffix)
  ) {
    return true;
  }
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

/**
 * Canonical PR-review terminal verdicts. The merge harness
 * (`scripts/release-preflight.sh`, `scripts/second-opinion.sh`) accepts
 * VERDICT: APPROVE / REQUEST_CHANGES. Stated limit: playbooks/ux-evaluator.md
 * uses VERDICT: PASS for graded live-preview eval; that token is not a
 * PR-review approval and is not consumed by the merge harness.
 */
export const CANONICAL_REVIEW_VERDICT_POSITIVE = "APPROVE";
export const CANONICAL_REVIEW_VERDICT_NEGATIVE = "REQUEST_CHANGES";
export const CANONICAL_REVIEW_HARNESS_FILES = [
  "scripts/second-opinion.sh",
  "scripts/release-preflight.sh",
];

const REVIEW_VERDICT_TOKEN_RE = /\bVERDICT:\s*([A-Za-z][A-Za-z0-9_-]*)/g;

function collectVerdictTokens(text) {
  const tokens = new Set();
  const src = String(text || "");
  const re = new RegExp(REVIEW_VERDICT_TOKEN_RE.source, "gi");
  let m;
  while ((m = re.exec(src)) !== null) {
    const tok = String(m[1] || "").toUpperCase().replace(/-/g, "_");
    if (tok) tokens.add(tok);
  }
  return tokens;
}

function harnessAcceptsApprove(text) {
  const t = String(text || "");
  if (harnessVerdictRegexGroupTokens(t).has("APPROVE")) return true;
  if (/VERDICT:\\s\*\(APPROVE/.test(t)) return true;
  if (/VERDICT:\\s\*\(APPROVE\|REQUEST_CHANGES\)/.test(t)) return true;
  if (/VERDICT:\[\[:space:\]\]\*approve/i.test(t)) return true;
  if (/VERDICT:\[\[:space:\]\]\*\(APPROVE/i.test(t)) return true;
  if (/VERDICT:\s*APPROVE\b/i.test(t)) return true;
  if (/VERDICT:\s*approve\b/.test(t)) return true;
  if (/\bAPPROVE\|REQUEST_CHANGES\b/.test(t) && /\bVERDICT\b/.test(t)) return true;
  return false;
}

/**
 * Quote context for canonical Bash grep forms only — not a general shell
 * parser. Tracks shell-slice none/single/double so BRE source-run rules can
 * differ for unquoted vs single-quoted vs double-quoted regexes. An unquoted
 * comment start (` #` / line-leading `#`) ends executable matching on that
 * physical line; `#` inside quotes is not a comment. One linear pass records
 * the state at every index; delimiter normalization must consume that map
 * instead of rescanning prefixes. Residual #264: $'...' ANSI-C quoting and
 * escaped quote context. Residual #263: executable-command provenance for
 * bare unquoted ERE groups and comment-only APPROVE text.
 */
function shellSliceQuoteStates(text) {
  const src = String(text || "");
  const n = src.length;
  const states = new Array(n);
  let state = "none";
  let i = 0;
  while (i < n) {
    states[i] = state;
    const c = src[i];
    if (state === "comment") {
      i += 1;
      continue;
    }
    if (state === "single") {
      i += 1;
      if (c === "'") state = "none";
      continue;
    }
    if (state === "double") {
      i += 1;
      if (c === "\\") {
        if (i < n) {
          states[i] = state;
          i += 1;
        }
        continue;
      }
      if (c === '"') state = "none";
      continue;
    }
    const atWordStart = i === 0 || /[ \t\r\n]/.test(src[i - 1] || "");
    if (c === "#" && atWordStart) {
      state = "comment";
      i += 1;
      continue;
    }
    i += 1;
    if (c === "'") state = "single";
    else if (c === '"') state = "double";
  }
  return states;
}

function quoteStateAfterPhysicalLine(line, initialState) {
  const src = String(line || "");
  let state = initialState || "none";
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (state === "single") {
      if (c === "'") state = "none";
      i += 1;
      continue;
    }
    if (state === "double") {
      if (c === "\\") {
        i += Math.min(2, src.length - i);
        continue;
      }
      if (c === '"') state = "none";
      i += 1;
      continue;
    }
    const atWordStart = i === 0 || src[i - 1] === " " || src[i - 1] === "\t";
    if (c === "#" && atWordStart) break;
    if (c === "\\") {
      i += Math.min(2, src.length - i);
      continue;
    }
    if (c === "'") state = "single";
    else if (c === '"') state = "double";
    i += 1;
  }
  return state;
}

function shellMatcherSlices(text) {
  const slices = [];
  let slice = "";
  let quoteState = "none";
  for (const line of String(text || "").split(/\r?\n/)) {
    slice = slice ? `${slice}\n${line}` : line;
    quoteState = quoteStateAfterPhysicalLine(line, quoteState);
    if (quoteState === "none") {
      slices.push(slice);
      slice = "";
    }
  }
  if (slice) slices.push(slice);
  return slices;
}

function unquotedCommentStart(line) {
  const src = String(line || "");
  let state = "none";
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (state === "single") {
      if (c === "'") state = "none";
      i += 1;
      continue;
    }
    if (state === "double") {
      if (c === "\\") {
        i += 1;
        if (i < src.length) i += 1;
        continue;
      }
      if (c === '"') state = "none";
      i += 1;
      continue;
    }
    const atWordStart = i === 0 || /[ \t\r\n]/.test(src[i - 1] || "");
    if (c === "#" && atWordStart) return i;
    if (c === "'") state = "single";
    else if (c === '"') state = "double";
    i += 1;
  }
  return -1;
}

function grepFamilyBase(word) {
  let w = String(word || "");
  if (w.length >= 2) {
    const a = w[0];
    const b = w[w.length - 1];
    if ((a === "'" && b === "'") || (a === '"' && b === '"')) {
      w = w.slice(1, -1);
    }
  }
  const slash = w.lastIndexOf("/");
  return slash === -1 ? w : w.slice(slash + 1);
}

function isGrepFamilyWord(word) {
  const base = grepFamilyBase(word);
  return base === "grep" || base === "egrep" || base === "fgrep";
}

function isEnvUtilityWord(word) {
  return grepFamilyBase(word) === "env";
}

function isCommandUtilityWord(word) {
  return grepFamilyBase(word) === "command";
}

/** Short grep options whose next argv (or attached tail) is an operand. */
const GREP_SHORT_OPERAND = {
  e: "pattern",
  f: "file",
  m: "count",
  A: "count",
  B: "count",
  C: "count",
  D: "action",
  d: "action",
};

/** Long grep options that take a separate or `--name=value` operand. */
const GREP_LONG_OPERAND = {
  "--regexp": "pattern",
  "--file": "file",
  "--max-count": "count",
  "--after-context": "count",
  "--before-context": "count",
  "--context": "count",
  "--devices": "action",
  "--directories": "action",
  "--label": "label",
  "--exclude": "glob",
  "--exclude-from": "file",
  "--exclude-dir": "glob",
  "--include": "glob",
  "--binary-files": "type",
};

/**
 * Split a shell slice into command-list segments on unquoted `;`, `&&`,
 * `||`, and bare `&` only. Quote/#-comment aware via the same bounded
 * scanner used elsewhere — not a general shell parser. Pipeline `|` is
 * isolated later by `shellPipelineStages` so grep ERE/BRE mode is per
 * executable grep command.
 */
function shellCommandListSegments(shellSlice) {
  const src = String(shellSlice || "");
  const segments = [];
  let start = 0;
  let state = "none";
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (state === "single") {
      if (c === "'") state = "none";
      i += 1;
      continue;
    }
    if (state === "double") {
      if (c === "\\") {
        i += Math.min(2, src.length - i);
        continue;
      }
      if (c === '"') state = "none";
      i += 1;
      continue;
    }
    const atWordStart = i === 0 || /[ \t\r\n]/.test(src[i - 1] || "");
    if (c === "#" && atWordStart) break;
    if (c === "\\") {
      i += Math.min(2, src.length - i);
      continue;
    }
    if (c === "'") {
      state = "single";
      i += 1;
      continue;
    }
    if (c === '"') {
      state = "double";
      i += 1;
      continue;
    }
    if (c === ";") {
      segments.push(src.slice(start, i));
      i += 1;
      start = i;
      continue;
    }
    if (c === "&" && src[i + 1] === "&") {
      segments.push(src.slice(start, i));
      i += 2;
      start = i;
      continue;
    }
    if (c === "|" && src[i + 1] === "|") {
      segments.push(src.slice(start, i));
      i += 2;
      start = i;
      continue;
    }
    if (c === "&") {
      segments.push(src.slice(start, i));
      i += 1;
      start = i;
      continue;
    }
    i += 1;
  }
  segments.push(src.slice(start));
  return segments;
}

function isEnvAssignmentWord(word) {
  const w = String(word || "");
  const eq = w.indexOf("=");
  if (eq <= 0) return false;
  const name = w.slice(0, eq);
  for (let i = 0; i < name.length; i += 1) {
    const c = name.charCodeAt(i);
    const letter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95;
    const digit = c >= 48 && c <= 57;
    if (!(letter || (i > 0 && digit))) return false;
  }
  return true;
}

function isRedirectionWord(word) {
  const w = String(word || "");
  // Glued forms (`2>/dev/null`, `>&1`, `&>>log`) and bare ops (`>`, `2>`).
  return /^(?:\d*)(?:>>?|<<?|>&|<&|&>>?)/.test(w);
}

function redirectionConsumesTarget(word) {
  const w = String(word || "");
  if (/^(?:\d*)>&\d+$/.test(w) || /^(?:\d*)<&\d+$/.test(w)) return false;
  if (/^(?:\d*)(?:>>?|<<?|&>>?)/.test(w)) {
    const rest = w.replace(/^(?:\d*)(?:>>?|<<?|&>>?)/, "");
    return rest.length === 0;
  }
  return false;
}

/**
 * Quote/#-comment aware shell word scanner. Redirection operators keep
 * glued targets (`2>/dev/null`) as one word so stage normalization can
 * carry leading redirections beside wrappers. Residual: not a general
 * shell parser (ANSI-C quotes, here-docs, extended globs).
 */
function unquotedShellWords(src) {
  const words = [];
  const n = src.length;
  let state = "none";
  let i = 0;
  let start = -1;
  const flush = (end) => {
    if (start !== -1 && end > start) {
      words.push({ start, end, word: src.slice(start, end) });
    }
    start = -1;
  };
  const isBreakMeta = (c) =>
    c === "|" ||
    c === "&" ||
    c === ";" ||
    c === "(" ||
    c === ")" ||
    c === "\n" ||
    c === "\r";
  while (i < n) {
    const c = src[i];
    if (state === "single") {
      if (start === -1) start = i;
      i += 1;
      if (c === "'") state = "none";
      continue;
    }
    if (state === "double") {
      if (start === -1) start = i;
      if (c === "\\") {
        i += Math.min(2, n - i);
        continue;
      }
      i += 1;
      if (c === '"') state = "none";
      continue;
    }
    const atWordStart = i === 0 || /[ \t\r\n]/.test(src[i - 1] || "");
    if (c === "#" && atWordStart) break;
    if (c === "\\") {
      if (start === -1) start = i;
      i += Math.min(2, n - i);
      continue;
    }
    if (c === "'") {
      if (start === -1) start = i;
      state = "single";
      i += 1;
      continue;
    }
    if (c === '"') {
      if (start === -1) start = i;
      state = "double";
      i += 1;
      continue;
    }
    if (c === "<" || c === ">") {
      const digitOnly =
        start !== -1 && /^\d+$/.test(src.slice(start, i)) ? start : -1;
      if (start !== -1 && digitOnly === -1) flush(i);
      const redirStart = digitOnly !== -1 ? digitOnly : i;
      start = redirStart;
      if (c === ">" && src[i + 1] === ">") i += 2;
      else if (c === "<" && src[i + 1] === "<") i += 2;
      else i += 1;
      if (src[i] === "&") {
        i += 1;
        while (i < n && /\d/.test(src[i])) i += 1;
        flush(i);
        continue;
      }
      while (
        i < n &&
        src[i] !== " " &&
        src[i] !== "\t" &&
        !isBreakMeta(src[i]) &&
        src[i] !== "<" &&
        src[i] !== ">" &&
        src[i] !== "'" &&
        src[i] !== '"'
      ) {
        if (src[i] === "\\") {
          i += Math.min(2, n - i);
          continue;
        }
        const atWs = i === 0 || /[ \t\r\n]/.test(src[i - 1] || "");
        if (src[i] === "#" && atWs) break;
        i += 1;
      }
      flush(i);
      continue;
    }
    if (c === "&" && src[i + 1] === ">") {
      if (start !== -1) flush(i);
      start = i;
      i += 2;
      if (src[i] === ">") i += 1;
      while (
        i < n &&
        src[i] !== " " &&
        src[i] !== "\t" &&
        !isBreakMeta(src[i]) &&
        src[i] !== "<" &&
        src[i] !== ">" &&
        src[i] !== "'" &&
        src[i] !== '"'
      ) {
        if (src[i] === "\\") {
          i += Math.min(2, n - i);
          continue;
        }
        i += 1;
      }
      flush(i);
      continue;
    }
    if (c === " " || c === "\t" || isBreakMeta(c)) {
      flush(i);
      i += 1;
      continue;
    }
    if (start === -1) start = i;
    i += 1;
  }
  flush(i);
  return words;
}

/**
 * Split one command-list segment into pipeline stages. Every unquoted,
 * unescaped single `|` outside quotes is a pipeline connector; `||` is
 * not. Quoted or escaped regex alternation is not a stage boundary. Do
 * not infer connectors by guessing whether a later token looks like
 * grep. Residual #263/#264: not a general shell parser.
 */
function shellPipelineStages(segment) {
  const src = String(segment || "");
  const stages = [];
  let start = 0;
  let state = "none";
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (state === "single") {
      if (c === "'") state = "none";
      i += 1;
      continue;
    }
    if (state === "double") {
      if (c === "\\") {
        i += Math.min(2, src.length - i);
        continue;
      }
      if (c === '"') state = "none";
      i += 1;
      continue;
    }
    const atWordStart = i === 0 || /[ \t\r\n]/.test(src[i - 1] || "");
    if (c === "#" && atWordStart) break;
    if (c === "\\") {
      i += Math.min(2, src.length - i);
      continue;
    }
    if (c === "'") {
      state = "single";
      i += 1;
      continue;
    }
    if (c === '"') {
      state = "double";
      i += 1;
      continue;
    }
    if (c === "|" && src[i + 1] === "|") {
      i += 2;
      continue;
    }
    if (c === "|") {
      stages.push(src.slice(start, i));
      i += 1;
      start = i;
      continue;
    }
    i += 1;
  }
  stages.push(src.slice(start));
  return stages;
}

/**
 * Resolve one already-scanned shell word (quotes + backslash-escapes) to
 * the value it would receive as argv, so wrapper/option classification
 * treats whole-word-quoted forms (`'-y'`, `"-S"`, `-'P'`) identically to
 * bare ones. Classification-only: `scanText`/raw source still feeds
 * regex/BRE quote-state parsing untouched. An unterminated quote or a
 * trailing lone backslash is ambiguous and fails closed rather than
 * guessing a value.
 */
function decodeArgvWord(word) {
  const w = String(word || "");
  let out = "";
  let state = "none";
  let i = 0;
  while (i < w.length) {
    const c = w[i];
    if (state === "single") {
      if (c === "'") {
        state = "none";
        i += 1;
        continue;
      }
      out += c;
      i += 1;
      continue;
    }
    if (state === "double") {
      if (c === "\\") {
        const n = w[i + 1];
        if (n === '"' || n === "\\" || n === "$" || n === "`") {
          out += n;
          i += 2;
          continue;
        }
        if (n === undefined) return { value: out, ambiguous: true };
        out += c;
        i += 1;
        continue;
      }
      if (c === '"') {
        state = "none";
        i += 1;
        continue;
      }
      out += c;
      i += 1;
      continue;
    }
    if (c === "'") {
      state = "single";
      i += 1;
      continue;
    }
    if (c === '"') {
      state = "double";
      i += 1;
      continue;
    }
    if (c === "\\") {
      const n = w[i + 1];
      if (n === undefined) return { value: out, ambiguous: true };
      out += n;
      i += 2;
      continue;
    }
    out += c;
    i += 1;
  }
  if (state !== "none") return { value: out, ambiguous: true };
  return { value: out, ambiguous: false };
}

/**
 * Bounded decoder for a GNU `env -S`/`--split-string` operand — env's own
 * mini-language, distinct from general shell syntax. Whitespace and
 * quotes group argv words as usual; an env-level `\_` outside quotes is a
 * forced argv separator (used to defeat naive whitespace tokenizers, e.g.
 * `grep\_-y\_'pattern'`), and `\\`/`\'`/`\"`/`\t`/`\n` resolve to their
 * literal character. Any other backslash escape is unrecognized and fails
 * closed (`unresolved: true`) rather than guessing at intent. Quoted
 * content is copied through unresolved so nested BRE escapes (`\(`, `\|`,
 * `\)`) reach the caller's regex parsing unchanged.
 */
function tokenizeEnvSplitString(raw) {
  const src = String(raw || "");
  const words = [];
  let cur = "";
  let started = false;
  let state = "none";
  let i = 0;
  const flush = () => {
    if (started) words.push(cur);
    cur = "";
    started = false;
  };
  while (i < src.length) {
    const c = src[i];
    if (state === "single") {
      started = true;
      if (c === "'") {
        state = "none";
        i += 1;
        continue;
      }
      cur += c;
      i += 1;
      continue;
    }
    if (state === "double") {
      started = true;
      if (c === "\\") {
        const n = src[i + 1];
        if (n === '"' || n === "\\" || n === "$" || n === "`") {
          cur += n;
          i += 2;
          continue;
        }
        if (n === undefined) return { words, unresolved: true };
        cur += c;
        i += 1;
        continue;
      }
      if (c === '"') {
        state = "none";
        i += 1;
        continue;
      }
      cur += c;
      i += 1;
      continue;
    }
    if (c === " " || c === "\t" || c === "\n" || c === "\r") {
      flush();
      i += 1;
      continue;
    }
    if (c === "'") {
      state = "single";
      started = true;
      i += 1;
      continue;
    }
    if (c === '"') {
      state = "double";
      started = true;
      i += 1;
      continue;
    }
    if (c === "\\") {
      const n = src[i + 1];
      if (n === "_") {
        flush();
        i += 2;
        continue;
      }
      if (n === "\\" || n === "'" || n === '"') {
        cur += n;
        started = true;
        i += 2;
        continue;
      }
      if (n === "t") {
        cur += "\t";
        started = true;
        i += 2;
        continue;
      }
      if (n === "n") {
        cur += "\n";
        started = true;
        i += 2;
        continue;
      }
      return { words, unresolved: true };
    }
    cur += c;
    started = true;
    i += 1;
  }
  flush();
  if (state !== "none") return { words, unresolved: true };
  return { words, unresolved: false };
}

function splitEnvOperandIntoWords(operandRaw) {
  const split = tokenizeEnvSplitString(operandRaw);
  if (split.unresolved || !split.words.length) return null;
  return split.words.map((word) => ({ start: 0, end: 0, word }));
}

/**
 * Consume `env` utility options. Every option word is resolved through
 * `decodeArgvWord` first so a whole-word-quoted `'-S'`, `"-P"`, or
 * `--split-string='...'` classifies exactly like its unquoted form; an
 * ambiguous decode fails closed. Separated `-P`/`--path` operands are
 * skipped so the executable command remains visible. `-S` /
 * `--split-string` (GNU spelling) splice the finite nested command
 * string into `words` in place and return the index at that nested
 * command — callers continue wrapper normalization from there. The
 * operand is decoded through the shell quoting layer, then through
 * `tokenizeEnvSplitString` for env's own separator/escape rules. Missing
 * or unresolved split-string operands fail closed via `unresolved: true`.
 *
 * @returns {{ index: number, unresolved?: boolean }}
 */
function skipEnvUtilityArgs(words, i) {
  let u = i;
  while (u < words.length) {
    const raw = words[u].word;
    if (isEnvAssignmentWord(raw)) {
      u += 1;
      continue;
    }
    const decoded = decodeArgvWord(raw);
    if (decoded.ambiguous) return { index: u, unresolved: true };
    const w = decoded.value;
    if (w === "-S" || w === "--split-string") {
      if (u + 1 >= words.length) return { index: u, unresolved: true };
      const operand = decodeArgvWord(words[u + 1].word);
      if (operand.ambiguous) return { index: u, unresolved: true };
      const nestedWords = splitEnvOperandIntoWords(operand.value);
      if (!nestedWords) return { index: u, unresolved: true };
      words.splice(u, 2, ...nestedWords);
      return { index: u };
    }
    if (w.startsWith("--split-string=")) {
      const nestedWords = splitEnvOperandIntoWords(
        w.slice("--split-string=".length)
      );
      if (!nestedWords) return { index: u, unresolved: true };
      words.splice(u, 1, ...nestedWords);
      return { index: u };
    }
    if (w.startsWith("-S") && w.length > 2) {
      const nestedWords = splitEnvOperandIntoWords(w.slice(2));
      if (!nestedWords) return { index: u, unresolved: true };
      words.splice(u, 1, ...nestedWords);
      return { index: u };
    }
    if (w === "-P" || w === "--path") {
      u += 1;
      if (u < words.length) u += 1;
      continue;
    }
    if (w.startsWith("--path=")) {
      u += 1;
      continue;
    }
    if (w.startsWith("-P") && w.length > 2) {
      u += 1;
      continue;
    }
    if (w === "-u" || w === "-C" || w === "--unset" || w === "--chdir") {
      u += 2;
      continue;
    }
    if (w.startsWith("--unset=") || w.startsWith("--chdir=")) {
      u += 1;
      continue;
    }
    if (w.startsWith("-") && w.length > 1) {
      u += 1;
      continue;
    }
    break;
  }
  return { index: u };
}

function isShellKeywordWord(word) {
  const w = String(word || "");
  return (
    w === "!" ||
    w === "{" ||
    w === "}" ||
    /^(?:if|then|else|elif|fi|while|until|for|do|done|case|esac|select|time|function)$/.test(
      w
    )
  );
}

/**
 * One normalized executable-command representation consumed by all
 * verdict classification. Carries wrappers (`command`, `env`, including
 * absolute-path `env`, assignments), leading redirections, grep dialect,
 * and grep flags in the same object. Wrappers are consumed iteratively
 * in valid order (`env command`, `command env`, `/usr/bin/env`) for the
 * finite parsed word list — not a magic depth. Every wrapper iteration
 * must advance the word cursor. If a defensive cap is exhausted while a
 * recognized wrapper remains, fail closed rather than classifying the
 * stage as a green `other`. `env -P`/`--path` consume their path
 * operand. `env -S`/`--split-string` splice a finite nested command
 * string (fail closed when unresolved). `command -v/-V` is
 * introspection-only and never an executable verdict matcher; names
 * after those flags are not executed. Operand-taking grep options
 * (`-m`/`-A`/`-C`/`--max-count`, `-e`/`--regexp`, `-f`/`--file`)
 * consume separated or attached operands so later dialect/case flags
 * remain visible. Matcher-affecting options after the first bare
 * pattern (`grep 'pat' -y`) are modeled. `-e` does not end option
 * parsing. `-i`/`-y`/`--ignore-case` set ignore-case (`-y` is the
 * obsolete GNU/BSD synonym of `-i`, including bundled orderings).
 * `-f`/`--file` is fail-closed (pattern file unread). Residual: not a
 * general shell parser.
 *
 * @returns {{
 *   kind: 'grep' | 'introspection' | 'other',
 *   dialect: 'bre' | 'ere' | 'fixed',
 *   ignoreCase: boolean,
 *   wrappers: string[],
 *   leadingRedirs: string[],
 *   scanText: string,
 *   unsupportedExecutableMatcher: boolean,
 *   patternFile: boolean,
 *   unresolvedWrapper: boolean,
 * }}
 */
function normalizeExecutableStage(stage) {
  const commentAt = unquotedCommentStart(stage);
  const slice = commentAt === -1 ? String(stage || "") : String(stage || "").slice(0, commentAt);
  const words = unquotedShellWords(slice);
  const wrappers = [];
  const leadingRedirs = [];
  let i = 0;
  const empty = {
    kind: "other",
    dialect: "bre",
    ignoreCase: false,
    wrappers,
    leadingRedirs,
    scanText: slice,
    unsupportedExecutableMatcher: false,
    patternFile: false,
    unresolvedWrapper: false,
  };
  const failClosedUnresolvedWrapper = () => ({
    ...empty,
    unresolvedWrapper: true,
    unsupportedExecutableMatcher: true,
  });
  const skipPrefixNoise = () => {
    while (i < words.length) {
      const w = words[i].word;
      if (isRedirectionWord(w)) {
        leadingRedirs.push(w);
        i += 1;
        if (redirectionConsumesTarget(w) && i < words.length && !isRedirectionWord(words[i].word)) {
          leadingRedirs.push(words[i].word);
          i += 1;
        }
        continue;
      }
      if (isEnvAssignmentWord(w)) {
        wrappers.push(w);
        i += 1;
        continue;
      }
      // Production harnesses wrap matchers as `if grep ...; then`. Skip
      // reserved words so the executable grep (and its -i flag) remains
      // visible to verdict classification.
      if (isShellKeywordWord(w)) {
        i += 1;
        continue;
      }
      break;
    }
  };
  skipPrefixNoise();
  let introspection = false;
  // Cap is the finite parsed input, not a magic depth. Nine (or 32)
  // valid `env` wrappers must still reveal the executable grep.
  let wrapperCap = words.length;
  let wrapperGuard = 0;
  while (i < words.length && !introspection) {
    const remainingWrapper =
      isEnvUtilityWord(words[i].word) || isCommandUtilityWord(words[i].word);
    if (!remainingWrapper) break;
    if (wrapperGuard >= wrapperCap) {
      return failClosedUnresolvedWrapper();
    }
    wrapperGuard += 1;
    const before = i;
    if (isEnvUtilityWord(words[i].word)) {
      wrappers.push(words[i].word);
      i += 1;
      const skipped = skipEnvUtilityArgs(words, i);
      if (skipped.unresolved) {
        return failClosedUnresolvedWrapper();
      }
      // Nested -S/--split-string words replace the option in place; the
      // cursor stays on the nested command so the next loop iteration
      // (or skipPrefixNoise) can see env/command/grep monotonically.
      if (skipped.index < i) {
        return failClosedUnresolvedWrapper();
      }
      i = skipped.index;
      wrapperCap = words.length;
      skipPrefixNoise();
    } else if (isCommandUtilityWord(words[i].word)) {
      wrappers.push(words[i].word);
      i += 1;
      while (i < words.length) {
        const w = words[i].word;
        if (w === "--") {
          i += 1;
          break;
        }
        if (w === "-v" || w === "-V") {
          introspection = true;
          i += 1;
          continue;
        }
        if (w === "-p") {
          i += 1;
          continue;
        }
        if (/^-[pvV]+$/.test(w)) {
          if (/[vV]/.test(w)) introspection = true;
          i += 1;
          continue;
        }
        break;
      }
      if (!introspection) skipPrefixNoise();
    } else {
      break;
    }
    if (i <= before) {
      return failClosedUnresolvedWrapper();
    }
  }
  if (
    !introspection &&
    i < words.length &&
    (isEnvUtilityWord(words[i].word) || isCommandUtilityWord(words[i].word))
  ) {
    return failClosedUnresolvedWrapper();
  }
  if (!introspection) skipPrefixNoise();
  if (i >= words.length) {
    return { ...empty, wrappers: wrappers.slice(), leadingRedirs: leadingRedirs.slice() };
  }
  const cmdWord = words[i].word;
  if (!isGrepFamilyWord(cmdWord)) {
    return {
      ...empty,
      kind: introspection ? "introspection" : "other",
      wrappers: wrappers.slice(),
      leadingRedirs: leadingRedirs.slice(),
    };
  }
  if (introspection) {
    return {
      kind: "introspection",
      dialect: "bre",
      ignoreCase: false,
      wrappers: wrappers.slice(),
      leadingRedirs: leadingRedirs.slice(),
      scanText: slice,
      unsupportedExecutableMatcher: false,
      patternFile: false,
      unresolvedWrapper: false,
    };
  }
  const base = grepFamilyBase(cmdWord);
  let dialect = base === "egrep" ? "ere" : base === "fgrep" ? "fixed" : "bre";
  let ignoreCase = false;
  let unsupportedExecutableMatcher = false;
  let patternFile = false;
  i += 1;
  while (i < words.length) {
    const raw = words[i].word;
    if (isRedirectionWord(raw)) {
      i += 1;
      if (redirectionConsumesTarget(raw) && i < words.length) i += 1;
      continue;
    }
    // Whole-word ordinary quoting around an option (`'-y'`, `"-y"`,
    // `'--ignore-case'`) must classify exactly like the unquoted form —
    // the shell strips those quotes identically before grep ever sees
    // argv. An ambiguous decode (unterminated quote) fails closed rather
    // than silently treating the option as inert.
    const decoded = decodeArgvWord(raw);
    if (decoded.ambiguous) {
      unsupportedExecutableMatcher = true;
      i += 1;
      continue;
    }
    const w = decoded.value;
    if (w === "--") {
      i += 1;
      // After `--`, remaining words are operands; matcher-affecting
      // options cannot follow. Stop closed rather than inventing a
      // second option scan past operand-only args.
      break;
    }
    if (w === "--ignore-case") {
      ignoreCase = true;
      i += 1;
      continue;
    }
    if (w === "--extended-regexp") {
      dialect = "ere";
      i += 1;
      continue;
    }
    if (w === "--basic-regexp") {
      dialect = "bre";
      i += 1;
      continue;
    }
    if (w === "--fixed-strings") {
      dialect = "fixed";
      i += 1;
      continue;
    }
    if (w === "--perl-regexp") {
      unsupportedExecutableMatcher = true;
      i += 1;
      continue;
    }
    if (w.startsWith("--")) {
      const eq = w.indexOf("=");
      const name = eq === -1 ? w : w.slice(0, eq);
      const operandKind = GREP_LONG_OPERAND[name];
      if (operandKind) {
        i += 1;
        if (eq !== -1) {
          if (operandKind === "file") patternFile = true;
          continue;
        }
        if (i < words.length) {
          if (operandKind === "file") patternFile = true;
          i += 1;
        }
        continue;
      }
      i += 1;
      continue;
    }
    if (w.startsWith("-") && w.length > 1 && !isEnvAssignmentWord(w)) {
      const body = w.slice(1);
      i += 1;
      let ci = 0;
      while (ci < body.length) {
        const ch = body[ci];
        if (ch === "i" || ch === "y") ignoreCase = true;
        else if (ch === "E") dialect = "ere";
        else if (ch === "G") dialect = "bre";
        else if (ch === "F") dialect = "fixed";
        else if (ch === "P") unsupportedExecutableMatcher = true;
        const operandKind = GREP_SHORT_OPERAND[ch];
        if (operandKind) {
          const attached = body.slice(ci + 1);
          if (attached.length) {
            if (operandKind === "file") patternFile = true;
          } else if (i < words.length) {
            if (operandKind === "file") patternFile = true;
            i += 1;
          }
          break;
        }
        ci += 1;
      }
      continue;
    }
    // Bare pattern or file operand. BSD/GNU grep still accept later
    // matcher-affecting options (`grep 'pat' -y`), so keep scanning.
    i += 1;
  }
  return {
    kind: "grep",
    dialect,
    ignoreCase,
    wrappers: wrappers.slice(),
    leadingRedirs: leadingRedirs.slice(),
    scanText: slice,
    unsupportedExecutableMatcher,
    patternFile,
    unresolvedWrapper: false,
  };
}

function executableBreDelimRun(slashCount, quoteState) {
  // Quote context for canonical Bash grep forms (not a general parser):
  // - double-quoted source: a run of one or two backslashes immediately
  //   before `(`, `)`, or `|` becomes the one runtime backslash grep BRE
  //   needs. Both `"\(...\)"` and `"\\(...\\)"` are executable. Runs of
  //   three or more stay extra runtime backslashes and are not grouping.
  // - single-quoted source: only a run of one backslash is executable.
  //   `'\(...\)'` is executable; `'\\(...\\)'` remains two runtime
  //   backslashes and is not BRE grouping/alternation.
  // - unquoted source: run 1 is received as literal `(`/`|`/`)` (grep rc 1
  //   on `VERDICT: APPROVE`); run 2 leaves an unquoted `(` (Bash syntax
  //   error, rc 2); run 3 is the executable form (`\\\(` → `\(`). Nearby
  //   longer runs change the pattern and do not match ordinary verdict
  //   samples. Do not consume a suffix of a longer run.
  if (quoteState === "comment") return false;
  if (slashCount === 1) return quoteState === "single" || quoteState === "double";
  if (slashCount === 2) return quoteState === "double";
  if (slashCount === 3) return quoteState === "none";
  return false;
}

const POSIX_CLASS_PRED = {
  space: (ch) => /\s/.test(ch),
  blank: (ch) => ch === " " || ch === "\t",
  digit: (ch) => ch >= "0" && ch <= "9",
  xdigit: (ch) => /[0-9A-Fa-f]/.test(ch),
  alnum: (ch) => /[A-Za-z0-9]/.test(ch),
  alpha: (ch) => /[A-Za-z]/.test(ch),
  lower: (ch) => ch >= "a" && ch <= "z",
  upper: (ch) => ch >= "A" && ch <= "Z",
  word: (ch) => /[A-Za-z0-9_]/.test(ch),
  punct: (ch) => /[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]/.test(ch),
};

function charsEqFold(a, b) {
  return a === b || a.toUpperCase() === b.toUpperCase();
}

function parseCountedInterval(inner) {
  const m = /^(\d+)(?:,(\d*))?$/.exec(inner);
  if (!m) return null;
  const min = Number(m[1]);
  if (!Number.isFinite(min) || min < 0) return null;
  const max = m[2] === undefined ? min : m[2] === "" ? Infinity : Number(m[2]);
  if (max !== Infinity && (!Number.isFinite(max) || max < 0)) return null;
  return { min, max };
}

function parseVerdictAltQuantifier(src, i, dialect) {
  if (src[i] === "*") return { min: 0, max: Infinity, next: i + 1 };
  if (dialect === "ere") {
    if (src[i] === "?") return { min: 0, max: 1, next: i + 1 };
    if (src[i] === "+") return { min: 1, max: Infinity, next: i + 1 };
    if (src[i] === "{") {
      const close = src.indexOf("}", i + 1);
      if (close !== -1) {
        const parsed = parseCountedInterval(src.slice(i + 1, close));
        if (parsed) return { min: parsed.min, max: parsed.max, next: close + 1 };
      }
    }
  }
  if (dialect === "bre" && src[i] === "\\") {
    const n = src[i + 1];
    if (n === "?") return { min: 0, max: 1, next: i + 2 };
    if (n === "+") return { min: 1, max: Infinity, next: i + 2 };
    if (n === "{") {
      const close = src.indexOf("\\}", i + 2);
      if (close !== -1) {
        const parsed = parseCountedInterval(src.slice(i + 2, close));
        if (parsed) return { min: parsed.min, max: parsed.max, next: close + 2 };
      }
    }
  }
  return null;
}

function parseVerdictAltAtom(src, i) {
  // Shell backslash-newline is line continuation, not a regex atom
  // (`APPROVE|\` / `PASS)`). Do not fold other punctuation away.
  while (i < src.length && src[i] === "\\") {
    const n = src[i + 1];
    if (n === "\n") {
      i += 2;
      continue;
    }
    if (n === "\r") {
      i += src[i + 2] === "\n" ? 3 : 2;
      continue;
    }
    break;
  }
  if (i >= src.length) return null;
  if (src.startsWith("[[:", i)) {
    const close = src.indexOf(":]]", i + 3);
    if (close !== -1) {
      const name = src.slice(i + 3, close).toLowerCase();
      return { kind: "posix", name, next: close + 3 };
    }
  }
  if (src[i] === "[") {
    let j = i + 1;
    if (src[j] === "^") j += 1;
    if (src[j] === "]") j += 1;
    while (j < src.length && src[j] !== "]") j += 1;
    if (j < src.length && src[j] === "]") {
      return { kind: "class", raw: src.slice(i, j + 1), next: j + 1 };
    }
  }
  if (src[i] === ".") return { kind: "any", next: i + 1 };
  if (src[i] === "\\") {
    if (i + 1 >= src.length) return { kind: "char", ch: "\\", next: i + 1 };
    return { kind: "char", ch: src[i + 1], next: i + 2 };
  }
  return { kind: "char", ch: src[i], next: i + 1 };
}

function compileVerdictAltAtoms(src, dialect) {
  const atoms = [];
  let i = 0;
  while (i < src.length) {
    const atom = parseVerdictAltAtom(src, i);
    if (!atom) break;
    i = atom.next;
    const q = parseVerdictAltQuantifier(src, i, dialect);
    if (q) {
      atom.min = q.min;
      atom.max = q.max;
      i = q.next;
    } else {
      atom.min = 1;
      atom.max = 1;
    }
    atoms.push(atom);
  }
  return atoms;
}

function classMatchesChar(raw, ch, ignoreCase) {
  const neg = raw[1] === "^";
  const inner = raw.slice(neg ? 2 : 1, -1);
  const candidates = ignoreCase
    ? Array.from(
        new Set([
          ch,
          ch.toLowerCase(),
          ch.toUpperCase(),
        ])
      )
    : [ch];
  let hit = false;
  for (const cand of candidates) {
    if (inner.includes(cand)) {
      hit = true;
      break;
    }
    for (let k = 0; k + 2 < inner.length; k += 1) {
      if (inner[k + 1] === "-" && inner[k] <= cand && cand <= inner[k + 2]) {
        hit = true;
        break;
      }
    }
    if (hit) break;
  }
  return neg ? !hit : hit;
}

function consumeVerdictAtom(atom, want, ti, ignoreCase) {
  if (ti >= want.length) return -1;
  const ch = want[ti];
  if (atom.kind === "any") return 1;
  if (atom.kind === "char") return charsEqFold(atom.ch, ch) ? 1 : -1;
  if (atom.kind === "posix") {
    const pred = POSIX_CLASS_PRED[atom.name];
    if (!pred) return -1;
    if (ignoreCase && (atom.name === "lower" || atom.name === "upper" || atom.name === "alpha")) {
      return /[A-Za-z]/.test(ch) ? 1 : -1;
    }
    if (ignoreCase) {
      return pred(ch) || pred(ch.toLowerCase()) || pred(ch.toUpperCase()) ? 1 : -1;
    }
    return pred(ch) ? 1 : -1;
  }
  if (atom.kind === "class") {
    return classMatchesChar(atom.raw, ch, Boolean(ignoreCase)) ? 1 : -1;
  }
  return -1;
}

/**
 * Does this one regex alternative match a literal verdict token?
 * Interprets POSIX classes and BRE/ERE quantifiers on the alternative
 * (`PASS[[:space:]]*`, `P\?PASS`) instead of deleting punctuation, which
 * would glue `[[:space:]]` / `\?` into fake tokens such as PASSSPACE or
 * PPASS. When ignoreCase is set (grep `-i` / `--ignore-case`), bracket
 * and POSIX-class atoms fold case so `P[a]SS` detects PASS. Bounded:
 * pattern and token lengths are capped.
 */
function verdictAltMatchesLiteral(raw, token, dialect, ignoreCase) {
  const src = String(raw || "");
  const want = String(token || "");
  if (!src || !want || src.length > 240 || want.length > 32) return false;
  const atoms = compileVerdictAltAtoms(src, dialect || "bre");
  if (!atoms) return false;
  const fold = Boolean(ignoreCase);
  const memo = new Map();
  function rec(ai, ti) {
    const key = `${ai}:${ti}`;
    if (memo.has(key)) return memo.get(key);
    if (ai === atoms.length) {
      const okEnd = ti === want.length;
      memo.set(key, okEnd);
      return okEnd;
    }
    const atom = atoms[ai];
    let t = ti;
    let k = 0;
    while (k < atom.min) {
      const n = consumeVerdictAtom(atom, want, t, fold);
      if (n < 0) {
        memo.set(key, false);
        return false;
      }
      t += n;
      k += 1;
    }
    while (k <= atom.max) {
      if (rec(ai + 1, t)) {
        memo.set(key, true);
        return true;
      }
      if (k === atom.max) break;
      const n = consumeVerdictAtom(atom, want, t, fold);
      if (n < 0) break;
      t += n;
      k += 1;
    }
    memo.set(key, false);
    return false;
  }
  return rec(0, 0);
}

function addVerdictToken(tokens, raw, dialect, ignoreCase) {
  const src = String(raw || "");
  if (!src) return;
  const mode = dialect || "bre";
  for (const cand of ["APPROVE", "PASS", "REQUEST_CHANGES"]) {
    if (verdictAltMatchesLiteral(src, cand, mode, ignoreCase)) tokens.add(cand);
  }
  const ident = src.trim();
  if (/^[A-Za-z][A-Za-z0-9_]*$/.test(ident)) {
    tokens.add(ident.toUpperCase());
  }
}

function splitUnescapedVerdictAlts(inner) {
  // Split only on `|` that survived BRE normalization (executable
  // alternation). Leftover `\|` / `\\|` runs are not grouping alts.
  const parts = [];
  let start = 0;
  let slashes = 0;
  const src = String(inner || "");
  for (let k = 0; k < src.length; k += 1) {
    const c = src[k];
    if (c === "\\") {
      slashes += 1;
      continue;
    }
    if (c === "|" && slashes === 0) {
      parts.push(src.slice(start, k));
      start = k + 1;
    }
    slashes = 0;
  }
  parts.push(src.slice(start));
  return parts;
}

function collectMatcherClusterTokens(slice, tokens, dialect, ignoreCase) {
  // VERDICT: then JS `\s*` or POSIX `[[:space:]]*`, then a shell-slice
  // matcher cluster of balanced groups (and ungrouped |TOKEN siblings).
  // A slice spans physical lines only while a shell quote remains open;
  // a closed-quote dangling `(` cannot swallow a later PASS matcher.
  // Double-quoted group-run-3 / alternation-run-1 leaves leftover `\(`
  // while normalizing `|`; skip those leftover escapes so the executable
  // top-level PASS alternative is visible. Alternatives keep POSIX
  // classes and quantifiers so `PASS[[:space:]]*` / `P\?PASS` still
  // tokenize as PASS rather than PASSSPACE / PPASS. ignoreCase flows
  // from grep `-i` into literal and bracket/POSIX-class matching.
  // Not a general regex parser.
  const mode = dialect || "bre";
  const fold = Boolean(ignoreCase);
  const prefixRe = /VERDICT:(?:\\s\*|\[\[:space:\]\]\*|\s*)/gi;
  let p;
  while ((p = prefixRe.exec(slice)) !== null) {
    let i = p.index + p[0].length;
    let k = i;
    while (slice[k] === "\\") k += 1;
    if (k > i && slice[k] === "(") i = k;
    if (slice[i] !== "(") continue;
    while (i < slice.length) {
      if (slice[i] === "(") {
        const close = slice.indexOf(")", i + 1);
        if (close === -1) break;
        const inner = slice.slice(i + 1, close);
        for (const part of splitUnescapedVerdictAlts(inner)) {
          addVerdictToken(tokens, part, mode, fold);
        }
        i = close + 1;
      } else if (/[A-Za-z]/.test(slice[i] || "")) {
        let j = i;
        while (j < slice.length && /[A-Za-z0-9_]/.test(slice[j])) j += 1;
        addVerdictToken(tokens, slice.slice(i, j), mode, fold);
        i = j;
      } else {
        break;
      }
      if (slice[i] === "|") {
        i += 1;
        continue;
      }
      break;
    }
    prefixRe.lastIndex = Math.max(prefixRe.lastIndex, i);
  }
}

function stageHasVerdictMatcherShape(text) {
  return /VERDICT:(?:\\s\*|\[\[:space:\]\]\*|\s*)/i.test(String(text || ""));
}

function harnessVerdictRegexGroupTokens(text) {
  const tokens = new Set();
  // Normalize only executable BRE grouping/alternation in each pipeline
  // stage, then parse every sibling group in the same matcher cluster.
  // Physical lines join only while a shell quote is open, covering legal
  // multiline quoted grep patterns without restoring unconstrained
  // cross-line groups. Command-list `;` / `&&` / `||` split first, then
  // every unquoted `|` splits pipeline stages. Each stage is reduced to
  // one normalized executable-command representation (wrappers,
  // leading redirections, dialect, ignore-case). Introspection-only
  // `command -v/-V` stages are skipped. Unsupported executable VERDICT
  // regex dialects fail closed. Residual #263/#264: not a general
  // shell/regex parser. Residual #265: pathological scan cost.
  for (const shellSlice of shellMatcherSlices(text)) {
    for (const segment of shellCommandListSegments(shellSlice)) {
      const stages = shellPipelineStages(segment);
      const norms = stages.map((stage) => normalizeExecutableStage(stage));
      // Shell-syntax `|` always splits executable pipelines. Bare pattern
      // text with unquoted ERE alternation (`VERDICT:...(APPROVE|PASS)`) is
      // not an executable pipeline; when no stage is a grep/introspection
      // command, scan the whole segment so regex alternation stays intact.
      const hasExecutableCommand = norms.some(
        (norm) => norm.kind === "grep" || norm.kind === "introspection"
      );
      const units = hasExecutableCommand
        ? stages.map((stage, idx) => ({ stage, norm: norms[idx] }))
        : [{ stage: segment, norm: normalizeExecutableStage(segment) }];
      for (const { norm } of units) {
        if (norm.kind === "introspection") continue;
        if (
          norm.unresolvedWrapper ||
          (norm.kind === "grep" &&
            (norm.unsupportedExecutableMatcher || norm.patternFile))
        ) {
          // `-P` and `-f`/`--file` are unread/unsupported pattern sources.
          // An unresolved wrapper after a defensive cap is the same class:
          // fail closed rather than classifying green. Residual: non-VERDICT
          // `grep -f` in a review harness is also fail-closed.
          if (
            stageHasVerdictMatcherShape(norm.scanText) ||
            norm.patternFile ||
            norm.unresolvedWrapper
          ) {
            tokens.add("PASS");
            tokens.add("APPROVE");
            tokens.add("REQUEST_CHANGES");
          }
          continue;
        }
        if (norm.kind === "grep" && norm.dialect === "fixed") continue;
        let slice = norm.scanText;
        const dialect = norm.kind === "grep" ? norm.dialect : "bre";
        const ignoreCase = norm.kind === "grep" ? norm.ignoreCase : false;
        if (dialect === "bre") {
          const quoteStates = shellSliceQuoteStates(slice);
          slice = slice.replace(
            /(\\*)([()|])/g,
            (match, slashes, delim, offset) =>
              executableBreDelimRun(
                slashes.length,
                quoteStates[offset] || "none"
              )
                ? delim
                : match
          );
        }
        collectMatcherClusterTokens(slice, tokens, dialect, ignoreCase);
      }
    }
  }
  return tokens;
}

function harnessAcceptsPass(text) {
  // Regex-group PASS acceptance always goes through the normalized
  // executable-command representation (introspection-only `command -v/-V`
  // stages are skipped there). Prose/echo acceptors scan non-introspection
  // stages only so pattern text inside `command -v grep '...PASS...'`
  // cannot false-red a harness that never executes the matcher.
  if (harnessVerdictRegexGroupTokens(text).has("PASS")) return true;
  for (const shellSlice of shellMatcherSlices(text)) {
    for (const segment of shellCommandListSegments(shellSlice)) {
      for (const stage of shellPipelineStages(segment)) {
        const norm = normalizeExecutableStage(stage);
        if (norm.kind === "introspection") continue;
        const t = norm.scanText;
        if (/VERDICT:\\s\*\(PASS/.test(t)) return true;
        if (/VERDICT:\[\[:space:\]\]\*PASS/i.test(t)) return true;
        if (/VERDICT:\s*PASS\b/i.test(t)) return true;
        if (/\bVERDICT: PASS\b/.test(t)) return true;
        if (/\bVERDICT\b/.test(t) && /\bAPPROVE\|PASS\b/.test(t)) return true;
      }
    }
  }
  return false;
}

/**
 * Document and merge-harness reviewer verdicts must agree. Missing harness
 * files fail closed (cannot determine authority). A VERDICT regex group
 * that lists PASS as an alternative (including ERE
 * `[[:space:]]*(APPROVE|PASS|REQUEST_CHANGES)` and BRE
 * `[[:space:]]*\(APPROVE\|PASS\|REQUEST_CHANGES\)`, lossless quantified
 * alts `PASS[[:space:]]*` / `P\?PASS`, ERE `{m}` / `{m,}` / `{m,n}`
 * (`P{1}ASS`), the mixed double-quoted group-run-3 / alternation-run-1
 * form, and a pipeline `grep -E` stage followed by a default-BRE matcher,
 * including no-whitespace `LC_ALL=C` / `env` / `command` / `command --` /
 * `command -p --` / `command env` / `/usr/bin/env` prefixes and leading
 * redirections such as `2>/dev/null grep`) is a harness accept of PASS;
 * APPROVE/REQUEST_CHANGES without PASS stays green. `env -S` /
 * `/usr/bin/env -S` / GNU `--split-string=` splice a finite nested
 * command (unresolved split-strings fail closed). Separated `env -P DIR`
 * / `--path DIR` consume the path operand. Grep `-i` / `-y` /
 * `--ignore-case` flows into bracket/POSIX-class matching, including after
 * operand-taking options (`-m 1`, `-A 1`, `-C 1`, `--max-count 1`), after
 * `-e`/`--regexp`, and after the first bare pattern (`grep 'pat' -y`).
 * `-y` is the obsolete GNU/BSD synonym of `-i` (bundled `-yi`/`-iy`/`-yE`/
 * `-Ey` included). Wrapper depth follows the finite parsed word list; a
 * remaining recognized wrapper after a defensive cap fail-closes.
 * `-f`/`--file` fail-closes rather than inventing file contents.
 * Introspection-only `command -v/-V` is not an executable matcher.
 * Residual: nested groups and non-VERDICT alternations are not parsed.
 * Residual #263/#264: not a general shell/regex parser. Residual #265:
 * pathological scan cost.
 *
 * @param {{
 *   agentsText: string,
 *   harnessFiles: Record<string, string | null | undefined>,
 * }} input
 * @returns {Array<{ code: string, message: string }>}
 */
export function reviewVerdictVocabularyFindings(input) {
  const findings = [];
  const agentsText = input && input.agentsText != null ? String(input.agentsText) : "";
  const harnessFiles =
    input && input.harnessFiles && typeof input.harnessFiles === "object"
      ? input.harnessFiles
      : null;
  if (!agentsText.trim()) {
    findings.push({
      code: "E_VERDICT_VOCABULARY",
      message: "cannot determine reviewer verdict vocabulary: AGENTS.md is empty",
    });
    return findings;
  }
  const roleSection = extractSection(agentsText, "Your role this session") || "";
  const lensSection = extractSection(agentsText, "Review lenses (binding)") || "";
  const mergeSection = extractSection(agentsText, "Commit, PR, and merge") || "";
  const hay = `${roleSection}\n${lensSection}\n${mergeSection}`;
  const tokens = collectVerdictTokens(hay);
  if (!tokens.has(CANONICAL_REVIEW_VERDICT_POSITIVE)) {
    findings.push({
      code: "E_VERDICT_VOCABULARY",
      message: `AGENTS.md reviewer verdicts must include VERDICT: ${CANONICAL_REVIEW_VERDICT_POSITIVE}; got ${JSON.stringify([...tokens].sort())}`,
    });
  }
  if (tokens.has("PASS")) {
    findings.push({
      code: "E_VERDICT_VOCABULARY",
      message: `AGENTS.md reviewer/merge sections list VERDICT: PASS; canonical PR-review positive verdict is ${CANONICAL_REVIEW_VERDICT_POSITIVE}`,
    });
  }
  if (!tokens.has(CANONICAL_REVIEW_VERDICT_NEGATIVE)) {
    findings.push({
      code: "E_VERDICT_VOCABULARY",
      message: `AGENTS.md reviewer verdicts must include VERDICT: ${CANONICAL_REVIEW_VERDICT_NEGATIVE}; got ${JSON.stringify([...tokens].sort())}`,
    });
  }
  if (!harnessFiles) {
    findings.push({
      code: "E_VERDICT_VOCABULARY",
      message: "cannot determine review-verdict harness: harness file map is missing",
    });
    return findings;
  }
  for (const rel of CANONICAL_REVIEW_HARNESS_FILES) {
    if (!Object.prototype.hasOwnProperty.call(harnessFiles, rel)) {
      findings.push({
        code: "E_VERDICT_VOCABULARY",
        message: `${rel}: cannot determine review-verdict harness (not consulted)`,
      });
      continue;
    }
    const text = harnessFiles[rel];
    if (text == null || String(text).trim() === "") {
      findings.push({
        code: "E_VERDICT_VOCABULARY",
        message: `${rel}: cannot determine review-verdict harness (file missing or empty)`,
      });
      continue;
    }
    const acceptsApprove = harnessAcceptsApprove(text);
    const acceptsPass = harnessAcceptsPass(text);
    if (!acceptsApprove) {
      findings.push({
        code: "E_VERDICT_VOCABULARY",
        message: `${rel} does not accept VERDICT: ${CANONICAL_REVIEW_VERDICT_POSITIVE} (document/harness disagreement)`,
      });
    }
    if (acceptsPass) {
      findings.push({
        code: "E_VERDICT_VOCABULARY",
        message: `${rel} accepts VERDICT: PASS; canonical PR-review positive verdict is ${CANONICAL_REVIEW_VERDICT_POSITIVE}`,
      });
    }
  }
  return findings;
}

const OVERLAY_GATE_REMOVAL_AFTER_RE =
  /\b(G\d+)\b[\s\S]{0,160}?\b(?:removed|waived|deleted|dropped|rescinded|repealed|retired|no longer applies|does not apply|is optional|may be skipped|is not required|not required)\b/gi;
const OVERLAY_GATE_REMOVAL_BEFORE_RE =
  /\b(?:remove|waive|delete|drop|rescind|repeal|retire|skip)\b[\s\S]{0,80}?\b(G\d+)\b/gi;
const OVERLAY_AUTH_VERB_RE = /\b(approved|authorized|waived)\b/gi;
const OVERLAY_REMOVAL_ACTION_RE =
  /\b(?:removed|removing|removal|remove|waived|waiving|waiver|waive)\b/i;
const OVERLAY_AUTH_NEGATION_RE =
  /\b(?:not|never|no|nor|don't|do not|didn't|did not|cannot|can't|wasn't|weren't|isn't|aren't|neither)\b/i;
/** Any G-number, including unpublished future ids. Mixed-gate uniqueness uses this. */
const OVERLAY_GATE_ID_RE = /G\d+/;
const CLAUSE_PREDICATE_START_RE =
  /\b(?:is|are|was|were|be|been|being|may|can|must|shall|should|might|could|did|does|do|has|have|had|approved|authorized|waived|rejected|declined|permitted|allowed|prohibited|required)\b/i;
const ACTOR_COORD_RE = /(?:(?:,\s+|\s+)(?:and|or)\s+)/gi;
const OVERLAY_GATE_POLARITY_SPLIT_RE = new RegExp(
  `,\\s+(?=(?:not|nor|neither)\\s+${OVERLAY_GATE_ID_RE.source}\\b)`,
  "i"
);
const LOCAL_POLARITY_TOKEN_RE =
  /^(?:not|never|no|neither|nor|don't|doesn't|didn't|cannot|can't|couldn't|isn't|aren't|wasn't|weren't|hasn't|haven't|hadn't|won't|wouldn't|shouldn't)$/i;

function overlayRegexMatches(re, text) {
  const flags = re.flags.includes("g") ? re.flags : `${re.flags}g`;
  const clone = new RegExp(re.source, flags);
  const out = [];
  let m;
  while ((m = clone.exec(text)) !== null) {
    if (!m[0]) {
      clone.lastIndex += 1;
      continue;
    }
    out.push({ index: m.index, end: m.index + m[0].length });
  }
  return out;
}

/**
 * Split an ADR-lite ledger into labeled fields. `Rejected:` alternatives
 * are returned so callers can ignore them; they must neither authorize
 * nor veto another gate's `Decided:` unit.
 */
function splitAdrLabeledFields(entry) {
  const text = String(entry || "");
  const re = /(^|\r?\n)((?:Decided|Rejected|Revisit when))\s*:/gi;
  const hits = [];
  let m;
  while ((m = re.exec(text)) !== null) {
    hits.push({
      label: m[2],
      labelIndex: m.index + m[1].length,
      bodyIndex: m.index + m[0].length,
    });
  }
  if (!hits.length) return [{ label: "", body: text }];
  const fields = [];
  const prefix = text.slice(0, hits[0].labelIndex);
  if (collapseWs(prefix)) fields.push({ label: "", body: prefix });
  for (let i = 0; i < hits.length; i++) {
    const end = i + 1 < hits.length ? hits[i + 1].labelIndex : text.length;
    fields.push({
      label: hits[i].label,
      body: text.slice(hits[i].bodyIndex, end),
    });
  }
  return fields;
}

function splitOverlayClauses(sentence) {
  const src = collapseWs(sentence);
  if (!src) return [];
  const parts = [];
  for (const semi of src.split(/\s*;\s+/)) {
    const chunk = collapseWs(semi);
    if (!chunk) continue;
    const polar = chunk.split(OVERLAY_GATE_POLARITY_SPLIT_RE);
    for (const piece of polar) {
      const t = collapseWs(piece);
      if (t) parts.push(t);
    }
  }
  return parts;
}

function leadingActor(text) {
  const src = collapseWs(text);
  if (!src) return "";
  const m = CLAUSE_PREDICATE_START_RE.exec(src);
  if (!m || m.index === 0) return "";
  return collapseWs(src.slice(0, m.index));
}

function classifyCoordRhs(rhs) {
  const t = collapseWs(rhs);
  if (!t) return "object";
  if (/^G\d+\b/i.test(t)) return "object";
  const pred = CLAUSE_PREDICATE_START_RE.exec(t);
  if (!pred) return "object";
  return pred.index === 0 ? "ellipsis" : "clause";
}

/**
 * Split coordinated subject/action clauses. Object coordination
 * (`G17 and G12`) stays one unit. A verb-phrase remainder keeps the
 * left-hand actor so polarity of "did not oppose … and approved …"
 * is local to each predicate. A new noun-phrase subject starts its
 * own clause (`owner rejected … and counsel approved …`).
 */
function splitCoordinatedActorClauses(text) {
  const src = collapseWs(normalizeApostrophes(text));
  if (!src) return [];
  const parts = [];
  let last = 0;
  let actor = leadingActor(src);
  const re = new RegExp(ACTOR_COORD_RE.source, "gi");
  let m;
  while ((m = re.exec(src)) !== null) {
    if (m.index < last) continue;
    const left = collapseWs(src.slice(last, m.index));
    const right = collapseWs(src.slice(m.index + m[0].length));
    if (!left || !right) continue;
    const kind = classifyCoordRhs(right);
    if (kind === "object") continue;
    parts.push(left);
    last = m.index + m[0].length;
    if (kind === "clause") {
      actor = leadingActor(right) || actor;
    }
  }
  let tail = collapseWs(src.slice(last));
  if (tail) {
    if (parts.length && classifyCoordRhs(tail) === "ellipsis" && actor) {
      tail = collapseWs(`${actor} ${tail}`);
    }
    parts.push(tail);
  }
  return parts.length ? parts : [src];
}

const OWNER_REPORTING_VERB_RE =
  /\b(?:reported|said|stated|noted|claimed|wrote|announced|relayed|conveyed|informed(?:\s+\w+)?\s+that)\b/i;
const OWNER_POSSESSIVE_OTHER_RE =
  /\bowner(?:'s|’s)\s+(?:counsel|delegate|attorney|agent|representative|proxy|lawyer|advisor|adviser)\b/i;

/**
 * Narrow canonical owner-authorization actor. Owner must be the
 * affirmative approving actor of this verb — not a reporter, possessor,
 * notified party, counsel/delegate, or prepositional object. Prefer a
 * fail-closed subject form over broad NLP guessing. Residual: not
 * general NLP.
 *
 * @returns {{ actor: string, polarity: 'affirmative' | 'rejected' } | null}
 */
function ownerAuthorizationActor(text, verbIndex) {
  const before = collapseWs(String(text || "").slice(0, verbIndex));
  if (!before) return null;
  const parts = before.split(
    /\b(?:after|before|when|while|because|since|although|though|if)\b/i
  );
  let local = collapseWs(parts[parts.length - 1] || "");
  if (!local) return null;
  local = collapseWs(
    local.replace(
      /\b(?:for|to|of|with|from|about|under|by)\s+(?:the\s+)?owner\b/gi,
      " "
    )
  );
  if (!local) return null;
  // Possessive other: "The owner's counsel/delegate approved …"
  if (OWNER_POSSESSIVE_OTHER_RE.test(local)) return null;
  // Reporter: "The owner reported counsel approved …"
  if (OWNER_REPORTING_VERB_RE.test(local)) return null;
  // Passive / notified owner is not the approving actor.
  if (
    /\bowner\b/i.test(local) &&
    /\b(?:was|were|is|are|been)\s+(?:notified|informed|told|advised)\b/i.test(
      local
    )
  ) {
    return null;
  }
  const actor = leadingActor(`${local} approved`);
  const subject = collapseWs(actor || local);
  if (!subject) return null;
  if (OWNER_POSSESSIVE_OTHER_RE.test(subject)) return null;
  const canonical = collapseWs(
    subject
      .replace(/\b(?:explicitly|hereby|formally|also|then)\b/gi, " ")
      .replace(/[^\w\s']/g, " ")
  );
  if (!/^(?:the\s+)?owner$/i.test(canonical)) return null;
  return { actor: "owner", polarity: "affirmative" };
}

/**
 * Owner must be the grammatical actor of this approval/waiver verb, not
 * merely mentioned (`for the owner`), a possessor (`owner's counsel`),
 * a reporter (`owner reported counsel approved`), or notified
 * (`the owner was notified after counsel approved`). Intervening
 * `after`/`before`/… clauses keep their own actor. Residual: not
 * general NLP.
 */
function ownerIsVerbActor(text, verbIndex) {
  return ownerAuthorizationActor(text, verbIndex) != null;
}

function verbInRelativeClause(text, verbIndex) {
  const before = collapseWs(String(text || "").slice(0, verbIndex));
  if (!before) return false;
  if (/\b(?:that|which|who)\s*$/i.test(before)) return true;
  const m = before.match(/\b(?:that|which|who)\s+(.+)$/i);
  if (!m) return false;
  const relSubject = collapseWs(m[1]);
  if (!relSubject) return true;
  // Finite relative with an intervening subject (`that counsel approved`).
  // An owner relative subject can still be the authorizing actor; any other
  // subject cannot. Residual: not general NLP — whose/whom, nested
  // complementizers, and passive by-phrases as the only owner mention
  // are not modeled.
  if (/\bowner\b/i.test(relSubject)) return false;
  return relSubject.split(/\s+/).length <= 6;
}

/**
 * Same-sentence / `Decided:` units that may authorize a named-gate
 * removal. Sibling `Rejected:` fields are omitted so they cannot
 * authorize or poison another gate. Adversative, contrastive, and
 * coordinated subject/action clauses stay independent so "approved
 * G11, not G12" cannot authorize G12, while "did not approve G11, but
 * approved G12" can, and "did not oppose … and approved G12" binds
 * approval to the owner remainder. After those splits, a unit that
 * still names more than one G-number cannot authorize any of them.
 */
/**
 * True when `left` ends with a completed removal/waiver-action object
 * (`removal of G12`, `waiver of the G12 gate`) with nothing but filler
 * after the gate id — the same shape `overlayGateIsRemovalObject` binds.
 * Used to keep an immediately following adversative connector
 * (`, but only from documentation`, `, but that was explicitly
 * rejected`) attached to that object instead of letting generic
 * adversative sentence-splitting discard it and authorize from the
 * truncated left half alone. Gate mentions that are not the object of a
 * removal action (`did not approve G11`) are unaffected, so a genuine
 * "did not approve G11, but approved G12" split is untouched.
 */
function overlayAdversativeBoundaryIsPostRemovalTarget(left, rightRemainder) {
  const t = collapseWs(left);
  if (!t) return false;
  const gates = overlayRegexMatches(new RegExp(OVERLAY_GATE_ID_RE.source, "gi"), t);
  if (!gates.length) return false;
  const lastGate = gates[gates.length - 1];
  if (!overlayRemovalTargetSkipOnly(t.slice(lastGate.end))) return false;
  const actions = overlayRegexMatches(OVERLAY_REMOVAL_ACTION_RE, t);
  let boundToRemoval = false;
  for (let i = actions.length - 1; i >= 0; i -= 1) {
    const action = actions[i];
    if (action.end > lastGate.index) continue;
    if (overlayRemovalTargetSkipOnly(t.slice(action.end, lastGate.index))) {
      boundToRemoval = true;
      break;
    }
  }
  if (!boundToRemoval) return false;
  // Binding is target-local: a *different* gate id on the far side of the
  // connector (`did not approve removal of G11, but approved removal of
  // G12`) is an independent clause about a different gate, not a
  // restriction/rejection of this one — do not let a denial for one gate
  // suppress the split that frees a separately affirmative approval for
  // another. Only merge when nothing but this same gate id (or no gate
  // id at all) appears past the connector.
  const targetId = t.slice(lastGate.index, lastGate.end).toUpperCase();
  const rightGates = overlayNamedGateIds(String(rightRemainder || ""));
  if (rightGates.some((id) => id !== targetId)) return false;
  return true;
}

/**
 * The bare-whitespace `yet` boundary in `CLAUSE_BOUNDARY_RE` is meant for
 * contrastive "X yet Y"; it also matches the hedge "not yet"/"never yet"
 * (`was not yet authorized`), which is not a clause boundary at all.
 */
function overlayBoundaryIsNotYetIdiom(left, matchedText) {
  return /\byet\b/i.test(matchedText) && /\b(?:not|never)\s*$/i.test(left);
}

/**
 * The explicitly named owner subject a following coordinated predicate
 * may inherit. Only the canonical bare `the owner` subject is
 * inheritable: any other leading actor (counsel, a delegate, a reporter,
 * an unnamed subject) must never become an owner approval in the second
 * clause, so anything else yields no inheritable actor at all.
 */
function overlayInheritableOwnerActor(clause) {
  const actor = leadingActor(clause);
  if (!actor) return "";
  const canonical = collapseWs(actor.replace(/[^\w\s']/g, " "));
  return /^(?:the\s+)?owner$/i.test(canonical) ? "the owner" : "";
}

/**
 * Re-attach an inherited owner subject to a split clause that has no
 * subject of its own (`…, but approved removal of G12`). Only a bare
 * predicate remainder inherits: a clause that already names an actor —
 * owner or otherwise — keeps it, and an object remainder (`, but not
 * G12`) is not a predicate at all. Polarity is not inherited, so a
 * denial for one gate cannot travel to the other clause; only the
 * subject does.
 */
function overlayWithInheritedActor(part, actor) {
  if (!actor || !part) return part;
  if (/\bowner\b/i.test(part)) return part;
  if (classifyCoordRhs(part) !== "ellipsis") return part;
  return collapseWs(`${actor} ${part}`);
}

/**
 * Same boundaries as `splitAdversativeClauses`, but a boundary
 * immediately following a completed removal-target object is not split
 * — the restriction/rejection after the connector stays bound to that
 * object for `overlayGateIsRemovalObject` to see — and a `not yet` /
 * `never yet` hedge is not treated as a boundary at all. Where a
 * boundary does split, a subjectless second predicate inherits an
 * explicit owner subject from the clause before it.
 */
function splitOverlayAdversativeClauses(text) {
  const src = collapseWs(text);
  if (!src) return [];
  const parts = [];
  let last = 0;
  let actor = "";
  const push = (part) => {
    if (!part) return;
    parts.push(parts.length ? overlayWithInheritedActor(part, actor) : part);
    actor = overlayInheritableOwnerActor(part) || actor;
  };
  const re = new RegExp(CLAUSE_BOUNDARY_RE.source, "gi");
  let m;
  while ((m = re.exec(src)) !== null) {
    if (m.index < last) continue;
    const left = collapseWs(src.slice(last, m.index));
    const rightRemainder = src.slice(m.index + m[0].length);
    if (
      overlayAdversativeBoundaryIsPostRemovalTarget(left, rightRemainder) ||
      overlayBoundaryIsNotYetIdiom(left, m[0])
    ) {
      continue;
    }
    push(left);
    last = m.index + m[0].length;
    if (last === m.index) last = m.index + 1;
  }
  const tail = collapseWs(
    src.slice(last).replace(
      /^(?:however|nevertheless|nonetheless|although|though|whereas|but|yet)\b[,:\s]*/i,
      ""
    )
  );
  push(tail);
  return parts.length ? parts : [src];
}

/**
 * Semicolon/gate-polarity splitting for overlay authorization units. A
 * `;` that directly follows a completed gate-removal target keeps its
 * continuation attached (`removal of G12; only its label may be
 * deleted`), so `overlayGateIsRemovalObject` judges that continuation
 * instead of the truncated left half authorizing on its own. A
 * semicolon after anything else (`removal of another object; the minutes
 * mention G12`) still splits, and `, not G12` polarity splitting is
 * unchanged.
 */
function splitOverlayAuthorizationClauses(sentence) {
  const src = collapseWs(sentence);
  if (!src) return [];
  const chunks = [];
  const re = /\s*;\s+/g;
  let last = 0;
  let m;
  while ((m = re.exec(src)) !== null) {
    if (m.index < last) continue;
    const left = collapseWs(src.slice(last, m.index));
    const rightRemainder = src.slice(m.index + m[0].length);
    if (overlayAdversativeBoundaryIsPostRemovalTarget(left, rightRemainder)) {
      continue;
    }
    if (left) chunks.push(left);
    last = m.index + m[0].length;
  }
  const tail = collapseWs(src.slice(last));
  if (tail) chunks.push(tail);
  const parts = [];
  for (const chunk of chunks.length ? chunks : [src]) {
    for (const piece of chunk.split(OVERLAY_GATE_POLARITY_SPLIT_RE)) {
      const t = collapseWs(piece);
      if (t) parts.push(t);
    }
  }
  return parts;
}

function overlayAuthorizationUnits(decisionsText) {
  const src = String(decisionsText || "");
  if (!src.trim()) return [];
  const units = [];
  for (const chunk of src.split(/^##\s+/m)) {
    if (!collapseWs(chunk)) continue;
    for (const field of splitAdrLabeledFields(chunk)) {
      if (/^rejected$/i.test(field.label)) continue;
      for (const sent of polarityUnits(field.body)) {
        for (const adv of splitOverlayAdversativeClauses(sent)) {
          for (const clause of splitOverlayAuthorizationClauses(adv)) {
            for (const actorPart of splitCoordinatedActorClauses(clause)) {
              units.push(actorPart);
            }
          }
        }
      }
    }
  }
  return units;
}

function overlayAuthVerbNegated(before) {
  const tail = collapseWs(before).split(/\s+/).slice(-10).join(" ");
  return OVERLAY_AUTH_NEGATION_RE.test(tail);
}

function overlayComplementSkipOnly(text) {
  const t = collapseWs(text);
  if (!t) return true;
  return t.split(/\s+/).every((tok) =>
    /^(?:the|a|an|its|this|that|explicitly|hereby|formally|also|then)$/i.test(tok)
  );
}

const OVERLAY_REMOVAL_TARGET_SKIP_RE =
  /^(?:the|a|an|its|this|that|of|for|to|named|human|gate|explicitly|hereby|formally|also|then)$/i;
/** Clause continuations after a complete gate-removal target. */
const OVERLAY_GATE_OBJECT_FOLLOW_RE =
  /^(?:and|or|but|nor|because|since|so|therefore|thus|rather|than|while|when|if|unless|although|though|after|before|versus|vs|then|hereby|explicitly|formally|also|still|now|today|was|were|is|are|be|been|being|remains?|stays?|continues?|applies|does|did|cannot|must|may|shall|should|will|would)$/i;
/**
 * Prepositions that attach a collateral/narrowed object after the gate
 * id (`G12 from documentation`, `G12 in the example`, `G12 as a label`).
 * These are not removal of the human gate itself.
 */
const OVERLAY_GATE_COLLATERAL_PREP_RE =
  /^(?:from|in|into|on|onto|at|by|with|without|via|per|as|for|of|about|regarding|concerning|among|across|within|toward|towards)$/i;
/**
 * Copulas that can carry a post-target predicate about the removal. The
 * statives `remains` / `stays` / `continues` belong here with `was` /
 * `is`: `removal of G12 remains pending` reports the same non-final
 * state as `removal of G12 is pending`, so it must reach the rejection
 * test below instead of passing as an ordinary object continuation.
 */
const OVERLAY_GATE_COPULA_RE =
  /^(?:was|were|is|are|be|been|being|remains?|stays?|continues?)$/i;
/** `continues to be pending` — infinitival copula after a stative. */
const OVERLAY_GATE_STATIVE_TO_BE_RE = /^to\s+be\s+/i;
/** Adverbs that may sit between the copula and the rejection predicate. */
const OVERLAY_REJECTION_MODIFIER_SRC =
  "(?:explicitly|expressly|hereby|formally|duly|also|then|later|subsequently|since|already|still|now)\\s+";
/**
 * Copular complements that report the removal as not (or no longer) in
 * force: an outright rejection (`was denied`, `was expressly denied`), a
 * non-final state (`is pending`, `remains pending`), or a negated /
 * lapsed authorization (`was not yet authorized`, `was no longer
 * authorized`).
 */
const OVERLAY_REMOVAL_COPULAR_REJECTION_RE = new RegExp(
  "^(?:" +
    OVERLAY_REJECTION_MODIFIER_SRC +
    ")*(?:rejected|denied|declined|refused|revoked|retracted|withdrawn|reversed|overturned|unauthorized|unapproved|pending" +
    "|(?:not|never|no\\s+longer)\\s+(?:yet\\s+)?(?:authorized|approved|permitted|allowed|in\\s+effect))\\b",
  "i"
);
/**
 * Adversative connectors. Directly after a just-named removal target one
 * of these introduces a restriction, a rejection, or something this
 * sensor cannot resolve — never a benign continuation.
 */
const OVERLAY_ADVERSATIVE_CONNECTOR_RE =
  /^(?:but|however|nevertheless|nonetheless|although|though|whereas|yet|still)$/i;

/**
 * A contrastive connector directly after a completed removal target
 * never leaves that removal authorized. Some continuations narrow it
 * (`, but only from documentation`, `, but from documentation only`,
 * `, but not as a human gate`), some retract it (`, but that was
 * explicitly rejected`, `, but the owner rejected it`, `, but later
 * denied that removal`, `, but that remains denied`), and the rest are
 * language this sensor does not model.
 *
 * `overlayAdversativeBoundaryIsPostRemovalTarget` deliberately keeps
 * such a continuation bound to the target instead of splitting it away,
 * so this is the point where it has to be judged: an unresolved
 * continuation must fail closed, because the alternative is authorizing
 * from the truncated left half alone. Residual: not general NLP — a
 * genuinely benign contrastive continuation is treated as unresolved
 * and does not authorize.
 */
function overlayAdversativeContinuationBlocksRemoval(next) {
  return OVERLAY_ADVERSATIVE_CONNECTOR_RE.test(next);
}

function overlayRemovalTargetSkipOnly(text) {
  const t = collapseWs(text);
  if (!t) return true;
  return t.split(/\s+/).every((tok) => {
    const n = tok.replace(/[^A-Za-z]/g, "");
    if (!n) return true;
    return OVERLAY_REMOVAL_TARGET_SKIP_RE.test(n);
  });
}

/**
 * The named gate must be the complete object of this removal/waiver act
 * (`removal of G12`, `removal of the G12 gate`, `removal of gate G12`),
 * not a later mention, a pre-modifier / collateral target
 * (`references to G12`, `the G12 example`, `G12 from documentation`,
 * `G12 in the example`, `G12 as a label`), or a post-target copular
 * rejection/negation of that removal (`was rejected`, `was not
 * authorized`, `was denied`, `was declined`). Residual: not general NLP.
 */
function overlayCopularComplementRejectsRemoval(after, copula) {
  if (!OVERLAY_GATE_COPULA_RE.test(copula)) return false;
  const rest = collapseWs(after.replace(/^[A-Za-z']+\b/, "")).replace(
    /^[.,:;!?()[\]"'`]+/,
    ""
  );
  const predicate = collapseWs(
    rest.replace(OVERLAY_GATE_STATIVE_TO_BE_RE, "")
  );
  return OVERLAY_REMOVAL_COPULAR_REJECTION_RE.test(predicate);
}

function overlayGateIsRemovalObject(text, action, gate) {
  if (!action || !gate) return false;
  if (gate.index < action.end) return false;
  if (!overlayRemovalTargetSkipOnly(text.slice(action.end, gate.index))) {
    return false;
  }
  const afterRaw = String(text || "").slice(gate.end);
  // Strip leading punctuation, then re-collapse: stripping a comma out of
  // an already-collapsed ", but …" leaves a bare leading space, which
  // would otherwise split() into a phantom empty first token below.
  let after = collapseWs(
    collapseWs(afterRaw).replace(/^[.,:;!?()[\]"'`]+/, "")
  );
  if (!after) return true;
  // Complete the target noun: optional trailing "gate" / "human gate".
  const trailer = /^(?:human\s+)?gates?\b/i.exec(after);
  if (trailer) {
    after = collapseWs(
      collapseWs(after.slice(trailer[0].length)).replace(
        /^[.,:;!?()[\]"'`]+/,
        ""
      )
    );
    if (!after) return true;
  }
  const next = (after.split(/\s+/)[0] || "").replace(/[^A-Za-z']/g, "");
  if (!next) return true;
  if (OVERLAY_GATE_COLLATERAL_PREP_RE.test(next)) return false;
  if (overlayCopularComplementRejectsRemoval(after, next)) return false;
  if (overlayAdversativeContinuationBlocksRemoval(next)) return false;
  return OVERLAY_GATE_OBJECT_FOLLOW_RE.test(next);
}

function localPolarityTokens(before) {
  return collapseWs(before)
    .split(/\s+/)
    .filter(Boolean)
    .slice(-4)
    .map((tok) => tok.replace(/[^A-Za-z']/g, ""));
}

function namedGatePolarityDenied(text, gateIndex, gateId) {
  const tail = localPolarityTokens(text.slice(0, gateIndex));
  if (tail.some((tok) => LOCAL_POLARITY_TOKEN_RE.test(tok))) return true;
  const id = escapeRe(gateId);
  return new RegExp(`\\bneither\\b[\\s\\S]{0,80}\\b${id}\\b`, "i").test(text);
}

function spanHasAuthNegation(text, from, to) {
  if (from > to) {
    const tmp = from;
    from = to;
    to = tmp;
  }
  if (from >= to) return false;
  return OVERLAY_AUTH_NEGATION_RE.test(text.slice(from, to));
}

function overlayNamedGateIds(text) {
  return overlayRegexMatches(
    new RegExp(`\\b${OVERLAY_GATE_ID_RE.source}\\b`, "gi"),
    text
  ).map((span) => text.slice(span.index, span.end).toUpperCase());
}

/**
 * Same-clause owner authorization requires an un-negated approval verb
 * whose actor is the owner, an un-negated remove/waive act as that
 * verb's own complement, and an un-negated named gate bound as that
 * act's object — not a later mention, a modifier of another noun
 * (`the G12 example`), or a different object (`references to G12`,
 * `obsolete documentation about G12`, `another object; the minutes
 * mention G12`). Retain / reject / discuss / record / delegate /
 * authorize-someone-else-to-decide are not the removal act even when
 * the words co-occur. Owner must approve the gate-removal clause, not
 * merely be mentioned or notified. Relative-clause verbs (`decision
 * that waived G12`, `decision that counsel approved removal of G12`)
 * are not the clause's decision. A unit may authorize the target only
 * when it names no other G-number; independently split units still
 * authorize when they carry their own owner approval and
 * removal/waiver. `not G12` / `neither … G12` deny G12 even when a
 * sibling gate is approved in the same sentence. Residual: this is
 * not general NLP.
 */
function clauseAuthorizesGateRemoval(clause, gateId) {
  const t = collapseWs(clause);
  const id = String(gateId || "");
  if (!t || !id) return false;
  if (!/\bowner\b/i.test(t)) return false;
  const gates = overlayRegexMatches(new RegExp(`\\b${escapeRe(id)}\\b`, "gi"), t);
  if (!gates.length) return false;
  const target = id.toUpperCase();
  if (overlayNamedGateIds(t).some((named) => named !== target)) return false;
  const verbs = overlayRegexMatches(OVERLAY_AUTH_VERB_RE, t);
  const actions = overlayRegexMatches(OVERLAY_REMOVAL_ACTION_RE, t);
  if (!verbs.length || !actions.length) return false;
  for (const verb of verbs) {
    if (verbInRelativeClause(t, verb.index)) continue;
    if (overlayAuthVerbNegated(t.slice(0, verb.index))) continue;
    if (!ownerIsVerbActor(t, verb.index)) continue;
    for (const action of actions) {
      if (action.index !== verb.index) {
        if (action.index < verb.end) continue;
        if (!overlayComplementSkipOnly(t.slice(verb.end, action.index))) continue;
      }
      if (
        action.index !== verb.index &&
        spanHasAuthNegation(
          t,
          Math.min(verb.end, action.end),
          Math.max(verb.index, action.index)
        )
      ) {
        continue;
      }
      const pairLo = Math.min(verb.index, action.index);
      const pairHi = Math.max(verb.end, action.end);
      for (const gate of gates) {
        if (namedGatePolarityDenied(t, gate.index, id)) continue;
        if (!overlayGateIsRemovalObject(t, action, gate)) continue;
        const betweenLo = gate.index >= pairHi ? pairHi : gate.end;
        const betweenHi = gate.index >= pairHi ? gate.index : pairLo;
        if (spanHasAuthNegation(t, betweenLo, betweenHi)) continue;
        return true;
      }
    }
  }
  return false;
}

function overlayRemovalAuthorized(decisionsText, gateId) {
  const id = String(gateId || "");
  if (!id) return false;
  for (const unit of overlayAuthorizationUnits(decisionsText)) {
    if (clauseAuthorizesGateRemoval(unit, id)) return true;
  }
  return false;
}

/**
 * Enforce AGENTS.md overlay limits on local/AGENTS.local.md: Ask Contract
 * may not be weakened, and G1–G16 may be extended but not removed unless
 * memory/DECISIONS.md records an un-negated same-gate owner authorization
 * (`Decided:` / same-sentence). Empty overlay or missing expected gate ids
 * fail closed. Sibling `Rejected:` fields do not authorize.
 *
 * @param {string} overlayText
 * @param {string | null | undefined} decisionsText
 * @param {string[]} expectedGateIds
 * @returns {Array<{ code: string, message: string }>}
 */
export function overlayLimitFindings(overlayText, decisionsText, expectedGateIds) {
  const findings = [];
  const text = overlayText == null ? "" : String(overlayText);
  if (!text.trim()) {
    findings.push({
      code: "E_OVERLAY",
      message:
        "local/AGENTS.local.md is present but empty; cannot determine overlay limits",
    });
    return findings;
  }
  if (!Array.isArray(expectedGateIds) || expectedGateIds.length === 0) {
    findings.push({
      code: "E_OVERLAY",
      message:
        "cannot determine human-gate list to enforce overlay limits (fail closed)",
    });
    return findings;
  }

  const hay = authorityClaimHaystack(text);
  if (/\bAsk Contract\b/i.test(hay)) {
    if (obligationNegated(hay, "Ask Contract") || clauseWeakensBinding(hay, "Ask Contract")) {
      findings.push({
        code: "E_OVERLAY",
        message: "local/AGENTS.local.md weakens the Ask Contract",
      });
    }
  }
  for (const field of EXPECTED_ASK_FIELDS) {
    if (!hay.includes(field)) continue;
    if (obligationNegated(hay, field) || clauseWeakensBinding(hay, field)) {
      findings.push({
        code: "E_OVERLAY",
        message: `local/AGENTS.local.md weakens Ask Contract field "${field}"`,
      });
    }
  }

  const entries = parseHumanGateEntries(text);
  if (entries.length) {
    const got = new Set(entries.map((e) => e.id));
    for (const id of expectedGateIds) {
      if (got.has(id)) continue;
      if (overlayRemovalAuthorized(decisionsText, id)) continue;
      findings.push({
        code: "E_OVERLAY",
        message: `local/AGENTS.local.md removes human gate ${id} without an affirmative same-gate owner authorization in memory/DECISIONS.md`,
      });
    }
  }

  const seen = new Set();
  for (const re of [OVERLAY_GATE_REMOVAL_AFTER_RE, OVERLAY_GATE_REMOVAL_BEFORE_RE]) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(hay)) !== null) {
      const id = m[1];
      if (!expectedGateIds.includes(id) || seen.has(id)) continue;
      seen.add(id);
      if (overlayRemovalAuthorized(decisionsText, id)) continue;
      findings.push({
        code: "E_OVERLAY",
        message: `local/AGENTS.local.md removes or waives human gate ${id} without an affirmative same-gate owner authorization in memory/DECISIONS.md`,
      });
    }
  }
  return findings;
}

function isUnqualifiedMergeForbidden(item) {
  const tokens = contentTokens(normalizeObligation(item));
  return tokens.length === 1 && /^merg/.test(tokens[0] || "");
}

function requiresGreenGate(item) {
  return /\bgreen gate\b/.test(normalizeObligation(item));
}

function isSelfReviewObligation(item) {
  const n = normalizeObligation(item);
  if (!n) return false;
  if (/\bself[\s-]?review\b/.test(n)) return true;
  if (/\bsame[\s-]?agent\b/.test(n)) return true;
  if (!/\b(?:own|self)\b/.test(n)) return false;
  if (/\bgenerat/.test(n)) return true;
  if (/\bwork\b/.test(n)) return true;
  if (/\breview/.test(n)) return true;
  return false;
}

const BODY_GRANT_MERGE_RE =
  /\b(?:may|can|allowed to|permitted to)\s+merge\b/i;
const BODY_SKIP_GREEN_RE =
  /\bgreen gate\b[\s\S]{0,80}\b(?:may be skipped|can be skipped|is optional|is waived|need not run)\b/i;
const BODY_SKIP_GREEN_RE2 =
  /\b(?:may|can)\s+skip\b[\s\S]{0,60}\bgreen gate\b/i;
/** Bounded adjective slot before permission/right/authority (`explicit permission`, `full authority`). */
const PERMISSION_NOUN_ADJ_SRC = "(?:explicit|express|full|written|formal)\\s+";
const PERMISSION_PRED_RE = new RegExp(
  "\\b(?:" +
    "(?:is|are)\\s+(?:permitted|allowed|authorized)" +
    "|(?:is|are)\\s+(?:(?:expressly|explicitly|formally)\\s+)?required\\s+to" +
    "|(?:allowed|permitted|authorized)\\s+to" +
    "|(?:has|have|had)\\s+(?:the\\s+)?(?:" +
    PERMISSION_NOUN_ADJ_SRC +
    ")?(?:permission|right|authority)\\s+to" +
    "|(?:has|have|had|was|were|is|are)\\s+(?:been\\s+)?(?:granted|given)\\s+(?:the\\s+)?(?:" +
    PERMISSION_NOUN_ADJ_SRC +
    ")?(?:permission|right|authority)\\s+to" +
    "|must|shall|may|can|permitted|allowed|authorized" +
    ")\\b",
  "gi"
);
const OWN_WORK_TOPIC_RE =
  /\b(?:(?:its|their|your|our|my)\s+own(?:\s+(?:work|generation))?|own\s+work|review of\s+(?:its|their|your|our|my)\s+own)\b/i;
const REVIEW_ACT_RE = /\b(?:review|evaluate|evaluating|grade|grading)\b/i;

function grantPolarityUnits(hay) {
  const out = [];
  for (const unit of polarityUnits(hay)) {
    for (const adv of splitAdversativeClauses(unit)) {
      for (const actorPart of splitCoordinatedActorClauses(adv)) {
        for (const part of splitOverlayClauses(actorPart)) {
          if (part) out.push(part);
        }
      }
    }
  }
  return out;
}

/**
 * The whitespace-delimited tokens immediately before `index`, truncated
 * at the nearest `NEW_SUBJECT_BOUNDARY_RE` separator — equivalent to
 * `text.slice(0, index).split(NEW_SUBJECT_BOUNDARY_RE).pop()` tokenized
 * by `/\s+/`, but found by scanning backward from `index` a bounded
 * number of tokens (`maxTokens`) instead of slicing/splitting the whole
 * `0..index` prefix. Cost is proportional to the width of the returned
 * tokens and the small gaps checked between them, not to `index`, so a
 * caller filtering many occurrences across a long text stays linear
 * rather than quadratic. This is a token-count bound, not an arbitrary
 * byte window: a single token may be any length and is still returned
 * whole (contractions like "doesn't" included, unstripped — same as
 * plain `\s+` splitting). Residual: a dash/slash boundary glued directly
 * onto a word with no surrounding whitespace is not distinguished from
 * an ordinary token character (not general NLP).
 */
function boundedLocalTailTokens(text, index, maxTokens) {
  const s = String(text || "");
  const tokens = [];
  let i = Math.max(0, Math.min(index, s.length));
  while (tokens.length < maxTokens && i > 0) {
    const beforeGap = i;
    while (i > 0 && /\s/.test(s[i - 1])) i -= 1;
    const hadGap = i < beforeGap;
    if (i === 0) break;
    // `[,;:]\s+` — punctuation immediately followed by whitespace.
    if (hadGap && /[,;:]/.test(s[i - 1])) break;
    // `\s*\(\s*` — an opening paren, with or without preceding whitespace.
    if (s[i - 1] === "(") break;
    const tokenEnd = i;
    // Stop token collection at a bare `(` glued to the word (`(the`) too,
    // so the next iteration's paren check above can see it as a
    // boundary instead of it being swallowed into the token text.
    while (i > 0 && !/\s/.test(s[i - 1]) && s[i - 1] !== "(") i -= 1;
    const token = s.slice(i, tokenEnd);
    if (!token) break;
    // `\s+(?:or|while|plus)\s+` — the connector word is itself the
    // separator: stop without including it. Whitespace after it is
    // guaranteed by `hadGap` on the loop iteration that collected it.
    if (hadGap && /^(?:or|while|plus)$/i.test(token)) break;
    // `\s+\/\s+` and dash-run separators as their own whitespace-bounded
    // token.
    if (
      hadGap &&
      (token === "/" || /^[—–]+$/.test(token) || /^--+$/.test(token))
    ) {
      break;
    }
    tokens.unshift(token);
  }
  return tokens;
}

/** Fixed-length literal words only — bounding this scan to a small
 * constant window is exact, not approximate (unlike the backward token
 * scan above, whose tokens may be arbitrarily long). */
const NOT_NEVER_PREFIX_RE = /^(?:not|never)\b/i;

function afterSpanStartsWithNegation(text, spanEnd) {
  const s = String(text || "");
  let i = spanEnd;
  while (i < s.length && /\s/.test(s[i])) i += 1;
  return NOT_NEVER_PREFIX_RE.test(s.slice(i, i + 5));
}

function permissionPredicateNegated(text, span) {
  const tokens = boundedLocalTailTokens(text, span.index, 4).map((tok) =>
    tok.replace(/[^A-Za-z']/g, "")
  );
  if (tokens.some((tok) => LOCAL_POLARITY_TOKEN_RE.test(tok))) {
    return true;
  }
  return afterSpanStartsWithNegation(text, span.end);
}

function unnegatedPermissionSpans(text) {
  return overlayRegexMatches(PERMISSION_PRED_RE, text).filter(
    (span) => !permissionPredicateNegated(text, span)
  );
}

function clauseSubjectIsIndependent(text) {
  const actor = leadingActor(text) || String(text || "").slice(0, 80);
  return /\b(?:independent|different|another|other)\s+(?:agent|reviewer)s?\b/i.test(
    actor
  );
}

function independentReviewNotRequired(text) {
  const t = String(text || "");
  if (!/\b(?:independent|different|another|other)\s+(?:agent|reviewer)s?\b/i.test(t)) {
    return false;
  }
  // "is not required to self-review" restates the prohibition; it does
  // not authorize same-agent review.
  if (/\bself[\s-]?review\b/i.test(t)) return false;
  if (!REVIEW_ACT_RE.test(t)) return false;
  return (
    /\b(?:is|are|was|were)\s+not\s+required\b/i.test(t) ||
    /\bneed not\b/i.test(t) ||
    /\b(?:does|do|did)\s+not\s+(?:need|have)\s+to\b/i.test(t) ||
    /\bnot\s+necessary\b/i.test(t)
  );
}

/**
 * The two whitespace-delimited tokens immediately before `index`, found
 * by scanning backward a bounded distance from `index` itself — not by
 * slicing/collapsing/splitting the whole `0..index` prefix. Cost is
 * proportional to the width of those two tokens, not to `index`, so a
 * caller checking many occurrences across a long text stays linear
 * rather than quadratic.
 */
function lastTwoWordsBefore(text, index) {
  const s = String(text || "");
  let i = Math.max(0, Math.min(index, s.length));
  const words = ["", ""];
  for (let k = 0; k < 2; k += 1) {
    while (i > 0 && /\s/.test(s[i - 1])) i -= 1;
    const end = i;
    while (i > 0 && !/\s/.test(s[i - 1])) i -= 1;
    words[k] = s.slice(i, end);
  }
  return words;
}

function topicLocallyExcluded(text, index) {
  const [lastRaw, prevRaw] = lastTwoWordsBefore(text, index);
  const last = lastRaw.replace(/[^A-Za-z']/g, "");
  const prev = prevRaw.replace(/[^A-Za-z']/g, "");
  if (LOCAL_POLARITY_TOKEN_RE.test(last)) return true;
  if (/^(?:except|excluding)$/i.test(last)) return true;
  // `other than its own work` is the same local-exclusion family as except.
  // Residual: aside from / besides / apart from are not modeled.
  if (/^other$/i.test(prev) && /^than$/i.test(last)) return true;
  return false;
}

function ownWorkGrantedIn(text) {
  const re = new RegExp(OWN_WORK_TOPIC_RE.source, "gi");
  let m;
  while ((m = re.exec(text)) !== null) {
    if (!topicLocallyExcluded(text, m.index)) return true;
  }
  return false;
}

const AUTH_GRANT_VERB_SRC =
  "authoriz(?:e|es|ed|ing)|permit(?:s|ted)?|allow(?:s|ed)?|delegat(?:e|es|ed|ing)|grant(?:s|ed|ing)?|approv(?:e|es|ed|ing)|giv(?:e|es|en|ing)|provid(?:e|es|ed|ing)|lets?|letting|assign(?:s|ed|ing)?";
const AUTH_GRANT_VERB_RE = new RegExp(`\\b(?:${AUTH_GRANT_VERB_SRC})\\b`, "i");
const SELF_REVIEW_GRANT_VERB_RE = new RegExp(
  `\\b(?:${AUTH_GRANT_VERB_SRC}|may|can)\\b`,
  "i"
);
const REVIEW_NOUN_PHRASE_SRC =
  "(?:the\\s+)?review(?:\\s+to\\s+be\\s+(?:conducted|done|performed|carried\\s+out))?";
const REVIEWER_NOUN_TARGET_SRC =
  "(?:as\\s+(?:a\\s+|the\\s+)?reviewers?|to\\s+be\\s+(?:a\\s+|the\\s+)?reviewers?)";
/**
 * Non-grant predicate/topic family. Applied only to a structurally
 * identified infinitive lemma or topic noun — never to the whole
 * intervening span, so prenominal role modifiers (`report author`,
 * `documentation owner`, `record owner`, `discussion leader`) are not
 * treated as the authorized act.
 */
const SELF_REVIEW_NON_GRANT_PRED_RE =
  /\b(?:discuss(?:es|ed|ing|ion|ions)?|report(?:s|ed|ing)?|document(?:s|ed|ing|ation)?|mention(?:s|ed|ing)?|record(?:s|ed|ing)?|reject(?:s|ed|ing|ion)?|ban(?:s|ned|ning)?|prohibit(?:s|ed|ing|ion)?|den(?:y|ies|ying|ied)|refus(?:e|es|ed|ing)|forbid(?:s|ding)?|forbade|forbidden|prevent(?:s|ed|ing)?)\b/i;
const SELF_REVIEW_NON_GRANT_TOPIC_PREP_RE =
  /^(?:about|on|of|regarding|concerning)$/i;
/** Reversed-subject obligation: "Self-review is required of <reviewer>." */
const SELF_REVIEW_REQUIRED_OF_RE =
  /\bself[\s-]?review\s+(?:is|are|was|were)\s+(?!not\b)(?:(?:expressly|explicitly|formally)\s+)?required\s+of\b/i;
/**
 * Reversed permission subject: the permission is the grammatical subject
 * and the grant is its passive predicate ("Permission to self-review is
 * granted to an independent reviewer"), so the clause contains no
 * forward grant-verb-then-self-review span pair for the ordinary scan to
 * find. The copula must not be negated, and the whole subject must not
 * be locally excluded ("No permission to self-review is granted") —
 * `reversedSelfReviewPermissionGranted` checks the latter.
 */
const SELF_REVIEW_PERMISSION_SUBJECT_GRANTED_RE = new RegExp(
  "\\b(?:permission|right|authority|licence|license|leave|clearance)\\s+to\\s+self[\\s-]?review\\b" +
    "[^.!?;]{0,40}?\\b(?:is|are|was|were|has\\s+been|have\\s+been|had\\s+been)\\s+" +
    "(?!not\\b|never\\b|no\\b)(?:(?:hereby|expressly|explicitly|formally|duly|already)\\s+)*" +
    "(?:granted|given|conferred|extended|provided|allowed|permitted|authorized)\\b",
  "i"
);

function reversedSelfReviewPermissionGranted(text) {
  const re = new RegExp(SELF_REVIEW_PERMISSION_SUBJECT_GRANTED_RE.source, "gi");
  let m;
  while ((m = re.exec(text)) !== null) {
    if (!topicLocallyExcluded(text, m.index)) return true;
  }
  return false;
}

function interveningWord(tok) {
  return String(tok || "").replace(/[^A-Za-z']/g, "");
}

/**
 * Every `to <lemma>` in a clause, scanned once. The gap classifier below
 * consumes this index instead of re-tokenizing the intervening span, so a
 * candidate that stays nearest for many self-review mentions never pays
 * for an ever-growing rescan.
 */
function localInfinitiveSpans(local) {
  const infRe = /\bto\s+([A-Za-z][A-Za-z'-]*)/gi;
  const out = [];
  let m;
  while ((m = infRe.exec(local)) !== null) {
    out.push({ index: m.index, end: m.index + m[0].length, lemma: m[1] });
  }
  return out;
}

/**
 * The last `to <lemma>` lying wholly inside the gap `[verbEnd, selfIndex)`,
 * by binary search over `localInfinitiveSpans`. Equivalent to rescanning
 * the gap itself: a grant-verb / permission span ends on a word boundary
 * and `self-review` starts on one, so no infinitive can straddle either
 * edge of the gap, and the spans are ascending in both `index` and `end`.
 */
function lastInfinitiveLemma(infinitives, verbEnd, selfIndex) {
  let lo = 0;
  let hi = infinitives.length - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (infinitives[mid].end <= selfIndex) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (found < 0) return "";
  const hit = infinitives[found];
  return hit.index >= verbEnd ? hit.lemma : "";
}

/**
 * The two whitespace-delimited raw tokens immediately before `end`, found
 * by scanning backward without ever crossing `start` (the gap's left
 * edge). Cost is the width of those two tokens, not the width of the gap
 * — the same bounded shape as `lastTwoWordsBefore`. Returns
 * `[last, prev]`; a token that does not exist comes back as `null`.
 */
function lastTwoRawTokensBetween(text, start, end) {
  const s = text;
  const lo = Math.max(0, Math.min(start, s.length));
  let i = Math.max(lo, Math.min(end, s.length));
  const out = [null, null];
  for (let k = 0; k < 2 && i > lo; k += 1) {
    while (i > lo && /\s/.test(s[i - 1])) i -= 1;
    const tokEnd = i;
    while (i > lo && !/\s/.test(s[i - 1])) i -= 1;
    if (i === tokEnd) break;
    out[k] = s.slice(i, tokEnd);
  }
  return out;
}

/**
 * A negative-authority verb that takes its own object
 * (`deny permission to self-review`, `forbid the builder to
 * self-review`, `prevent the builder from self-review`). Distinct from
 * `SELF_REVIEW_NON_GRANT_PRED_RE`, which classifies the act at the *end*
 * of the gap; this one classifies the verb at its *start*, where the
 * rest of the gap is that verb's object rather than a grant.
 */
const SELF_REVIEW_NEGATIVE_AUTHORITY_VERB_RE =
  /^(?:den(?:y|ies|ied|ying)|refus(?:e|es|ed|ing)|forbid(?:s|ding)?|forbade|forbidden|prevent(?:s|ed|ing)?|prohibit(?:s|ed|ing)?|disallow(?:s|ed|ing)?|withhold(?:s|ing)?|withheld|bar(?:s|red|ring)?|block(?:s|ed|ing)?|reject(?:s|ed|ing)?|revok(?:e|es|ed|ing))$/i;

/**
 * Longest word either first-token test can match: `shouldn't` /
 * `wouldn't` in `LOCAL_POLARITY_TOKEN_RE`, and `prohibiting` /
 * `disallowing` / `withholding` in
 * `SELF_REVIEW_NEGATIVE_AUTHORITY_VERB_RE`.
 */
const GAP_FIRST_WORD_MAX_LETTERS = 11;

/**
 * Probe the gap's first whitespace-delimited token once per candidate.
 * Only the two first-token tests read that token, and both are anchored
 * to words of at most `GAP_FIRST_WORD_MAX_LETTERS` letters, so
 * collecting one letter more than that is enough to decide every prefix
 * of it: anything longer can never match and is not materialized.
 */
function scanFirstGapToken(text, verbEnd) {
  const s = text;
  let i = Math.max(0, Math.min(verbEnd, s.length));
  while (i < s.length && /\s/.test(s[i])) i += 1;
  const probe = { verbEnd, start: i, letters: [], overflowAt: Infinity };
  while (i < s.length && !/\s/.test(s[i])) {
    if (/[A-Za-z']/.test(s[i])) {
      if (probe.letters.length > GAP_FIRST_WORD_MAX_LETTERS) {
        probe.overflowAt = i;
        break;
      }
      probe.letters.push({ at: i, ch: s[i] });
    }
    i += 1;
  }
  return probe;
}

/**
 * The probed first token, clipped at `selfIndex` (a `self-review` match
 * can begin inside that token, e.g. `may not-self-review`) and reduced to
 * the letters `interveningWord` would keep. `""` when the clipped token is
 * longer than any word either first-token test can match, which cannot
 * match either way.
 */
function firstGapWord(probe, selfIndex) {
  if (probe.start >= selfIndex || selfIndex > probe.overflowAt) return "";
  let out = "";
  for (let k = 0; k < probe.letters.length; k += 1) {
    if (probe.letters[k].at >= selfIndex) break;
    out += probe.letters[k].ch;
  }
  return out;
}

/**
 * Unnegated has/have/had permission|right|authority (with an optional
 * explicit/full/express/written/formal modifier), passive was/were/has
 * been granted|given permission|right|authority, and must/shall/is|are
 * (expressly/explicitly/formally) required to are themselves the grant.
 * Do not wait for a second grant verb after that span. Reuses the
 * clause's precomputed self-review spans (`state.selfs`) instead of
 * rescanning per permission span. Residual: not general NLP.
 */
function permissionPredicateGrantsSelfReview(text, span, state) {
  const local = String(text || "").split(/[.!?;]/)[0] || "";
  if (!span || span.end > local.length) return false;
  const sameClause = Boolean(state) && state.local === local;
  const selfs =
    sameClause && Array.isArray(state.selfs)
      ? state.selfs
      : overlayRegexMatches(/\bself[\s-]?review\b/i, local);
  const blocksGrant =
    (sameClause && state.blocksGrant) || selfReviewGapClassifier(local);
  for (const self of selfs) {
    if (self.index < span.end) continue;
    if (!blocksGrant(span.end, self.index)) return true;
  }
  return false;
}

/**
 * Per-clause gap classifier: decides, for one candidate end and one
 * self-review start, whether the intervening language blocks the grant.
 *
 * Nothing here slices, collapses, or tokenizes the whole
 * `[verbEnd, selfIndex)` gap. Each check reads either a bounded backward
 * token scan, the candidate's cached forward first-token probe, or a
 * binary search over the clause's infinitive index — so one candidate that
 * remains nearest for many self-review mentions costs O(log n) per mention
 * instead of an ever-growing rescan. The classification itself is
 * unchanged: unfamiliar intervening language still fails closed.
 */
function selfReviewGapClassifier(local) {
  const text = String(local || "");
  let infinitives = null;
  let probe = null;
  return function interveningSelfReviewBlocksGrant(verbEnd, selfIndex) {
    if (topicLocallyExcluded(text, selfIndex)) return true;
    const [lastRaw, prevRaw] = lastTwoRawTokensBetween(text, verbEnd, selfIndex);
    // No token in the gap at all — the grant verb attaches directly.
    if (lastRaw === null) return false;
    if (!probe || probe.verbEnd !== verbEnd) {
      probe = scanFirstGapToken(text, verbEnd);
    }
    const firstWord = firstGapWord(probe, selfIndex);
    if (LOCAL_POLARITY_TOKEN_RE.test(firstWord)) return true;
    // A negative-authority verb heading the gap governs everything after
    // it: `deny permission to self-review` and `forbid the builder to
    // self-review` end in the same `… to` tail as a genuine grant, and
    // `prevent/prohibit … from self-review` in the same bare-noun tail,
    // so this has to bind before the trailing-`to` / conduct rules below
    // can read that tail as the granted act.
    if (SELF_REVIEW_NEGATIVE_AUTHORITY_VERB_RE.test(firstWord)) return true;
    // The gap's last two tokens are the whole tail these three
    // end-anchored patterns can reach, and a token start carries the same
    // `\b` context here as in the full gap, so matching on them is exact.
    const tail = prevRaw === null ? lastRaw : `${prevRaw} ${lastRaw}`;
    if (/\b(?:not|never|no)\s+to\s*$/i.test(tail)) return true;
    // Trailing `to self-review` / `conduct self-review` is the grant act.
    if (/\bto\s*$/i.test(tail)) return false;
    if (/\b(?:to\s+)?(?:conduct|perform|carry\s+out)\s*$/i.test(tail)) {
      return false;
    }
    // Last infinitive is the authorized act (`to discuss` vs `to conduct`).
    if (!infinitives) infinitives = localInfinitiveSpans(text);
    const infLemma = lastInfinitiveLemma(infinitives, verbEnd, selfIndex);
    if (infLemma) return SELF_REVIEW_NON_GRANT_PRED_RE.test(infLemma);
    // No infinitive: non-grant when the grant object is that topic
    // attaching to self-review (`a report about`, `a ban on`), or when
    // the last word is itself that predicate (`may discuss self-review`).
    const last = interveningWord(lastRaw);
    const prev = interveningWord(prevRaw);
    if (SELF_REVIEW_NON_GRANT_TOPIC_PREP_RE.test(last)) {
      return SELF_REVIEW_NON_GRANT_PRED_RE.test(prev);
    }
    return SELF_REVIEW_NON_GRANT_PRED_RE.test(last);
  };
}

/**
 * Merge two ascending-by-`.end` span lists into one ascending-by-`.end`
 * list, in O(a + b). Used to combine grant-verb and permission-predicate
 * spans into a single candidate list for the nearest-candidate-per-self
 * pass below, instead of scanning each list separately per self.
 */
function mergeSpansByEnd(a, b) {
  const merged = [];
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (a[i].end <= b[j].end) merged.push(a[i++]);
    else merged.push(b[j++]);
  }
  while (i < a.length) merged.push(a[i++]);
  while (j < b.length) merged.push(b[j++]);
  return merged;
}

/**
 * Single forward pass over `selfs` (ascending): for each self-review
 * span, advance a monotonic cursor `ci` to the nearest preceding grant
 * candidate (a merged grant-verb / unnegated-permission span) and check
 * whether the gap to that self blocks the grant. `ci` only ever moves
 * forward across the whole outer loop — it is never reset to the start
 * of `candidates` for a later self — so total cost is O(candidates +
 * selfs), not O(candidates * selfs). `minIndex` mirrors the leftmost
 * recognized permission predicate's position: a candidate or self
 * entirely before it is out of scope, matching the original
 * permission-anchored scan it replaces.
 */
function nearestCandidateGrantsAnySelf(blocksGrant, candidates, selfs, minIndex) {
  if (!blocksGrant || !candidates.length || !selfs.length) return false;
  const floor = Number(minIndex) || 0;
  let ci = 0;
  for (let si = 0; si < selfs.length; si += 1) {
    const self = selfs[si];
    if (self.index < floor) continue;
    while (ci + 1 < candidates.length && candidates[ci + 1].end <= self.index) {
      ci += 1;
    }
    const candidate = candidates[ci];
    if (!candidate || candidate.index < floor || candidate.end > self.index) {
      continue;
    }
    if (!blocksGrant(candidate.end, self.index)) return true;
  }
  return false;
}

/**
 * One forward pass over a polarity/clause unit: grant-verb, self-review,
 * and unnegated-permission spans, plus the self-review-target grant
 * verdict for the whole clause (`selfReviewTargetGrant`) computed once
 * via `nearestCandidateGrantsAnySelf` — not once per permission span.
 * Callers reuse this instead of nested per-self-review-per-permission
 * rescans. Residual: not general NLP.
 */
function selfReviewClauseState(text) {
  const src = String(text || "");
  const local = src.split(/[.!?;]/)[0] || "";
  const verbs = overlayRegexMatches(SELF_REVIEW_GRANT_VERB_RE, local);
  const selfs = overlayRegexMatches(/\bself[\s-]?review\b/i, local);
  const perms = unnegatedPermissionSpans(src).filter((p) => p.end <= local.length);
  const blocksGrant = selfReviewGapClassifier(local);
  // No modal / permission predicate anchors this clause. An indicative or
  // passive grant is still a grant ("gives the builder permission to
  // self-review", "is hereby granted permission to self-review"), so fall
  // back to the clause's own unnegated grant verbs. `verbs` cannot serve:
  // it also carries `may` / `can`, and an unnegated one of those would
  // have produced a permission span — so every modal left in `verbs` here
  // is a negated one. This second pass only runs for the clauses that
  // found no permission span at all.
  const grantVerbs = perms.length
    ? []
    : overlayRegexMatches(AUTH_GRANT_VERB_RE, local).filter(
        (span) => !permissionPredicateNegated(local, span)
      );
  const selfReviewTargetGrant = perms.length
    ? nearestCandidateGrantsAnySelf(
        blocksGrant,
        mergeSpansByEnd(verbs, perms),
        selfs,
        perms[0].index
      )
    : nearestCandidateGrantsAnySelf(blocksGrant, grantVerbs, selfs, 0);
  return {
    src,
    local,
    verbs,
    selfs,
    perms,
    grantVerbs,
    blocksGrant,
    selfReviewTargetGrant,
  };
}

/**
 * Unnegated grant/permission/approval verb then `self-review` in this
 * polarity/clause unit is a grant unless the intervening phrase is an
 * explicit non-grant predicate or topic (infinitive discuss/report/… or
 * a report/ban/… attaching via about/on/of) or a local negation.
 * Direct `can self-review` / `may conduct self-review` and
 * give/provide permission are grants. Prenominal modifiers of the
 * recipient or role are not that predicate. Unfamiliar intervening
 * language fails closed. Discuss / reject / review are not grant verbs.
 * A later sentence cannot bind. Residual: not general NLP.
 *
 * Rightmost grant verb before each self-review is enough: an earlier
 * unblocked grant would already have attached to an earlier
 * self-review, and last-infinitive / trailing-to / last-predicate
 * blocking is determined by the gap after that nearest verb.
 */
function grantThenSelfReviewFromState(state, fromIndex) {
  const local = state && state.local;
  const verbs = (state && state.verbs) || [];
  const selfs = (state && state.selfs) || [];
  if (!local || !verbs.length || !selfs.length) return false;
  const blocksGrant =
    (state && state.blocksGrant) || selfReviewGapClassifier(local);
  const start = Number(fromIndex) || 0;
  let vi = 0;
  for (let si = 0; si < selfs.length; si += 1) {
    const self = selfs[si];
    if (self.index < start) continue;
    while (vi + 1 < verbs.length && verbs[vi + 1].end <= self.index) {
      vi += 1;
    }
    const verb = verbs[vi];
    if (!verb || verb.index < start || verb.end > self.index) continue;
    if (!blocksGrant(verb.end, self.index)) return true;
  }
  return false;
}

function grantThenSelfReview(after, state, fromIndex) {
  const precomputed = state && Array.isArray(state.verbs) && Array.isArray(state.selfs);
  const st = precomputed ? state : selfReviewClauseState(after);
  const start = precomputed ? Number(fromIndex) || 0 : 0;
  return grantThenSelfReviewFromState(st, start);
}

function selfReviewGrantAction(blob) {
  if (/\bdelegat/i.test(blob) || /\bassign/i.test(blob)) return "delegate";
  if (/\bpermit/i.test(blob)) return "permit";
  if (/\ballow/i.test(blob) || /\blets?\b/i.test(blob)) return "allow";
  if (/\bgrant/i.test(blob) || /\bgiv(?:e|es|en|ing)\b/i.test(blob) || /\bprovid/i.test(blob)) {
    return "grant";
  }
  if (/\bapprov/i.test(blob)) return "approve";
  if (/\bauthoriz/i.test(blob)) return "authorize";
  return "authorize";
}

/**
 * Normalize a self-review permission unit to actor/action/target/polarity.
 * Unnegated permission that authorizes, permits, allows, grants, approves,
 * gives/provides permission, lets/assigns, or delegates review to/by the
 * same agent, self-review, or the same agent as reviewer fails regardless
 * of word order, voice, or intervening review-conducted / grant-verb
 * phrases that are not an explicit non-grant predicate/topic or local
 * negation. Direct `can self-review` / `may conduct self-review`,
 * `has/have/had permission|right|authority to self-review`, and
 * `must` / `shall` / `is|are required to self-review` are grants without
 * a second grant verb. Passive `assigned to the same agent` is a grant.
 * Prenominal recipient or role modifiers are not that predicate.
 * Unfamiliar intervening language fails closed. An independent subject
 * reviewing, discussing, or rejecting self-review is not a grant;
 * granting self-review or same-agent review is.
 *
 * @returns {{
 *   action: 'authorize' | 'permit' | 'allow' | 'delegate' | 'grant' | 'approve' | 'review' | null,
 *   target: 'same-agent' | 'self-review' | null,
 *   polarity: 'grant' | 'none',
 * } | null}
 */
function selfReviewPermissionUnit(text, span, state) {
  const after = text.slice(span.index);
  const afterEnd = text.slice(span.end);
  const before = text.slice(0, span.index);
  const activeReviewPhraseGrant = new RegExp(
    `${AUTH_GRANT_VERB_RE.source}\\s+${REVIEW_NOUN_PHRASE_SRC}\\s+(?:by|to)\\s+(?:the\\s+)?same[\\s-]?agent\\b`,
    "i"
  ).test(after);
  const activeSameAgentGrant =
    new RegExp(
      `${AUTH_GRANT_VERB_RE.source}\\s+(?:the\\s+)?same[\\s-]?agent\\b`,
      "i"
    ).test(after) && REVIEW_ACT_RE.test(after);
  const sameAgentToReview =
    /\bsame[\s-]?agent\s+to\s+(?:review|evaluate|grade)\b/i.test(after);
  const grantSameAgentAsReviewer = new RegExp(
    `${AUTH_GRANT_VERB_RE.source}\\s+(?:the\\s+)?same[\\s-]?agent\\s+${REVIEWER_NOUN_TARGET_SRC}\\b`,
    "i"
  ).test(after);
  // Hot path: `state.selfReviewTargetGrant` is the single precomputed
  // clause-wide verdict from `selfReviewClauseState`'s one forward pass.
  // `grantThenSelfReview` / `permissionPredicateGrantsSelfReview` remain
  // as narrow fallback helpers for callers that pass no precomputed
  // state (not this function's hot path, which always receives one).
  const selfReviewTargetGrant =
    state && typeof state.selfReviewTargetGrant === "boolean"
      ? state.selfReviewTargetGrant
      : grantThenSelfReview(after, state, span.index) ||
        permissionPredicateGrantsSelfReview(text, span, state);
  if (selfReviewTargetGrant) {
    return {
      action: selfReviewGrantAction(after),
      target: "self-review",
      polarity: "grant",
    };
  }
  if (
    activeReviewPhraseGrant ||
    activeSameAgentGrant ||
    sameAgentToReview ||
    grantSameAgentAsReviewer
  ) {
    return {
      action: selfReviewGrantAction(after),
      target: "same-agent",
      polarity: "grant",
    };
  }
  const passiveDelegated =
    /\bbe\s+(?:delegat(?:e|ed|ing)|assigned)\s+to\s+(?:the\s+)?same[\s-]?agent\b/i.test(
      afterEnd
    );
  const passiveConductedBy =
    /\bbe\s+(?:conducted|done|performed|carried\s+out)\s+by\s+(?:the\s+)?same[\s-]?agent\b/i.test(
      afterEnd
    );
  if (
    (passiveDelegated || passiveConductedBy) &&
    (REVIEW_ACT_RE.test(after) || /\breview\b/i.test(before))
  ) {
    return {
      action: passiveDelegated ? "delegate" : selfReviewGrantAction(after),
      target: "same-agent",
      polarity: "grant",
    };
  }
  const subject = /\bsame[\s-]?agent\b/i.test(before);
  if (/\bbe\s+(?:the\s+)?same[\s-]?agent\b/i.test(after)) {
    return { action: "review", target: "same-agent", polarity: "grant" };
  }
  if (subject && /\bbe\s+(?:the\s+)?reviewer\b/i.test(after)) {
    return { action: "review", target: "same-agent", polarity: "grant" };
  }
  if (subject && REVIEW_ACT_RE.test(after)) {
    return { action: "review", target: "same-agent", polarity: "grant" };
  }
  if (subject && /\breview\b/i.test(before)) {
    return { action: "review", target: "same-agent", polarity: "grant" };
  }
  if (/\b(?:be\s+)?reviewed\s+by\s+(?:the\s+)?same[\s-]?agent\b/i.test(afterEnd)) {
    return { action: "review", target: "same-agent", polarity: "grant" };
  }
  return null;
}

/**
 * `unit` is the single `selfReviewPermissionUnit` result for this
 * permission span — computed once by the caller and reused for both the
 * same-agent and self-review target checks, rather than recomputed once
 * per check.
 */
function sameAgentGrantFromUnit(text, unit) {
  if (!unit || unit.polarity !== "grant" || unit.target !== "same-agent") {
    return false;
  }
  // Independent review is not a same-agent grant; explicit grant/delegation
  // to/by the same agent as reviewer still is.
  const delegatedOrAuthorized =
    unit.action === "authorize" ||
    unit.action === "permit" ||
    unit.action === "allow" ||
    unit.action === "delegate" ||
    unit.action === "grant" ||
    unit.action === "approve";
  if (clauseSubjectIsIndependent(text) && !delegatedOrAuthorized) return false;
  return true;
}

function selfReviewTopicGrantFromUnit(unit) {
  return Boolean(
    unit && unit.polarity === "grant" && unit.target === "self-review"
  );
}

function selfReviewGrantTopic(unit) {
  const text = collapseWs(String(unit || ""));
  if (!text) return null;
  // Reversed subject: "Self-review is required of an independent
  // reviewer" obligates self-review directly (self-review is the
  // grammatical subject, not the object after a permission verb), so it
  // is not reached by the permission-span scan below.
  if (SELF_REVIEW_REQUIRED_OF_RE.test(text)) return "self-review";
  if (independentReviewNotRequired(text)) return "same-agent";
  // One forward pass computes verbs/selfs/perms/grant-verbs and the
  // clause-wide self-review-target grant verdict together; nothing here
  // rescans from offset zero per anchor.
  const state = selfReviewClauseState(text);
  const perms = state.perms;
  const reversedGrant = reversedSelfReviewPermissionGranted(text);
  // Permission spans anchor the clause when it has any; otherwise its
  // unnegated grant verbs do, so an indicative or passive grant with no
  // modal is still evaluated.
  const anchors = perms.length ? perms : state.grantVerbs;
  if (!anchors.length) return reversedGrant ? "self-review" : null;
  let sameAgentGrant = false;
  // These do not depend on which anchor span is inspected; compute them
  // once instead of once per anchor span. The broad topic tests (a bare
  // `self-review` mention, own work anywhere in the clause) stay behind
  // the permission anchor: with no permission predicate in the clause
  // they would read a prohibition ("must never review your own work",
  // whose only modal is negated) as a grant.
  let ownGrant =
    reversedGrant ||
    state.selfReviewTargetGrant ||
    (perms.length > 0 &&
      ((/\bself[\s-]?review\b/i.test(text) &&
        !clauseSubjectIsIndependent(text)) ||
        ownWorkGrantedIn(text)));
  // Every remaining check below (same-agent phrase detection, and the
  // own-work-after-review-act fallback) is a before-only or after-only
  // pattern match: existence in a shorter suffix/prefix implies existence
  // in the longest suffix (leftmost anchor span) or longest prefix
  // (rightmost anchor span) that contains it. So checking at most those
  // two representative spans — not one call per anchor span — finds
  // everything the full anchor-by-anchor scan would, in O(clause length)
  // regardless of how many anchors exist.
  const first = anchors[0];
  const last = anchors[anchors.length - 1];
  const candidateSpans = first === last ? [first] : [first, last];
  for (const span of candidateSpans) {
    if (sameAgentGrant && ownGrant) break;
    const permUnit = selfReviewPermissionUnit(text, span, state);
    if (!sameAgentGrant && sameAgentGrantFromUnit(text, permUnit)) {
      sameAgentGrant = true;
    }
    if (!ownGrant && selfReviewTopicGrantFromUnit(permUnit)) ownGrant = true;
    if (!ownGrant) {
      const before = text.slice(0, span.index);
      const after = text.slice(span.end);
      if (REVIEW_ACT_RE.test(after) && ownWorkGrantedIn(`${before} ${after}`)) {
        ownGrant = true;
      }
    }
  }
  if (!sameAgentGrant && !ownGrant) return null;
  if (/\bgenerat/i.test(text) && /\b(?:own|self)\b/i.test(text) && ownWorkGrantedIn(text)) {
    return "own generation";
  }
  if (/\bself[\s-]?review\b/i.test(text) && ownGrant) {
    return "self-review";
  }
  if (/\bself[\s-]?review\b/i.test(text) && !clauseSubjectIsIndependent(text)) {
    return "self-review";
  }
  if (sameAgentGrant) return "same-agent";
  return "own work";
}

/**
 * Modal, noun, and passive self-review grants are clause-local.
 * Coordinated, semicolon, and adversative units are not joined. Own-work
 * under local not/except/`other than` is not a grant. Noun permission is.
 * Residual: not general NLP.
 */
function bodySelfReviewGrantTopic(hay) {
  for (const unit of grantPolarityUnits(hay)) {
    const topic = selfReviewGrantTopic(unit);
    if (topic) return topic;
  }
  return null;
}

/**
 * Playbook / job BODY must not invert role-contract obligations. Frontmatter
 * parity alone is not enough: "the builder may merge", "the green gate
 * may be skipped", or a modal grant to review own/self/same-agent work
 * in the mandatory prompt body changes agent behaviour. Polarized
 * sentences are not joined.
 *
 * @param {string} id
 * @param {{ forbidden?: string[], gates?: string[], outputs?: string[] }} authBuckets
 * @param {string} body
 * @returns {Array<{ code: string, message: string }>}
 */
export function playbookBodyObligationFindings(id, authBuckets, body) {
  const findings = [];
  const forbidden = Array.isArray(authBuckets && authBuckets.forbidden)
    ? authBuckets.forbidden
    : [];
  const gates = Array.isArray(authBuckets && authBuckets.gates)
    ? authBuckets.gates
    : [];
  const hay = authorityClaimHaystack(body || "");
  if (!hay.trim()) return findings;

  if (forbidden.some(isUnqualifiedMergeForbidden) && BODY_GRANT_MERGE_RE.test(hay)) {
    findings.push({
      code: "E_ROLE_NEGATION",
      message: `${id} body grants merge authority while forbidden lists merging`,
    });
  }
  if (
    gates.some(requiresGreenGate) &&
    (BODY_SKIP_GREEN_RE.test(hay) || BODY_SKIP_GREEN_RE2.test(hay))
  ) {
    findings.push({
      code: "E_ROLE_NEGATION",
      message: `${id} body permits skipping the green gate while gates require it`,
    });
  }
  const selfReviewProhibited =
    gates.some(isSelfReviewObligation) || forbidden.some(isSelfReviewObligation);
  const selfReviewGrant = selfReviewProhibited
    ? bodySelfReviewGrantTopic(hay)
    : null;
  if (selfReviewGrant) {
    findings.push({
      code: "E_ROLE_NEGATION",
      message: `${id} body grants review of ${selfReviewGrant} while gates or forbidden prohibit self-review`,
    });
  }
  return findings;
}
