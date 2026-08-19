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
      });
    }
  }
  for (const pItem of unmatchedPb) {
    findings.push({
      code: "E_ROLE_ADDITION",
      message: `${role} ${bucket}: playbook adds obligation absent from authority: ${pItem.text}`,
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

const GATE_ENTRY_RE = /^[ \t]*- \*\*(G\d+)\*\*(?:[ \t]*⛔)?[ \t]*—[ \t]*(.+)$/gm;
const ANY_GATE_ID_RE = /\*\*(G\d+)\*\*/g;

/**
 * Structural closed-list parse of human-gate bullets. Multiplicity is
 * preserved; unexpected IDs such as G17 are visible; duplicates are not
 * collapsed. Only `- **G<digits>** — summary` list entries count.
 */
export function parseHumanGateEntries(agentsText) {
  const section = extractSection(agentsText, "Human gates (the ONLY reasons to stop)");
  const hay = section || agentsText;
  const entries = [];
  let m;
  const re = new RegExp(GATE_ENTRY_RE.source, "gm");
  while ((m = re.exec(hay)) !== null) {
    entries.push({
      id: m[1],
      summary: collapseWs(m[2]),
      index: entries.length,
    });
  }
  return entries;
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

function localPolarityWindow(text, needle) {
  const flat = collapseWs(text);
  const idx = flat.toLowerCase().indexOf(String(needle).toLowerCase());
  if (idx < 0) return null;
  const before = flat.slice(Math.max(0, idx - 48), idx);
  const clause = flat.slice(Math.max(0, idx - 48), Math.min(flat.length, idx + needle.length + 48));
  const stripped = clause.replace(/\bnot just\b[\s\S]*/i, "");
  return { before, clause: stripped, idx };
}

export function diffBindingPhrase(familyId, phrase, section, opts = {}) {
  const findings = [];
  const hit = localPolarityWindow(section || "", phrase);
  if (!hit) {
    findings.push({
      code: "E_BINDING_FAMILY",
      message: `AGENTS.md binding-family ${familyId} omits required statement: ${phrase}`,
    });
    return findings;
  }
  const before = hit.before.toLowerCase();
  const clause = hit.clause.toLowerCase();
  if (
    /\b(never|not|no longer|without)\b/.test(before) ||
    new RegExp(`\\b(never|not)\\s+${escapeRe(phrase.split(" ")[0])}`, "i").test(clause)
  ) {
    findings.push({
      code: "E_BINDING_NEGATION",
      message: `AGENTS.md binding-family ${familyId} negated around "${phrase}"`,
    });
  } else if (opts.requireMust !== false && /\b(optional|may|should)\b/.test(before)) {
    findings.push({
      code: "E_BINDING_WEAKENING",
      message: `AGENTS.md binding-family ${familyId} weakened around "${phrase}"`,
    });
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

  const tiers = parseRiskTiers(agentsText).map((t) => t.id);
  findings.push(...diffClosedSequence("TIER", tiers, EXPECTED_TIERS));

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
    const omText = String(om.f.message || "").replace(/^.*omits authority obligation:\s*/, "");
    const omShape = semanticShape(omText, om.bucket);
    let best = null;
    let bestScore = 0;
    for (const ad of additions) {
      if (ad.bucket === om.bucket) continue;
      const adText = String(ad.f.message || "").replace(
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

const OPERATIVE_CLAIM_PATTERNS = [
  {
    id: "closed-list",
    re: /\bthis list is\s+\*\*closed\*\*/i,
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
    re: /\ba role is a\s+\*\*contract\*\*/i,
  },
  {
    id: "principle-wins-over-agents",
    re: /\bthe principle wins\b/i,
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

function paragraphDefersToAgents(para) {
  return /\bAGENTS\.md\b/.test(para);
}

export function findOperativeClaims(text) {
  const hits = [];
  for (const pat of OPERATIVE_CLAIM_PATTERNS) {
    const m = pat.re.exec(text);
    if (!m) continue;
    const idx = m.index;
    const start = text.lastIndexOf("\n\n", idx);
    const end = text.indexOf("\n\n", idx + m[0].length);
    const para = text.slice(start === -1 ? 0 : start, end === -1 ? text.length : end);
    hits.push({
      id: pat.id,
      snippet: collapseWs(m[0]).slice(0, 160),
      defersToAgents: paragraphDefersToAgents(para),
    });
  }
  return hits;
}

/**
 * A non-normative file that later asserts a closed/authoritative/operative
 * list without deferring to AGENTS.md in the same paragraph.
 */
export function findNonNormativeOperativeContradiction(text, nonNormativeMarker) {
  if (!text.includes(nonNormativeMarker)) return [];
  const after = text.slice(text.indexOf(nonNormativeMarker) + nonNormativeMarker.length);
  return findOperativeClaims(after).filter((h) => !h.defersToAgents);
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
