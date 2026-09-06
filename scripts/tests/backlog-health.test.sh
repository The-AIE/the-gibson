#!/usr/bin/env bash
# backlog-health.test.sh — fixtures F1–F12 + live-stub parity + mutation teeth (#309)
#
# WHY
#   The blocked predicate, moved truth table, and INCOMPLETE>RED>YELLOW>GREEN
#   order are load-bearing. Fixture-only tests are hollow: every case runs
#   --fixture and a stubbed-fetch GraphQL path through the same
#   normaliser+classifier and byte-compares the two outputs.
#
# USAGE
#   scripts/tests/backlog-health.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
SENSOR="$REPO_ROOT/scripts/backlog-health.mjs"
CFG="$REPO_ROOT/config/backlog-health.v1.json"
DECOMPOSE="$REPO_ROOT/scripts/decompose-graph.mjs"
NOW="2026-09-04T00:00:00.000Z"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "backlog-health.test.sh: node required"; exit 1; }
[[ -f "$SENSOR" ]] || { echo "backlog-health.test.sh: missing $SENSOR"; exit 1; }
[[ -f "$CFG" ]] || { echo "backlog-health.test.sh: missing $CFG"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-backlog-health.XXXXXX")
MUT1="$ROOT/mut-incomplete.mjs"
MUT2="$ROOT/mut-red.mjs"
MUT3="$ROOT/mut-yellow.mjs"
trap 'rm -rf "$ROOT"' EXIT

SENSOR_URL=$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$SENSOR")

has() {
  printf '%s\n' "$1" | grep -E "$2" >/dev/null
}
has_f() {
  printf '%s\n' "$1" | grep -F -- "$2" >/dev/null
}

# --- CLI contract -----------------------------------------------------------
echo "# CLI contract"
help_out=$(node "$SENSOR" --help 2>"$ROOT/help.err")
help_rc=$?
if [[ "$help_rc" -eq 0 ]] \
   && has_f "$help_out" "WHAT IT DOES" \
   && has_f "$help_out" "WHY" \
   && has_f "$help_out" "RISKS" \
   && has_f "$help_out" "USAGE" \
   && has_f "$help_out" "EXIT"; then
  ok "--help exits 0 with Ask-Contract fields"
else
  bad "--help (rc=$help_rc)"
fi
[[ ! -s "$ROOT/help.err" ]] && ok "--help quiet on stderr" || bad "--help wrote stderr"

unk_err=$(node "$SENSOR" --definitely-not-a-flag 2>&1 >/dev/null)
unk_rc=$?
if [[ "$unk_rc" -eq 2 ]] && has_f "$unk_err" "unknown flag: --definitely-not-a-flag"; then
  ok "unknown flag exits 2"
else
  bad "unknown flag (rc=$unk_rc err=$unk_err)"
fi

noval_err=$(node "$SENSOR" --fixture 2>&1 >/dev/null)
noval_rc=$?
if [[ "$noval_rc" -eq 2 ]] && has_f "$noval_err" "--fixture requires a value"; then
  ok "value flag without operand exits 2"
else
  bad "missing --fixture value (rc=$noval_rc err=$noval_err)"
fi

# --- source contracts -------------------------------------------------------
echo "# source contracts"
if grep -E 'from ["'\'']\./lib/issue-loader|from ["'\'']\./decompose-graph|from ["'\''][^"'\'']*issue-loader|from ["'\''][^"'\'']*decompose-graph' "$SENSOR" >/dev/null; then
  bad "sensor imports issue-loader.mjs or decompose-graph.mjs"
else
  ok "does not import issue-loader.mjs or decompose-graph.mjs"
fi
if grep -F 'spawnSync' "$SENSOR" >/dev/null; then
  bad "sensor uses spawnSync"
else
  ok "never spawnSync"
fi
if grep -F 'AbortSignal.timeout' "$SENSOR" >/dev/null; then
  ok "uses AbortSignal.timeout"
else
  bad "missing AbortSignal.timeout"
fi
for k in blockedLabel blockedRatioMax blockerQuietDays minDependents requestTimeoutMs; do
  if grep -F "\"$k\"" "$CFG" >/dev/null; then
    ok "config has $k"
  else
    bad "config missing $k"
  fi
done

echo "# AC1 regex source byte-identical to decompose-graph.mjs"
re_out=$(SENSOR_URL="$SENSOR_URL" DECOMPOSE="$DECOMPOSE" node --input-type=module <<'JS'
import { readFileSync } from "node:fs";
const { DEPENDENCY_CITATION_RE_SOURCE } = await import(process.env.SENSOR_URL);
const src = readFileSync(process.env.DECOMPOSE, "utf8");
const start = src.indexOf("/(?:blocked");
const end = start >= 0 ? src.indexOf("/gi", start) : -1;
const extracted = start >= 0 && end > start ? src.slice(start + 1, end) : "";
if (!extracted) {
  console.error("decompose-graph regex not found");
  process.exit(1);
}
if (extracted !== DEPENDENCY_CITATION_RE_SOURCE) {
  console.error("source mismatch\n got " + DEPENDENCY_CITATION_RE_SOURCE + "\n want " + extracted);
  process.exit(1);
}
process.stdout.write("match\n");
JS
)
re_rc=$?
[[ "$re_rc" -eq 0 ]] && ok "DEPENDENCY_CITATION_RE_SOURCE byte-identical" || bad "regex source ($re_out)"

echo "# AC5 loader never process.exit"
ac5_out=$(SENSOR_URL="$SENSOR_URL" node --input-type=module <<'JS'
const { loadFromGraphql, INCOMPLETE } = await import(process.env.SENSOR_URL);
const r = await loadFromGraphql({
  owner: "o",
  name: "n",
  config: {
    blockedLabel: "dependency-blocked",
    blockedRatioMax: 0.4,
    blockerQuietDays: 7,
    minDependents: 3,
    requestTimeoutMs: 50,
  },
  token: "x",
  fetchImpl: async () => ({ ok: false, status: 500, json: async () => ({}) }),
});
if (r.complete !== false) throw new Error("complete");
if (r.incompleteReason !== INCOMPLETE.API_NON_SUCCESS) throw new Error(String(r.incompleteReason));
if (!("rows" in r)) throw new Error("rows");
process.stdout.write("returned\n");
JS
)
ac5_rc=$?
if [[ "$ac5_rc" -eq 0 ]] && has_f "$ac5_out" "returned"; then
  ok "loadFromGraphql returns { complete:false } on HTTP 500 (no process.exit)"
else
  bad "AC5 loader (rc=$ac5_rc out=$ac5_out)"
fi

# --- world builder ----------------------------------------------------------
echo "# build fixtures"
SENSOR_URL="$SENSOR_URL" ROOT="$ROOT" node --input-type=module <<'JS'
import { writeFileSync } from "node:fs";
import { join } from "node:path";

const ROOT = process.env.ROOT;
const LABEL = "dependency-blocked";
const NOW = "2026-09-04T00:00:00.000Z";
const IN = "2026-09-03T00:00:00.000Z";
const BOUND = "2026-08-28T00:00:00.000Z";
const BEFORE = "2026-08-20T00:00:00.000Z";

function depsCite(n) {
  return `## Dependencies\n\nblocked by #${n}\n`;
}
function depsBare(n) {
  return `## Dependencies\n\n- #${n}\n`;
}
function depsNone() {
  return `## Dependencies\n\nnone\n`;
}
function issue(number, opts = {}) {
  const labels = opts.labels || [];
  const body = Object.prototype.hasOwnProperty.call(opts, "body")
    ? opts.body
    : depsNone();
  return {
    number,
    title: `issue ${number}`,
    body,
    state: "OPEN",
    labels,
  };
}
function seven(blockedSpec) {
  // blockedSpec: map number -> { labels, body }
  const nodes = [];
  for (const n of [1, 2, 3, 4, 5, 6, 161]) {
    const s = blockedSpec[n] || {};
    nodes.push(issue(n, s));
  }
  return {
    totalCount: 7,
    hasNextPage: false,
    endCursor: null,
    nodes,
  };
}
function labelled(n, extra = {}) {
  return { labels: [LABEL], body: extra.body || depsNone() };
}
function world(id, obj) {
  writeFileSync(join(ROOT, id + ".json"), JSON.stringify(obj, null, 2));
}

const fiveLabelled = {
  1: labelled(1),
  2: labelled(2),
  3: labelled(3),
  4: labelled(4),
  5: labelled(5),
};

world("F1", { issues: seven(fiveLabelled) });

const cite161 = {
  1: { labels: [LABEL], body: depsCite(161) },
  2: { labels: [LABEL], body: depsCite(161) },
  3: { labels: [LABEL], body: depsBare(161) },
  4: labelled(4),
  5: labelled(5),
};

world("F2", {
  issues: seven(cite161),
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [{ __typename: "IssueComment", createdAt: IN }],
    },
  },
});

world("F3", {
  issues: seven(cite161),
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [
        {
          __typename: "CrossReferencedEvent",
          createdAt: IN,
          source: { __typename: "PullRequest", number: 99, merged: true, state: "MERGED" },
        },
      ],
    },
  },
});

world("F4", {
  issues: seven(cite161),
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [{ __typename: "ClosedEvent", createdAt: IN }],
    },
  },
});

world("F5", {
  issues: seven(cite161),
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [{ __typename: "LabeledEvent", createdAt: IN }],
    },
  },
});

world("F6", {
  issues: seven({
    1: labelled(1),
    2: labelled(2),
  }),
});

world("F7", {
  issues: {
    totalCount: 7,
    hasNextPage: true,
    endCursor: null,
    nodes: [1, 2, 3, 4, 5].map((n) => issue(n, labelled(n))),
  },
});

world("F8", {
  issues: seven(cite161),
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [],
      timelineErrors: [{ message: "timeline boom" }],
    },
  },
});

world("F9", {
  issues: seven({
    1: { labels: [LABEL], body: depsCite(99999) },
    2: labelled(2),
    3: labelled(3),
    4: labelled(4),
    5: labelled(5),
  }),
  cited: { 99999: null },
});

world("F10", {
  issues: seven({
    1: { labels: [LABEL], body: depsCite(161) },
    2: { labels: [LABEL], body: depsCite(161) },
    3: { labels: [LABEL], body: depsCite(161) },
    161: labelled(161),
  }),
  cited: {
    161: { number: 161, state: "OPEN", timeline: [] },
  },
});

world("F11a", {
  issues: seven(cite161),
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [{ __typename: "ClosedEvent", createdAt: BOUND }],
    },
  },
});

world("F11b", {
  issues: seven(cite161),
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [{ __typename: "ClosedEvent", createdAt: NOW }],
    },
  },
});

world("F12a", {
  issues: seven({
    1: labelled(1),
    2: labelled(2),
    3: labelled(3),
  }),
});

world("F12b", {
  issues: seven({
    1: { labels: [], body: depsCite(161) },
    2: { labels: [], body: depsCite(161) },
    3: { labels: [], body: depsBare(161) },
  }),
  cited: { 161: { number: 161, state: "OPEN", timeline: [] } },
});

world("F12-outside", {
  issues: seven({
    1: {
      labels: [],
      body: "blocked by #161\ndepends on #161\n\n## Context\n\nblocked by #161\n\n## Dependencies\n\nnone\n",
    },
  }),
});

world("F12-closed-cite", {
  issues: seven({
    1: { labels: [], body: depsCite(200) },
    2: { labels: [], body: depsCite(200) },
    3: { labels: [], body: depsCite(200) },
  }),
  cited: { 200: { number: 200, state: "CLOSED", timeline: [] } },
});

world("F1-flip", {
  issues: seven({
    1: labelled(1),
    2: labelled(2),
  }),
});

world("F5-flip", {
  issues: seven(cite161),
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [{ __typename: "ReopenedEvent", createdAt: IN }],
    },
  },
});

world("AC3-api", { httpStatus: 500, issues: seven(fiveLabelled) });
world("AC3-timeout", { timeout: true, issues: seven(fiveLabelled) });
world("AC3-listing-errors", {
  listingErrors: [{ message: "boom" }],
  issues: seven(fiveLabelled),
});
world("AC3-missing-label", { labelPresent: false, issues: seven(fiveLabelled) });
world("AC3-count", {
  issues: {
    totalCount: 7,
    hasNextPage: false,
    endCursor: null,
    nodes: [1, 2, 3, 4, 5].map((n) => issue(n, labelled(n))),
  },
});
world("AC3-lookup", {
  issues: seven({
    1: { labels: [LABEL], body: depsCite(888) },
    2: labelled(2),
    3: labelled(3),
    4: labelled(4),
    5: labelled(5),
  }),
  lookupFailures: [888],
});
world("AC3-page-cap", {
  issues: {
    totalCount: 7,
    hasNextPage: true,
    endCursor: "c1",
    nodes: [1, 2, 3, 4, 5].map((n) => issue(n, labelled(n))),
  },
});

world("G-MOVE", {
  issues: {
    totalCount: 10,
    hasNextPage: false,
    nodes: [
      issue(1, { labels: [LABEL], body: depsCite(161) }),
      issue(2, { labels: [LABEL], body: depsCite(161) }),
      issue(3, { labels: [LABEL], body: depsCite(161) }),
      issue(4),
      issue(5),
      issue(6),
      issue(7),
      issue(8),
      issue(9),
      issue(161),
    ],
  },
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [{ __typename: "ClosedEvent", createdAt: IN }],
    },
  },
});

const truth = [
  ["TT-closed", { __typename: "ClosedEvent", createdAt: IN }, "YELLOW"],
  ["TT-reopened", { __typename: "ReopenedEvent", createdAt: IN }, "YELLOW"],
  [
    "TT-xref-merged",
    {
      __typename: "CrossReferencedEvent",
      createdAt: IN,
      source: { __typename: "PullRequest", number: 9, merged: true, state: "MERGED" },
    },
    "YELLOW",
  ],
  [
    "TT-connected-merged",
    {
      __typename: "ConnectedEvent",
      createdAt: IN,
      subject: { __typename: "PullRequest", number: 9, merged: true, state: "MERGED" },
    },
    "YELLOW",
  ],
  [
    "TT-xref-open-pr",
    {
      __typename: "CrossReferencedEvent",
      createdAt: IN,
      source: { __typename: "PullRequest", number: 9, merged: false, state: "OPEN" },
    },
    "RED",
  ],
  [
    "TT-xref-issue",
    {
      __typename: "CrossReferencedEvent",
      createdAt: IN,
      source: { __typename: "Issue", number: 9 },
    },
    "RED",
  ],
  ["TT-comment-bot", { __typename: "IssueComment", createdAt: IN }, "RED"],
  ["TT-labeled", { __typename: "LabeledEvent", createdAt: IN }, "RED"],
  ["TT-unlabeled", { __typename: "UnlabeledEvent", createdAt: IN }, "RED"],
  ["TT-renamed", { __typename: "RenamedTitleEvent", createdAt: IN }, "RED"],
  ["TT-assigned", { __typename: "AssignedEvent", createdAt: IN }, "RED"],
  ["TT-before-window", { __typename: "ClosedEvent", createdAt: BEFORE }, "RED"],
];
for (const [id, event] of truth) {
  world(id, {
    issues: seven(cite161),
    cited: { 161: { number: 161, state: "OPEN", timeline: [event] } },
  });
}

world("TT-ref-reach", {
  issues: seven(cite161),
  reachableOids: ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [
        {
          __typename: "ReferencedEvent",
          createdAt: IN,
          commit: { oid: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        },
      ],
    },
  },
});
world("TT-ref-unreach", {
  issues: seven(cite161),
  reachableOids: [],
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [
        {
          __typename: "ReferencedEvent",
          createdAt: IN,
          commit: { oid: "cccccccccccccccccccccccccccccccccccccccc" },
        },
      ],
    },
  },
});

console.log("wrote worlds");
JS

[[ $? -eq 0 ]] && ok "fixture worlds written" || bad "fixture world builder failed"

write_stub() {
  local world="$1" stub="$2"
  WORLD="$world" STUB="$stub" SENSOR_URL="$SENSOR_URL" node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
const { graphqlStubFromWorld } = await import(process.env.SENSOR_URL);
const world = JSON.parse(readFileSync(process.env.WORLD, "utf8"));
writeFileSync(process.env.STUB, JSON.stringify(graphqlStubFromWorld(world)));
JS
}

run_fx() {
  local world="$1"
  shift
  FX_OUT=$(node "$SENSOR" --fixture "$world" --now "$NOW" --config "$CFG" "$@" 2>"$ROOT/fx.err")
  FX_RC=$?
  FX_ERR=$(cat "$ROOT/fx.err")
}

run_stub() {
  local stub="$1"
  shift
  STUB_OUT=$(node "$SENSOR" --graphql-stub "$stub" --now "$NOW" --config "$CFG" --repo The-AIE/the-gibson "$@" 2>"$ROOT/stub.err")
  STUB_RC=$?
  STUB_ERR=$(cat "$ROOT/stub.err")
}

# run_case ID want_rc want_verdict [extra grep -F strings...] [-- extra cli args]
run_case() {
  local id="$1" want_rc="$2" want_verdict="$3"
  shift 3
  local extra_args=""
  local greps=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      shift
      extra_args="$*"
      break
    fi
    greps+=("$1")
    shift
  done
  local world="$ROOT/${id}.json"
  local stub="$ROOT/${id}.stub.json"
  write_stub "$world" "$stub" || { bad "$id stub write failed"; return; }
  # bash 3.2 + set -u: do not expand an empty array
  # shellcheck disable=SC2086
  run_fx "$world" $extra_args
  # shellcheck disable=SC2086
  run_stub "$stub" $extra_args
  if [[ "$FX_OUT" == "$STUB_OUT" && "$FX_RC" -eq "$STUB_RC" ]]; then
    ok "$id fixture/stub byte-compare (rc=$FX_RC)"
  else
    bad "$id parity fx_rc=$FX_RC stub_rc=$STUB_RC fx=$(printf '%s' "$FX_OUT" | tr '\n' '|') stub=$(printf '%s' "$STUB_OUT" | tr '\n' '|') ferr=$FX_ERR serr=$STUB_ERR"
  fi
  if [[ "$FX_RC" -eq "$want_rc" ]]; then
    ok "$id exit $want_rc"
  else
    bad "$id exit want $want_rc got $FX_RC out=$FX_OUT err=$FX_ERR"
  fi
  if has "$FX_OUT" "^${want_verdict}([ :]|$)"; then
    ok "$id verdict $want_verdict"
  else
    bad "$id verdict want $want_verdict got $(printf '%s' "$FX_OUT" | tr '\n' '|')"
  fi
  if [[ "$want_verdict" == "INCOMPLETE" ]]; then
    if has "$FX_OUT" "^(RED|YELLOW|GREEN) "; then
      bad "$id INCOMPLETE printed a colour: $(printf '%s' "$FX_OUT" | tr '\n' '|')"
    else
      ok "$id INCOMPLETE prints no colour"
    fi
  fi
  local g
  if [[ ${#greps[@]} -gt 0 ]]; then
    for g in "${greps[@]}"; do
      if has_f "$FX_OUT" "$g"; then
        ok "$id contains $(printf '%s' "$g" | tr '\n' ' ')"
      else
        bad "$id missing '$g' in $(printf '%s' "$FX_OUT" | tr '\n' '|')"
      fi
    done
  fi
}

echo "# F1–F12 + AC3 (fixture + stubbed-fetch parity)"
run_case F1 0 RED "5/7" "top blockers: none" "unresolved: 0"
run_case F2 0 RED "5/7" "#161 lastMovedAt"
run_case F3 0 YELLOW "5/7" "#161" "CrossReferencedEvent" "merged-pr"
run_case F4 0 YELLOW "5/7" "#161" "ClosedEvent"
run_case F5 0 RED "5/7" "#161 lastMovedAt"
run_case F6 0 GREEN "2/7"
run_case F7 1 INCOMPLETE "INCOMPLETE: HAS_NEXT_PAGE"
run_case F8 1 INCOMPLETE "INCOMPLETE: GRAPHQL_ERRORS"
run_case F9 0 RED "5/7" "unresolved: 1" "top blockers: none"
run_case F10 0 RED "4/7" "#161 lastMovedAt" "unresolved: 0"
run_case F11a 0 RED "5/7" "#161 lastMovedAt"
run_case F11b 0 YELLOW "5/7" "#161" "ClosedEvent"
run_case F12a 0 RED "3/7" "top blockers: none"
run_case F12b 0 RED "3/7" "#161 lastMovedAt"
run_case F12-outside 0 GREEN "0/7"
run_case F12-closed-cite 0 GREEN "0/7"

echo "# AC2 sibling flips (one fact)"
run_case F1-flip 0 GREEN "2/7"
run_case F5-flip 0 YELLOW "ReopenedEvent"

echo "# AC3 incomplete extras"
run_case AC3-api 1 INCOMPLETE "INCOMPLETE: API_NON_SUCCESS"
run_case AC3-timeout 1 INCOMPLETE "INCOMPLETE: TIMEOUT"
run_case AC3-listing-errors 1 INCOMPLETE "INCOMPLETE: GRAPHQL_ERRORS"
run_case AC3-missing-label 1 INCOMPLETE "INCOMPLETE: MISSING_LABEL"
run_case AC3-count 1 INCOMPLETE "INCOMPLETE: COUNT_MISMATCH"
run_case AC3-lookup 1 INCOMPLETE "INCOMPLETE: UNRESOLVED_LOOKUP"
run_case AC3-page-cap 1 INCOMPLETE "INCOMPLETE: PAGE_CAP" -- --page-cap 1

echo "# G-MOVE: ratio ≤ max is GREEN even with a moved top blocker"
run_case G-MOVE 0 GREEN "3/10"

echo "# moved truth table"
run_case TT-closed 0 YELLOW "ClosedEvent"
run_case TT-reopened 0 YELLOW "ReopenedEvent"
run_case TT-xref-merged 0 YELLOW "merged-pr"
run_case TT-connected-merged 0 YELLOW "ConnectedEvent"
run_case TT-xref-open-pr 0 RED "#161 lastMovedAt"
run_case TT-xref-issue 0 RED "#161 lastMovedAt"
run_case TT-comment-bot 0 RED "#161 lastMovedAt"
run_case TT-labeled 0 RED "#161 lastMovedAt"
run_case TT-unlabeled 0 RED "#161 lastMovedAt"
run_case TT-renamed 0 RED "#161 lastMovedAt"
run_case TT-assigned 0 RED "#161 lastMovedAt"
run_case TT-before-window 0 RED "#161 lastMovedAt"
run_case TT-ref-reach 0 YELLOW "ReferencedEvent"
run_case TT-ref-unreach 0 RED "#161 lastMovedAt"

echo "# AbortSignal.timeout actually fires"
to_out=$(SENSOR_URL="$SENSOR_URL" node --input-type=module <<'JS'
const { graphqlRequest, INCOMPLETE } = await import(process.env.SENSOR_URL);
const started = Date.now();
const r = await Promise.race([
  graphqlRequest({
    fetchImpl: async (_url, init) => {
      if (!(init && init.signal)) throw new Error("signal missing");
      return await new Promise((_, reject) => {
        const fail = () => {
          const e = new Error("aborted");
          e.name = "TimeoutError";
          reject(init.signal.reason || e);
        };
        if (init.signal.aborted) fail();
        else init.signal.addEventListener("abort", fail, { once: true });
      });
    },
    token: "x",
    timeoutMs: 80,
    query: "query { __typename }",
    variables: {},
  }),
  new Promise((_, reject) =>
    setTimeout(() => reject(new Error("watchdog: AbortSignal.timeout did not fire")), 1000)
  ),
]);
if (r.complete !== false || r.incompleteReason !== INCOMPLETE.TIMEOUT) {
  throw new Error("want TIMEOUT got " + JSON.stringify(r));
}
if (Date.now() - started > 2000) throw new Error("timeout took too long");
process.stdout.write("fired\n");
JS
)
to_rc=$?
if [[ "$to_rc" -eq 0 ]] && has_f "$to_out" "fired"; then
  ok "AbortSignal.timeout(80) aborts graphqlRequest as TIMEOUT"
else
  bad "AbortSignal.timeout fire (rc=$to_rc out=$to_out)"
fi

echo "# mutation: INCOMPLETE always wins"
SENSOR="$SENSOR" MUT1="$MUT1" ARGS="$REPO_ROOT/scripts/lib/args.mjs" node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const src = readFileSync(process.env.SENSOR, "utf8");
let next = src.replace(
  /\/\/ VERDICT_PRECEDENCE_INCOMPLETE_WINS[\s\S]*?\/\/ VERDICT_PRECEDENCE_INCOMPLETE_WINS_END\n/,
  "/* mutated: incomplete check removed */\n"
);
if (next === src) {
  console.error("INCOMPLETE marker not found");
  process.exit(2);
}
next = next.replaceAll(
  "from \"./lib/args.mjs\"",
  "from \"" + pathToFileURL(process.env.ARGS).href + "\""
);
writeFileSync(process.env.MUT1, next);
JS
if [[ $? -eq 0 ]]; then
  ok "mutation 1 applied (INCOMPLETE-first removed)"
else
  bad "mutation 1 did not apply"
fi
mut1_out=$(node "$MUT1" --fixture "$ROOT/F7.json" --now "$NOW" --config "$CFG" 2>"$ROOT/mut1.err")
mut1_rc=$?
if has "$mut1_out" "^INCOMPLETE"; then
  bad "mutation 1 still INCOMPLETE (check is not load-bearing): $mut1_out"
else
  ok "mutation 1: F7 is no longer INCOMPLETE (got $(printf '%s' "$mut1_out" | tr '\n' '|') rc=$mut1_rc)"
fi
if has "$mut1_out" "^RED "; then
  ok "mutation 1: F7 falls through to RED without the INCOMPLETE gate"
else
  bad "mutation 1 expected RED, got $(printf '%s' "$mut1_out" | tr '\n' '|')"
fi
# control: unmutated F7 stays INCOMPLETE
ctrl7=$(node "$SENSOR" --fixture "$ROOT/F7.json" --now "$NOW" --config "$CFG" 2>/dev/null)
if has "$ctrl7" "^INCOMPLETE: HAS_NEXT_PAGE"; then
  ok "mutation 1 control: unmutated F7 still INCOMPLETE"
else
  bad "mutation 1 control drifted: $ctrl7"
fi

echo "# mutation: RED rule is load-bearing (quiet high ratio is not GREEN)"
SENSOR="$SENSOR" MUT2="$MUT2" ARGS="$REPO_ROOT/scripts/lib/args.mjs" node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const src = readFileSync(process.env.SENSOR, "utf8");
let next = src.replace(
  /\/\/ VERDICT_PRECEDENCE_RED[\s\S]*?\/\/ VERDICT_PRECEDENCE_RED_END\n/,
  "/* mutated: RED rule removed */\n"
);
if (next === src) {
  console.error("RED marker not found");
  process.exit(2);
}
next = next.replaceAll(
  "from \"./lib/args.mjs\"",
  "from \"" + pathToFileURL(process.env.ARGS).href + "\""
);
writeFileSync(process.env.MUT2, next);
JS
if [[ $? -eq 0 ]]; then
  ok "mutation 2 applied (RED rule removed)"
else
  bad "mutation 2 did not apply"
fi
mut2_out=$(node "$MUT2" --fixture "$ROOT/F1.json" --now "$NOW" --config "$CFG" 2>/dev/null)
if has "$mut2_out" "^GREEN "; then
  ok "mutation 2: F1 becomes GREEN without the RED rule"
else
  bad "mutation 2 expected GREEN, got $(printf '%s' "$mut2_out" | tr '\n' '|')"
fi
ctrl1=$(node "$SENSOR" --fixture "$ROOT/F1.json" --now "$NOW" --config "$CFG" 2>/dev/null)
if has "$ctrl1" "^RED "; then
  ok "mutation 2 control: unmutated F1 still RED"
else
  bad "mutation 2 control drifted: $ctrl1"
fi

echo "# mutation: YELLOW requires ratio > max (G-MOVE stays GREEN)"
SENSOR="$SENSOR" MUT3="$MUT3" ARGS="$REPO_ROOT/scripts/lib/args.mjs" node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const src = readFileSync(process.env.SENSOR, "utf8");
let next = src.replace(
  "if (ratio > config.blockedRatioMax && snapshot.moved.length > 0)",
  "if (snapshot.moved.length > 0)"
);
if (next === src) {
  console.error("YELLOW ratio guard not found");
  process.exit(2);
}
next = next.replaceAll(
  "from \"./lib/args.mjs\"",
  "from \"" + pathToFileURL(process.env.ARGS).href + "\""
);
writeFileSync(process.env.MUT3, next);
JS
if [[ $? -eq 0 ]]; then
  ok "mutation 3 applied (YELLOW ignores ratio)"
else
  bad "mutation 3 did not apply"
fi
mut3_out=$(node "$MUT3" --fixture "$ROOT/G-MOVE.json" --now "$NOW" --config "$CFG" 2>/dev/null)
if has "$mut3_out" "^YELLOW "; then
  ok "mutation 3: G-MOVE becomes YELLOW if YELLOW is checked without the ratio guard"
else
  bad "mutation 3 expected YELLOW, got $(printf '%s' "$mut3_out" | tr '\n' '|')"
fi
ctrlg=$(node "$SENSOR" --fixture "$ROOT/G-MOVE.json" --now "$NOW" --config "$CFG" 2>/dev/null)
if has "$ctrlg" "^GREEN "; then
  ok "mutation 3 control: unmutated G-MOVE still GREEN"
else
  bad "mutation 3 control drifted: $ctrlg"
fi

echo "backlog-health.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
