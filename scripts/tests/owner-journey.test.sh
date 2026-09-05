#!/usr/bin/env bash
# owner-journey.test.sh — state, persistence, safety, copy, and mutation checks
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PROTOTYPE_DIR="${OWNER_JOURNEY_PROTOTYPE_DIR:-$ROOT/prototypes/owner-journey}"
APP="$PROTOTYPE_DIR/app.js"
HTML="$PROTOTYPE_DIR/index.html"
CSS="$PROTOTYPE_DIR/styles.css"
README="$PROTOTYPE_DIR/README.md"

for required in "$APP" "$HTML" "$CSS" "$README"; do
  if [[ ! -f "$required" ]]; then
    echo "owner-journey.test.sh: missing $required" >&2
    exit 1
  fi
done

APP_PATH="$APP" HTML_PATH="$HTML" CSS_PATH="$CSS" README_PATH="$README" node <<'NODE'
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");

const appPath = process.env.APP_PATH;
const htmlPath = process.env.HTML_PATH;
const cssPath = process.env.CSS_PATH;
const readmePath = process.env.README_PATH;
delete require.cache[require.resolve(appPath)];
const model = require(appPath);
const appSource = fs.readFileSync(appPath, "utf8");
const htmlSource = fs.readFileSync(htmlPath, "utf8");
const cssSource = fs.readFileSync(cssPath, "utf8");
const readmeSource = fs.readFileSync(readmePath, "utf8");

let assertions = 0;
function equal(actual, expected, message) {
  assert.equal(actual, expected, message);
  assertions += 1;
}
function deepEqual(actual, expected, message) {
  assert.deepEqual(actual, expected, message);
  assertions += 1;
}
function same(actual, expected, message) {
  assert.strictEqual(actual, expected, message);
  assertions += 1;
}
function ok(value, message) {
  assert.ok(value, message);
  assertions += 1;
}

class MemoryStorage {
  constructor(entries) {
    this.values = new Map(Object.entries(entries || {}));
    this.removed = [];
  }
  getItem(key) {
    return this.values.has(key) ? this.values.get(key) : null;
  }
  setItem(key, value) {
    this.values.set(key, String(value));
  }
  removeItem(key) {
    this.removed.push(key);
    this.values.delete(key);
  }
}

function unavailableStorage(method) {
  return {
    getItem() {
      if (method === "get") throw new Error("unavailable");
      return null;
    },
    setItem() {
      throw new Error("unavailable");
    },
    removeItem() {
      if (method === "remove") throw new Error("unavailable");
    }
  };
}

const projectId = model.PROJECTS[0].id;
const request = "Make account sign-up clearer.";
const feedback = "Keep the clearer heading.";

equal(model.STORAGE_KEY, "gibson.owner-journey-prototype.local.v1", "storage key is namespaced");
equal(model.STORAGE_SCHEMA, model.STORAGE_KEY, "schema and key intentionally match");
equal(model.REQUEST_LIMIT, 4096, "request limit is fixed");
equal(model.FEEDBACK_LIMIT, 2048, "feedback limit is fixed");
equal(model.BINDING_LIMIT, 256, "binding limit is fixed");
deepEqual(
  model.WORK_STAGES,
  ["understanding", "planning", "building", "checking", "ready_for_review"],
  "work stages are closed and ordered"
);

let state = model.initialState();
equal(state.screen, "connect", "journey starts at connect");
state = model.transition(state, { type: "select_project", projectId });
equal(state.screen, "readiness", "project selection opens readiness");
state = model.transition(state, { type: "continue" });
equal(state.screen, "request", "readiness continues to request");
state = model.transition(state, { type: "create_blueprint", request });
equal(state.screen, "blueprint", "valid request creates blueprint");
equal(state.request, request, "request stays data in memory");
state = model.transition(state, { type: "start_demo" });
equal(state.screen, "work", "blueprint starts work demonstration");
equal(state.workStage, "understanding", "work starts at understanding");
for (const expected of ["planning", "building", "checking", "ready_for_review"]) {
  state = model.transition(state, { type: "advance_work" });
  equal(state.workStage, expected, `work advances only to ${expected}`);
}
state = model.transition(state, { type: "open_preview" });
equal(state.screen, "preview", "final work stage opens preview");
state = model.transition(state, { type: "submit_feedback", feedback });
equal(state.screen, "preview", "feedback stays on preview");
equal(state.feedback, feedback, "feedback stays in memory");
state = model.transition(state, { type: "continue" });
equal(state.screen, "decision", "preview continues to decision");
const waiting = model.transition(state, { type: "wait" });
equal(waiting.screen, "decision", "wait stays on decision");
ok(waiting.waitNotice.includes("Nothing changes"), "wait explains safe behavior");
state = model.transition(waiting, { type: "approve_demo" });
equal(state.screen, "result", "approval completes only the demonstration");
equal(model.RESULT_COPY, "Demo complete. No code was changed or deployed.", "result is exact and bounded");

const backReadiness = model.transition(
  model.transition(model.initialState(), { type: "select_project", projectId }),
  { type: "back" }
);
equal(backReadiness.screen, "connect", "readiness back returns to connect");

let backState = model.transition(model.initialState(), { type: "select_project", projectId });
backState = model.transition(backState, { type: "continue" });
equal(model.transition(backState, { type: "back" }).screen, "readiness", "request back returns to readiness");
backState = model.transition(backState, { type: "create_blueprint", request });
equal(model.transition(backState, { type: "back" }).screen, "request", "blueprint back returns to request");
backState = model.transition(backState, { type: "start_demo" });
for (let index = 0; index < 4; index += 1) {
  backState = model.transition(backState, { type: "advance_work" });
}
backState = model.transition(backState, { type: "open_preview" });
const workAgain = model.transition(backState, { type: "back" });
equal(workAgain.screen, "work", "preview back returns to work");
equal(workAgain.workStage, "ready_for_review", "preview back restores final work stage");
backState = model.transition(backState, { type: "continue" });
equal(model.transition(backState, { type: "back" }).screen, "preview", "decision back returns to preview");

const actionSamples = Object.freeze({
  select_project: { type: "select_project", projectId },
  continue: { type: "continue" },
  back: { type: "back" },
  create_blueprint: { type: "create_blueprint", request },
  start_demo: { type: "start_demo" },
  advance_work: { type: "advance_work" },
  open_preview: { type: "open_preview" },
  submit_feedback: { type: "submit_feedback", feedback },
  approve_demo: { type: "approve_demo" },
  wait: { type: "wait" }
});

const representativeStates = [
  { state: model.initialState(), legal: ["select_project"] },
  { state: { ...model.initialState(), screen: "readiness", projectId }, legal: ["continue", "back"] },
  { state: { ...model.initialState(), screen: "request", projectId }, legal: ["create_blueprint", "back"] },
  { state: { ...model.initialState(), screen: "blueprint", projectId, request }, legal: ["start_demo", "back"] },
  { state: { ...model.initialState(), screen: "work", projectId, request, workStage: "understanding" }, legal: ["advance_work"] },
  { state: { ...model.initialState(), screen: "work", projectId, request, workStage: "ready_for_review" }, legal: ["open_preview"] },
  { state: { ...model.initialState(), screen: "preview", projectId, request }, legal: ["submit_feedback", "continue", "back"] },
  { state: { ...model.initialState(), screen: "decision", projectId, request }, legal: ["approve_demo", "wait", "back"] },
  { state: { ...model.initialState(), screen: "result", projectId, request }, legal: [] }
];

for (const entry of representativeStates) {
  for (const [type, action] of Object.entries(actionSamples)) {
    if (!entry.legal.includes(type)) {
      same(model.transition(entry.state, action), entry.state, `${entry.state.screen} rejects ${type}`);
    }
  }
}

const invalidProject = model.initialState();
same(
  model.transition(invalidProject, { type: "select_project", projectId: "attacker/private" }),
  invalidProject,
  "unknown project fails closed"
);
const emptyRequest = { ...model.initialState(), screen: "request", projectId };
same(
  model.transition(emptyRequest, { type: "create_blueprint", request: "   " }),
  emptyRequest,
  "blank request fails closed"
);
same(
  model.transition(emptyRequest, { type: "create_blueprint", request: "é".repeat(2049) }),
  emptyRequest,
  "oversized UTF-8 request fails closed"
);
equal(model.validateRequest("é".repeat(2048)).ok, true, "request accepts exact UTF-8 boundary");
equal(model.validateRequest("é".repeat(2048) + "a").ok, false, "request rejects one byte over boundary");
equal(model.validateFeedback("😀".repeat(512)).ok, true, "feedback accepts exact UTF-8 boundary");
equal(model.validateFeedback("😀".repeat(512) + "a").ok, false, "feedback rejects one byte over boundary");

const hostile = '<img src=x onerror="alert(1)"><script>bad()</script>';
const hostileBlueprint = model.transition(emptyRequest, { type: "create_blueprint", request: hostile });
equal(hostileBlueprint.request, hostile, "hostile request remains inert text data");
const hostilePreview = { ...hostileBlueprint, screen: "preview" };
equal(
  model.transition(hostilePreview, { type: "submit_feedback", feedback: hostile }).feedback,
  hostile,
  "hostile feedback remains inert text data"
);

const storage = new MemoryStorage({ "unrelated.preference": "keep-me" });
deepEqual(model.persistBinding(storage, projectId), { ok: true, notice: "" }, "allowlisted binding persists");
equal(
  storage.getItem(model.STORAGE_KEY),
  JSON.stringify({ schema: model.STORAGE_SCHEMA, projectId }),
  "persistence has the exact closed shape"
);
equal(storage.values.size, 2, "persistence touches no unrelated key");
const hydrated = model.hydrateBinding(storage);
equal(hydrated.screen, "request", "valid binding hydrates only to request");
equal(hydrated.projectId, projectId, "valid binding restores project id");
equal(hydrated.request, "", "request never hydrates");
equal(hydrated.feedback, "", "feedback never hydrates");
equal(hydrated.waitNotice, "", "decision never hydrates");
deepEqual(model.discardBinding(storage), { ok: true, notice: "" }, "reset clears binding");
equal(storage.getItem(model.STORAGE_KEY), null, "prototype key removed");
equal(storage.getItem("unrelated.preference"), "keep-me", "reset preserves unrelated storage");
deepEqual(storage.removed, [model.STORAGE_KEY], "reset removes exactly one namespaced key");

for (const invalidRaw of [
  "{",
  JSON.stringify({ schema: "unknown", projectId }),
  JSON.stringify({ schema: model.STORAGE_SCHEMA, projectId: "unknown/project" }),
  JSON.stringify({ schema: model.STORAGE_SCHEMA, projectId, request: hostile }),
  JSON.stringify({ projectId, schema: model.STORAGE_SCHEMA }),
  "x".repeat(257)
]) {
  const invalidStorage = new MemoryStorage({ [model.STORAGE_KEY]: invalidRaw });
  const safe = model.hydrateBinding(invalidStorage);
  equal(safe.screen, "connect", "invalid binding returns to connect");
  ok(safe.notice.length > 0, "invalid binding provides accessible notice copy");
  equal(invalidStorage.getItem(model.STORAGE_KEY), null, "invalid binding is cleared");
}

const unavailableHydration = model.hydrateBinding(unavailableStorage("get"));
equal(unavailableHydration.screen, "connect", "unavailable storage hydrates to connect");
ok(unavailableHydration.notice.length > 0, "unavailable storage gives notice");
const hostileHost = {};
Object.defineProperty(hostileHost, "localStorage", {
  get() {
    throw new Error("blocked by browser privacy mode");
  }
});
const guardedStorage = model.resolveStorage(hostileHost);
equal(model.hydrateBinding(guardedStorage).screen, "connect", "throwing storage getter is guarded");
ok(model.hydrateBinding(guardedStorage).notice.length > 0, "throwing storage getter gives notice");
equal(model.persistBinding(unavailableStorage("set"), projectId).ok, false, "failed storage write fails closed");
equal(model.discardBinding(unavailableStorage("remove")).ok, false, "failed storage reset is reported");
equal(model.persistBinding(new MemoryStorage(), "unknown/project").ok, false, "unknown project is never persisted");

for (const heading of [
  "Connect a project",
  "Review the read-only check",
  "Describe your request",
  "Review the blueprint",
  "Follow the work",
  "Review the preview",
  "Make the decision",
  "Release result"
]) {
  ok(appSource.includes(heading), `required heading present: ${heading}`);
}

for (const field of [
  "What I'm asking",
  "What it does",
  "Why",
  "Risks / undo",
  "Recommendation",
  "Safe wait",
  "Destination",
  "Evidence status"
]) {
  ok(appSource.includes(field), `decision field present: ${field}`);
}

ok(htmlSource.includes("Interactive prototype · No GitHub connection · No code changes."), "persistent boundary label is present");
ok(appSource.includes("Simulation only"), "screen-level simulation labels are present");
ok(appSource.includes("Simulated check"), "readiness is explicitly simulated");
ok(appSource.includes(model.RESULT_COPY), "exact result wording is rendered");
ok(readmeSource.includes("does not connect to GitHub"), "README states the product boundary");
ok(!/\b(?:Shipped|Verified|Live)\b[.!]/.test(appSource), "no unqualified real-world completion status exists");
ok(!appSource.includes("innerHTML"), "user-facing implementation never uses markup injection");
ok(appSource.includes("textContent"), "user-facing implementation uses text content rendering");

const forbiddenJavaScript = [
  /\bfetch\s*\(/,
  /\bXMLHttpRequest\b/,
  /\bsendBeacon\b/,
  /\bWebSocket\b/,
  /\bEventSource\b/,
  /\bserviceWorker\b/,
  /\bnew\s+Worker\b/,
  /\bimport\s*\(/,
  /\bimportScripts\b/,
  /\bwindow\.open\b/,
  /\blocation\s*=/,
  /\blocation\.(?:href|assign|replace)\b/
];
for (const pattern of forbiddenJavaScript) {
  ok(!pattern.test(appSource), `forbidden JavaScript surface absent: ${pattern}`);
}

const forbiddenHtml = [
  /<(?:form|iframe|object|embed|audio|video|source|track)\b/i,
  /https?:/i,
  /(?:^|["'(\s])\/\//m,
  /(?:mailto|tel):/i
];
for (const pattern of forbiddenHtml) {
  ok(!pattern.test(htmlSource), `forbidden HTML surface absent: ${pattern}`);
}
ok(!/@import\b/i.test(cssSource), "CSS imports are absent");
ok(!/url\s*\(\s*["']?(?:https?:|\/\/)/i.test(cssSource), "remote CSS resources are absent");
ok(!/<a\b[^>]+href=["'](?:https?:|\/\/|mailto:|tel:)/i.test(htmlSource), "external anchors are absent");

equal(model.JOURNEY.length, 8, "journey has eight explicit states");
equal(Object.keys(model.HEADINGS).length, 8, "each state has one heading");
equal(model.transition(state, { type: "reset" }).screen, "connect", "reset is legal from result");

console.log(`owner-journey model/static checks: ${assertions} assertions`);
NODE

if [[ "${OWNER_JOURNEY_MUTATION_RUN:-0}" == "1" ]]; then
  exit 0
fi

MUTATION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gibson-owner-journey-mutations.XXXXXX")
cleanup() {
  rm -rf -- "$MUTATION_DIR"
}
trap cleanup EXIT

run_witness() {
  local name="$1"
  local target="$2"
  local expression="$3"
  local case_dir="$MUTATION_DIR/$name"
  mkdir -p "$case_dir"
  cp "$APP" "$HTML" "$CSS" "$README" "$case_dir/"
  perl -0pi -e "$expression" "$case_dir/$target"
  if cmp -s "$PROTOTYPE_DIR/$target" "$case_dir/$target"; then
    echo "owner-journey.test.sh: mutation did not apply: $name" >&2
    exit 1
  fi
  if OWNER_JOURNEY_PROTOTYPE_DIR="$case_dir" OWNER_JOURNEY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "owner-journey.test.sh: mutation survived: $name" >&2
    exit 1
  fi
  echo "  mutation caught — $name"
}

run_witness \
  "direct-result-transition" \
  "app.js" \
  's/screen: "blueprint", request: requestCheck\.value/screen: "result", request: requestCheck.value/'
run_witness \
  "result-hydration" \
  "app.js" \
  's/return evolve\(initialState\(\), \{ screen: "request", projectId: projectId \}\);/return evolve(initialState(), { screen: "result", projectId: projectId });/'
run_witness \
  "freeform-persistence" \
  "app.js" \
  's/JSON\.stringify\(\{ schema: STORAGE_SCHEMA, projectId: projectId \}\)/JSON.stringify({ schema: STORAGE_SCHEMA, projectId: projectId, request: "persisted" })/'
run_witness \
  "network-surface" \
  "app.js" \
  's/\A/void fetch();\n/'
run_witness \
  "external-navigation" \
  "index.html" \
  's#<body>#<body><a href="https://example.invalid">Leave</a>#'
run_witness \
  "missing-boundary" \
  "index.html" \
  's/Interactive prototype · No GitHub connection · No code changes\./Product workspace./'
run_witness \
  "markup-injection" \
  "app.js" \
  's/screenRoot\.replaceChildren\(renderer\(\)\);/screenRoot.innerHTML = ""; screenRoot.appendChild(renderer());/'
run_witness \
  "unqualified-result" \
  "app.js" \
  's/Demo complete\. No code was changed or deployed\./Shipped./g'

echo "owner-journey.test.sh: PASS — model, trust boundaries, static UX contract, and 8 mutation witnesses"
