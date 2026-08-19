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

export function extractGateSummaries(agentsText) {
  const out = new Map();
  const re = /\*\*(G(?:[1-9]|1[0-6]))\*\*\s*(?:⛔\s*)?—\s*([^\n]+)/g;
  let m;
  while ((m = re.exec(agentsText)) !== null) {
    out.set(m[1], m[2].trim());
  }
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

export const PROVENANCE_FORBIDDEN_ROLES = new Set(["canonical-doctrine"]);
export const PROVENANCE_ALLOWED_ROLES = new Set([
  "human-readable-contract",
  "explanatory-history",
  "compatibility-doctrine",
  "supporting",
]);
