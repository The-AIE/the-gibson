#!/usr/bin/env bash
# owner-journey.test.sh — sensors for the owner-journey prototype (issue #348)
#
# WHY
#   The prototype's entire value is that its closed-shape contract actually
#   holds: every legal transition works, every illegal one fails closed, a
#   tampered or oversized persisted value never becomes a workflow state, and
#   no network/DOM-injection channel exists anywhere in the three static
#   files. This suite tests the SAME `app.js` the browser loads (via Node's
#   `require()`, per the contract's own requirement that the browser script
#   expose its pure state model through CommonJS) rather than a
#   reimplementation of its logic, plus static scans of the markup and
#   stylesheet for the forbidden channels the issue enumerates.
#
#   A handful of checks below are mutation witnesses (AC10): they run the
#   exact same check function against a deliberately broken copy of the real
#   file and assert the check NOW fails. A check that still passes against a
#   mutant it's supposed to catch is a vacuous sensor — this proves each one
#   isn't.
#
# USAGE
#   scripts/tests/owner-journey.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
PROTO_DIR="$REPO_ROOT/prototypes/owner-journey"
APP_JS="$PROTO_DIR/app.js"
INDEX_HTML="$PROTO_DIR/index.html"
STYLES_CSS="$PROTO_DIR/styles.css"
README_MD="$PROTO_DIR/README.md"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

for f in "$APP_JS" "$INDEX_HTML" "$STYLES_CSS" "$README_MD"; do
  [[ -f "$f" ]] || { echo "owner-journey.test.sh: missing required file: $f" >&2; exit 2; }
done

command -v node >/dev/null 2>&1 || { echo "owner-journey.test.sh: node is required" >&2; exit 2; }

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/owner-journey-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

# =============================================================================
# Section 1 — pure state model, exercised through Node's require() of the
# real app.js (not a copy, not a reimplementation).
# =============================================================================
echo "pure state model (Node, via require of the real app.js)"

NODE_SCRIPT="$TMP_DIR/assertions.js"
cat > "$NODE_SCRIPT" <<'NODEEOF'
'use strict';
const APP = require(process.env.OJ_APP_PATH);

const lines = [];
function ok(desc) { lines.push('OK\t' + desc); }
function bad(desc, extra) { lines.push('FAIL\t' + desc + (extra !== undefined ? ' :: ' + JSON.stringify(extra) : '')); }
function check(desc, cond, extra) { cond ? ok(desc) : bad(desc, extra); }
function eq(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
// A deep snapshot taken BEFORE calling transition(), so a reducer that
// mutates its input object in place and returns that same reference cannot
// make an eq(result, originalReference) comparison vacuously true (Codex
// round-2 finding: `eq(APP.transition(s, action, payload), s)` compares the
// result against the very reference that may have just been mutated, so an
// in-place mutation makes the check trivially "pass"). Comparing against a
// snapshot taken first is immune to that.
function snapshot(state) { return JSON.parse(JSON.stringify(state)); }

// ---- constants ----
check('RESULT_TEXT is the exact required sentence', APP.RESULT_TEXT === 'Demo complete. No code was changed or deployed.', APP.RESULT_TEXT);
check('exactly 3 allowlisted example projects', Array.isArray(APP.ALLOWLISTED_PROJECTS) && APP.ALLOWLISTED_PROJECTS.length === 3);
check('WORK_SUBSTAGES is the exact ordered set', eq(APP.WORK_SUBSTAGES, ['understanding', 'planning', 'building', 'checking', 'ready_for_review']));
check('STORAGE_MAX_BYTES is 256', APP.STORAGE_MAX_BYTES === 256);
check('REQUEST_MAX_BYTES is 4096', APP.REQUEST_MAX_BYTES === 4096);
check('FEEDBACK_MAX_BYTES is 2048', APP.FEEDBACK_MAX_BYTES === 2048);

// ---- utf8ByteLength: the contract's own worked cases ----
check('utf8ByteLength: ascii', APP.utf8ByteLength('abc') === 3);
check('utf8ByteLength: 2-byte codepoint (e-acute)', APP.utf8ByteLength('café') === 5);
check('utf8ByteLength: 4-byte codepoint (emoji)', APP.utf8ByteLength('😀') === 4);
check('utf8ByteLength differs from .length for multi-byte text (sanity on the boundary math itself)', 'é'.length !== APP.utf8ByteLength('é'));

// ---- exact UTF-8 boundaries: request (ASCII AND multi-byte, so a validator
// that switches to .length instead of utf8ByteLength cannot pass both) ----
check('request text at exactly 4096 ASCII bytes is valid', APP.isValidRequestText('a'.repeat(4096)) === true);
check('request text at 4097 ASCII bytes is invalid', APP.isValidRequestText('a'.repeat(4097)) === false);
// 1024 emoji = 4096 UTF-8 bytes (4 bytes each) but only 2048 UTF-16 code
// units — a validator using .length would wrongly accept 1025+ of them.
check('request text at exactly 1024 emoji (4096 UTF-8 bytes, 2048 .length) is valid', APP.isValidRequestText('\u{1F600}'.repeat(1024)) === true);
check('request text at 1025 emoji (4100 UTF-8 bytes) is invalid even though .length is only 2050', APP.isValidRequestText('\u{1F600}'.repeat(1025)) === false);
check('blank request text is invalid', APP.isValidRequestText('   ') === false);
check('non-string request text is invalid', APP.isValidRequestText(null) === false);

// ---- exact UTF-8 boundaries: feedback (same ASCII + multi-byte pairing) ----
check('feedback text at exactly 2048 ASCII bytes is valid', APP.isValidFeedbackText('b'.repeat(2048)) === true);
check('feedback text at 2049 ASCII bytes is invalid', APP.isValidFeedbackText('b'.repeat(2049)) === false);
// 512 emoji = 2048 UTF-8 bytes but only 1024 .length.
check('feedback text at exactly 512 emoji (2048 UTF-8 bytes, 1024 .length) is valid', APP.isValidFeedbackText('\u{1F600}'.repeat(512)) === true);
check('feedback text at 513 emoji (2052 UTF-8 bytes) is invalid even though .length is only 1026', APP.isValidFeedbackText('\u{1F600}'.repeat(513)) === false);
check('empty feedback text is invalid', APP.isValidFeedbackText('') === false);

// ---- storage write stays well under its own bound ----
check('serializePersisted output is <= 256 UTF-8 bytes', APP.utf8ByteLength(APP.serializePersisted('demo-storefront')) <= APP.STORAGE_MAX_BYTES);

// ---- full legal path across every state, in order ----
(function () {
  let s = APP.initialState();
  check('initial state is connect', s.screen === 'connect');
  s = APP.transition(s, 'select_project', 'demo-storefront');
  check('connect + select_project(allowlisted) -> readiness', s.screen === 'readiness' && s.projectId === 'demo-storefront');
  s = APP.transition(s, 'continue');
  check('readiness + continue -> request', s.screen === 'request');
  s = APP.transition(s, 'create_blueprint', 'Make the demo nicer.');
  check('request + create_blueprint(valid) -> blueprint', s.screen === 'blueprint' && s.requestText === 'Make the demo nicer.');
  s = APP.transition(s, 'start_demo');
  check('blueprint + start_demo -> work:understanding', s.screen === 'work:understanding');
  ['planning', 'building', 'checking', 'ready_for_review'].forEach(function (next) {
    s = APP.transition(s, 'advance_work');
    check('advance_work reaches work:' + next, s.screen === 'work:' + next);
  });
  s = APP.transition(s, 'open_preview');
  check('work:ready_for_review + open_preview -> preview', s.screen === 'preview');
  s = APP.transition(s, 'submit_feedback', 'Looks good.');
  check('preview + submit_feedback(valid) stays preview and records it', s.screen === 'preview' && eq(s.feedback, ['Looks good.']));
  s = APP.transition(s, 'continue');
  check('preview + continue -> decision', s.screen === 'decision');
  s = APP.transition(s, 'wait');
  check('decision + wait stays decision with a safe-wait notice', s.screen === 'decision' && typeof s.notice === 'string' && s.notice.length > 0);
  s = APP.transition(s, 'approve_demo');
  check('decision + approve_demo -> result', s.screen === 'result');
  s = APP.transition(s, 'reset');
  check('reset from result returns to a fresh connect state', s.screen === 'connect' && s.projectId === null && s.requestText === null && eq(s.feedback, []));
})();

// ---- every back transition ----
(function () {
  let s = APP.transition(APP.initialState(), 'select_project', 'demo-storefront');
  check('readiness + back -> connect', APP.transition(s, 'back').screen === 'connect');
  s = APP.transition(s, 'continue');
  check('request + back -> readiness', APP.transition(s, 'back').screen === 'readiness');
  s = APP.transition(s, 'create_blueprint', 'x');
  check('blueprint + back -> request', APP.transition(s, 'back').screen === 'request');
  s = APP.transition(s, 'start_demo');
  ['a', 'b', 'c', 'd'].forEach(function () { s = APP.transition(s, 'advance_work'); });
  s = APP.transition(s, 'open_preview');
  check('preview + back -> work:ready_for_review', APP.transition(s, 'back').screen === 'work:ready_for_review');
  s = APP.transition(s, 'continue');
  check('decision + back -> preview', APP.transition(s, 'back').screen === 'preview');
})();

// ---- exhaustive illegal-pair sweep: every screen x every action not in the
// legal table must leave state byte-for-byte unchanged ----
(function () {
  const ALL_SCREENS = ['connect', 'readiness', 'request', 'blueprint', 'work:understanding', 'work:planning', 'work:building', 'work:checking', 'work:ready_for_review', 'preview', 'decision', 'result'];
  const ALL_ACTIONS = ['select_project', 'continue', 'back', 'create_blueprint', 'start_demo', 'advance_work', 'open_preview', 'submit_feedback', 'approve_demo', 'wait', 'bogus_action', ''];
  const LEGAL = {
    'connect|select_project': 1,
    'readiness|continue': 1, 'readiness|back': 1,
    'request|create_blueprint': 1, 'request|back': 1,
    'blueprint|start_demo': 1, 'blueprint|back': 1,
    'work:understanding|advance_work': 1, 'work:planning|advance_work': 1, 'work:building|advance_work': 1, 'work:checking|advance_work': 1,
    'work:ready_for_review|open_preview': 1,
    'preview|submit_feedback': 1, 'preview|continue': 1, 'preview|back': 1,
    'decision|approve_demo': 1, 'decision|wait': 1, 'decision|back': 1
  };
  let checked = 0;
  let allUnchanged = true;
  const failures = [];
  ALL_SCREENS.forEach(function (screen) {
    ALL_ACTIONS.forEach(function (action) {
      const key = screen + '|' + action;
      if (LEGAL[key]) return;
      checked += 1;
      const before = { screen: screen, projectId: 'demo-storefront', requestText: 'x', feedback: ['y'], notice: null };
      const expected = snapshot(before); // taken BEFORE the call: see the `snapshot()` comment above
      const after = APP.transition(before, action, 'demo-storefront');
      if (!eq(expected, after)) {
        allUnchanged = false;
        failures.push(key + ' -> ' + JSON.stringify(after));
      }
    });
  });
  check('every illegal screen/action pair (' + checked + ' checked) leaves state unchanged', allUnchanged, failures.slice(0, 5));
})();

// ---- invalid payload on an otherwise-legal action must also fail closed.
// Each assertion compares the FULL state object, not just `.screen` — a
// mutant that keeps the same screen but corrupts projectId/requestText/
// feedback on an invalid payload must still be caught. Every call below
// gets its OWN freshly-built state object (never reused across checks) and
// the expected value is a `snapshot()` taken BEFORE transition() runs, so a
// reducer that mutated its input in place and returned that same reference
// cannot make the comparison vacuously true (Codex round-2 finding: the
// previous version reused one `s` reference as both the call's input and
// the comparison target, so an in-place `state.feedback.push(...)` mutation
// that then returned `state` unchanged would still read as "unchanged"). ----
(function () {
  function unchanged(state, action, payload) {
    const expected = snapshot(state);
    const after = APP.transition(state, action, payload);
    return eq(expected, after);
  }

  check('select_project with an unlisted id leaves the ENTIRE state unchanged', unchanged({ screen: 'connect', projectId: null, requestText: null, feedback: [], notice: null }, 'select_project', 'not-a-real-id'));
  check('create_blueprint with blank text leaves the entire state unchanged', unchanged({ screen: 'request', projectId: 'demo-storefront', requestText: null, feedback: [], notice: null }, 'create_blueprint', '   '));
  check('create_blueprint with 4097-byte text leaves the entire state unchanged', unchanged({ screen: 'request', projectId: 'demo-storefront', requestText: null, feedback: [], notice: null }, 'create_blueprint', 'a'.repeat(4097)));
  check('start_demo with no request text leaves the entire state unchanged (defense in depth)', unchanged({ screen: 'blueprint', projectId: 'demo-storefront', requestText: null, feedback: [], notice: null }, 'start_demo'));
  check('submit_feedback with blank text leaves the entire state unchanged (records nothing)', unchanged({ screen: 'preview', projectId: 'demo-storefront', requestText: 'x', feedback: [], notice: null }, 'submit_feedback', ''));
  check('submit_feedback with 2049-byte text leaves the entire state unchanged', unchanged({ screen: 'preview', projectId: 'demo-storefront', requestText: 'x', feedback: [], notice: null }, 'submit_feedback', 'z'.repeat(2049)));
})();

// ---- an adversarial reducer that mutates its input in place is itself
// caught by the above (proves the snapshot-based comparison, not just the
// real reducer, is exercised): a hand-written mutating stand-in that pushes
// onto the SAME feedback array and returns the SAME object reference must
// fail `unchanged()`, where the old `eq(result, s)` shape would have missed
// it entirely. ----
(function () {
  function mutatingRejectFeedback(state) {
    state.feedback.push('smuggled in place');
    return state; // same reference, "unchanged" by naive reference/JSON-of-self comparisons
  }
  function unchanged(transitionFn, state, action, payload) {
    const expected = snapshot(state);
    const after = transitionFn(state, action, payload);
    return eq(expected, after);
  }
  const fixture = { screen: 'preview', projectId: 'demo-storefront', requestText: 'x', feedback: [], notice: null };
  check('mutation witness (in-place mutation on rejection): the real transition() truly leaves feedback empty on a rejected submit', unchanged(APP.transition, { screen: 'preview', projectId: 'demo-storefront', requestText: 'x', feedback: [], notice: null }, 'submit_feedback', '') === true);
  check('mutation witness (in-place mutation on rejection): the snapshot-based check catches an in-place-mutating stand-in that the old reference-reusing check would have missed', unchanged(mutatingRejectFeedback, fixture, 'submit_feedback', '') === false);
})();

// ---- hostile HTML is only ever carried as inert data ----
(function () {
  const hostile = '<img src=x onerror=alert(1)>';
  check('a hostile-looking string is still valid request text (it is just bytes)', APP.isValidRequestText(hostile) === true);
  const s = APP.transition({ screen: 'request', projectId: 'demo-storefront', requestText: null, feedback: [], notice: null }, 'create_blueprint', hostile);
  check('hostile HTML is carried through verbatim as inert string data', s.requestText === hostile);
})();

// ---- hydration: only ever connect or request, never any other screen ----
(function () {
  check('hydrate(null) -> connect, no notice (an ordinary first visit)', (function () { const s = APP.hydrate(null); return s.screen === 'connect' && !s.notice; })());
  const good = APP.serializePersisted('demo-storefront');
  check('hydrate(valid persisted value) -> request, with that exact project bound', (function () { const s = APP.hydrate(good); return s.screen === 'request' && s.projectId === 'demo-storefront' && !s.notice; })());
  check('hydrate(malformed JSON) -> connect with an accessible notice', (function () { const s = APP.hydrate('{not json'); return s.screen === 'connect' && !!s.notice; })());
  check('hydrate(wrong schema/"unknown version") -> connect with a notice', (function () { const s = APP.hydrate(JSON.stringify({ schema: 'gibson.owner-journey-prototype.local.v2', projectId: 'demo-storefront' })); return s.screen === 'connect' && !!s.notice; })());
  check('hydrate(unknown repository id) -> connect with a notice', (function () { const s = APP.hydrate(JSON.stringify({ schema: APP.SCHEMA, projectId: 'not-a-real-project' })); return s.screen === 'connect' && !!s.notice; })());
  check('hydrate(unknown/extra key) -> connect with a notice', (function () { const s = APP.hydrate(JSON.stringify({ schema: APP.SCHEMA, projectId: 'demo-storefront', extra: 1 })); return s.screen === 'connect' && !!s.notice; })());
  check('hydrate(missing key) -> connect with a notice', (function () { const s = APP.hydrate(JSON.stringify({ schema: APP.SCHEMA })); return s.screen === 'connect' && !!s.notice; })());
  check('hydrate(array instead of object) -> connect with a notice', (function () { const s = APP.hydrate(JSON.stringify(['not', 'an', 'object'])); return s.screen === 'connect' && !!s.notice; })());
  // A whitespace-padded but otherwise perfectly SHAPE-VALID persisted
  // value: exact schema string, exact 2-key set, an allowlisted project id
  // — the only thing wrong with it is that the raw string is > 256 bytes.
  // This isolates the byte-cap check itself; a validator that dropped the
  // 256-byte check but kept every shape check would still wrongly accept
  // this (unlike the old "corrupt the schema" case, which was rejected for
  // the wrong reason and so proved nothing about the size cap).
  const oversizedButShapeValid = '{"schema":"' + APP.SCHEMA + '",' + ' '.repeat(220) + '"projectId":"demo-storefront"}';
  check('the padded oversized fixture is valid JSON with the exact 2-key shape (sanity on the fixture itself)', (function () { const parsed = JSON.parse(oversizedButShapeValid); return eq(Object.keys(parsed).sort(), ['projectId', 'schema']) && parsed.schema === APP.SCHEMA && parsed.projectId === 'demo-storefront'; })());
  check('the padded oversized fixture really is over 256 UTF-8 bytes (sanity on the fixture itself)', APP.utf8ByteLength(oversizedButShapeValid) > APP.STORAGE_MAX_BYTES);
  check('hydrate(oversized-but-otherwise-shape-valid raw value) -> connect with a notice', (function () { const s = APP.hydrate(oversizedButShapeValid); return s.screen === 'connect' && !!s.notice; })());
  check('hydrateUnavailable() -> connect with a notice (storage itself is broken)', (function () { const s = APP.hydrateUnavailable(); return s.screen === 'connect' && !!s.notice; })());
  // Never any screen other than connect/request from any hydration path.
  [null, good, '{not json', JSON.stringify({ schema: APP.SCHEMA }), JSON.stringify(['x'])].forEach(function (raw) {
    const s = APP.hydrate(raw);
    if (s.screen !== 'connect' && s.screen !== 'request') bad('hydrate() produced an out-of-contract screen: ' + s.screen);
  });
  ok('hydrate() never produces a screen other than connect or request, across every case above');
})();

// ---- allowlist / reset isolation ----
(function () {
  let s = APP.transition(APP.initialState(), 'select_project', 'demo-storefront');
  check('reset clears the bound projectId', APP.transition(s, 'reset').projectId === null);
  s = APP.transition(APP.initialState(), 'select_project', 'demo-support-portal');
  s = APP.transition(s, 'continue');
  s = APP.transition(s, 'create_blueprint', 'x');
  const reset = APP.transition(s, 'reset');
  check('reset from mid-journey clears screen, request text, and feedback together', reset.screen === 'connect' && reset.requestText === null && eq(reset.feedback, []));
})();

// ---- reset from EVERY reachable screen, not just a sample: a regression
// that only handles reset for some screens (e.g. forgets it inside the
// work:* substages, or from preview/decision/result) must be caught here,
// not just from the three screens the earlier check happened to use. ----
(function () {
  function buildJourneyTo(screen) {
    let s = APP.transition(APP.initialState(), 'select_project', 'demo-storefront');
    if (screen === 'connect') return APP.initialState();
    if (screen === 'readiness') return s;
    s = APP.transition(s, 'continue');
    if (screen === 'request') return s;
    s = APP.transition(s, 'create_blueprint', 'x');
    if (screen === 'blueprint') return s;
    s = APP.transition(s, 'start_demo');
    const order = ['understanding', 'planning', 'building', 'checking', 'ready_for_review'];
    const target = screen.indexOf('work:') === 0 ? screen.slice('work:'.length) : null;
    for (let i = 0; i < order.length; i += 1) {
      if (s.screen === 'work:' + order[i] && order[i] === target) return s;
      if (order[i] !== 'understanding') s = APP.transition(s, 'advance_work');
      if (s.screen === 'work:' + order[i] && order[i] === target) return s;
    }
    if (target) return s;
    s = APP.transition(s, 'open_preview');
    if (screen === 'preview') return s;
    s = APP.transition(s, 'continue');
    if (screen === 'decision') return s;
    s = APP.transition(s, 'approve_demo');
    return s; // 'result'
  }
  const EVERY_SCREEN = ['connect', 'readiness', 'request', 'blueprint', 'work:understanding', 'work:planning', 'work:building', 'work:checking', 'work:ready_for_review', 'preview', 'decision', 'result'];
  let allClean = true;
  const problems = [];
  EVERY_SCREEN.forEach(function (screen) {
    const before = buildJourneyTo(screen);
    if (before.screen !== screen) { allClean = false; problems.push('fixture builder reached ' + before.screen + ' instead of ' + screen); return; }
    const after = APP.transition(before, 'reset');
    const isCleanReset = eq(after, APP.initialState());
    if (!isCleanReset) { allClean = false; problems.push('reset from ' + screen + ' produced ' + JSON.stringify(after)); }
  });
  check('reset from every one of the 12 reachable screens produces an identical fresh connect state', allClean, problems.slice(0, 3));
})();

// =====================================================================
// Mutation witnesses A-C (AC10): each proves its check is not vacuous by
// running the SAME assertion shape against a deliberately broken stand-in
// and confirming detection, then re-confirming the REAL module is clean.
// =====================================================================

// Each witness below defines ONE predicate function and runs the IDENTICAL
// function against both the real module and a deliberately broken stand-in.
// The predicate must return true (safe) for the real module and false
// (caught) for the mutant — the same check, not two different assertions —
// which is what actually proves the check is capable of catching the
// mutation it claims to catch (Codex round-1 finding: the previous version
// asserted the mutant's bug existed and separately asserted the real module
// was clean, without ever applying one shared predicate to both).

// A — direct-result transition must not be reachable from any single action.
(function () {
  function mutantTransition(state, action, payload) {
    if (action === 'jump_to_result') return Object.assign({}, state, { screen: 'result' });
    return APP.transition(state, action, payload);
  }
  function noDirectResultJump(transitionFn) {
    // Two SEPARATE initialState() calls (not one shared reference passed
    // in and then compared against itself) — initialState() always returns
    // a fresh object, so `expected` cannot be the same reference `after`
    // even if transitionFn mutated its input in place and returned it.
    const expected = APP.initialState();
    const after = transitionFn(APP.initialState(), 'jump_to_result');
    return eq(expected, after);
  }
  check('predicate "no direct-result jump" passes against the real transition()', noDirectResultJump(APP.transition) === true);
  check('mutation witness (direct-result transition): the SAME predicate catches the mutant', noDirectResultJump(mutantTransition) === false);
})();

// B — hydration must only ever produce connect or request, never result.
(function () {
  function mutantHydrate(rawValue) {
    if (rawValue === 'FORCE_RESULT') return { screen: 'result', projectId: null, requestText: null, feedback: [], notice: null };
    return APP.hydrate(rawValue);
  }
  function hydrationNeverReachesResult(hydrateFn) {
    const out = hydrateFn('FORCE_RESULT');
    return out.screen !== 'result';
  }
  check('predicate "hydration never reaches result" passes against the real hydrate()', hydrationNeverReachesResult(APP.hydrate) === true);
  check('mutation witness (hydration-to-result): the SAME predicate catches the mutant', hydrationNeverReachesResult(mutantHydrate) === false);
})();

// C — free-form persistence (an extra key) must be rejected, not silently accepted.
(function () {
  function mutantIsValidPersisted(parsed) {
    if (!parsed || typeof parsed !== 'object') return false;
    if (parsed.schema !== APP.SCHEMA) return false;
    if (!APP.isValidProjectId(parsed.projectId)) return false;
    return true; // bug: forgot the exact-key-set check
  }
  const withFreeForm = { schema: APP.SCHEMA, projectId: 'demo-storefront', note: 'free-form text that must never persist' };
  function rejectsFreeForm(validatorFn) {
    return validatorFn(withFreeForm) === false;
  }
  check('predicate "rejects an extra key" passes against the real isValidPersisted()', rejectsFreeForm(APP.isValidPersisted) === true);
  check('mutation witness (free-form persistence): the SAME predicate catches the mutant', rejectsFreeForm(mutantIsValidPersisted) === false);
})();

process.stdout.write(lines.join('\n') + '\n');
NODEEOF

OJ_APP_PATH="$APP_JS" node "$NODE_SCRIPT" > "$TMP_DIR/node-out.txt" 2> "$TMP_DIR/node-err.txt"
NODE_RC=$?
if [[ $NODE_RC -ne 0 ]]; then
  bad "pure state model Node script exited $NODE_RC (see stderr below)"
  sed 's/^/    /' "$TMP_DIR/node-err.txt"
else
  while IFS=$'\t' read -r verdict desc; do
    [[ -z "$verdict" ]] && continue
    if [[ "$verdict" == "OK" ]]; then
      ok "$desc"
    else
      bad "$desc"
    fi
  done < "$TMP_DIR/node-out.txt"
fi

# =============================================================================
# Section 2 — static scan of index.html
# =============================================================================
echo
echo "static markup (index.html)"

count_matches() { grep -c -E "$1" "$2" 2>/dev/null || true; }

HEADINGS="Connect Readiness Request Blueprint Work Preview Decision Result"
HEADING_MISS=0
for h in $HEADINGS; do
  grep -qF "<h2>$h</h2>" "$INDEX_HTML" || HEADING_MISS=$((HEADING_MISS + 1))
done
check_count=$(grep -c '<h2>' "$INDEX_HTML")
if [[ "$HEADING_MISS" -eq 0 && "$check_count" -eq 8 ]]; then
  ok "exactly the 8 required state headings are present (Connect..Result)"
else
  bad "expected exactly 8 headings Connect..Result, found $check_count with $HEADING_MISS missing"
fi

ASK_LABELS=("What I'm asking" "What it does" "Why" "Risks/undo" "Recommendation" "Safe-wait behavior" "Destination" "Evidence status")
ASK_MISS=0
for label in "${ASK_LABELS[@]}"; do
  grep -qF "<dt>$label</dt>" "$INDEX_HTML" || ASK_MISS=$((ASK_MISS + 1))
done
[[ "$ASK_MISS" -eq 0 ]] && ok "all 8 Ask Contract fields are present with exact labels" || bad "$ASK_MISS Ask Contract field label(s) missing or misworded"

grep -qF 'no GitHub connection' "$INDEX_HTML" && ok "the product-boundary disclaimer is present in the markup" || bad "product-boundary disclaimer missing from index.html"

SIM_COUNT=$(grep -c 'simulation-label' "$INDEX_HTML")
[[ "$SIM_COUNT" -ge 4 ]] && ok "simulation labels present on readiness/work/preview/decision ($SIM_COUNT found)" || bad "expected at least 4 simulation labels, found $SIM_COUNT"

check_no_form()    { ! grep -qiE '<form[ >]' "$1"; }
check_no_iframe()  { ! grep -qiE '<iframe' "$1"; }
check_no_object()  { ! grep -qiE '<object|<embed' "$1"; }
check_no_media()   { ! grep -qiE '<video|<audio' "$1"; }
check_no_ext_href(){ ! grep -qiE 'href=["'"'"']?(https?:)?//' "$1"; }
check_no_mailto()  { ! grep -qiE 'mailto:|tel:' "$1"; }
check_no_remote()  { ! grep -qiE '(src|href)=["'"'"'](https?:)?//' "$1"; }

check_no_form "$INDEX_HTML" && ok "no <form> element in index.html" || bad "<form> found in index.html"
check_no_iframe "$INDEX_HTML" && ok "no <iframe> in index.html" || bad "<iframe> found in index.html"
check_no_object "$INDEX_HTML" && ok "no <object>/<embed> in index.html" || bad "<object>/<embed> found in index.html"
check_no_media "$INDEX_HTML" && ok "no <video>/<audio> in index.html" || bad "<video>/<audio> found in index.html"
check_no_ext_href "$INDEX_HTML" && ok "no external or protocol-relative anchor href in index.html" || bad "external/protocol-relative href found in index.html"
check_no_mailto "$INDEX_HTML" && ok "no mailto:/tel: link in index.html" || bad "mailto:/tel: link found in index.html"
check_no_remote "$INDEX_HTML" && ok "no remote/protocol-relative script or stylesheet src/href in index.html" || bad "remote/protocol-relative resource reference found in index.html"

# =============================================================================
# Section 3 — static scan of app.js: forbidden JS channels, innerHTML, exact
# result wording, and no unqualified Shipped/Verified/Live claim.
# =============================================================================
echo
echo "static scan (app.js): forbidden channels and wording"

# Deliberately narrow on the location-assignment alternatives (Codex round-2
# finding: an earlier, broader version matched ANY read of `window.location`
# (a plain reference or comparison, not just a mutating assignment) and ANY
# property literally named "location" on an arbitrary object (`\b` matches
# right after a `.`, so `model.location = ...` — nothing to do with browser
# navigation — was a false positive). Only two shapes actually cause
# navigation: assigning the whole `window.location` object, or reassigning
# the bare global `location` identifier directly (not as a property of some
# other object) — both require a literal `=` immediately after, and the bare
# form must NOT be preceded by `.`/alnum/`_` (i.e. it is not somebody's
# `.location` property).
FORBIDDEN_JS_RE='fetch\(|XMLHttpRequest|sendBeacon|WebSocket|EventSource|ServiceWorker|serviceWorker|new[[:space:]]+Worker|importScripts|import\(|window\.open|window\.location[[:space:]]*=[^=]|location\.href|location\.assign|location\.replace|document\.location|(^|[^.[:alnum:]_])location[[:space:]]*=[^=]|\.innerHTML[[:space:]]*='

# Flattens the whole file to one line (newlines -> spaces) before matching,
# so a statement split across lines — e.g.
#   window.location =
#     "https://example.invalid/";
# — is still caught. A plain line-by-line `grep` requires the post-`=`
# character on the SAME line as the `=`, which a reformatted (but still
# executing) assignment can trivially cross (Codex round-3 finding). This
# also hardens every other alternative in FORBIDDEN_JS_RE against the same
# blind spot, not only the location ones.
check_forbidden_js() { ! tr '\n' ' ' < "$1" | grep -qE "$FORBIDDEN_JS_RE"; }

check_forbidden_js "$APP_JS" && ok "no forbidden network/navigation/innerHTML token in app.js" || bad "a forbidden network/navigation/innerHTML token was found in app.js"

grep -qF "'Demo complete. No code was changed or deployed.'" "$APP_JS" && ok "RESULT_TEXT is the exact required sentence in app.js" || bad "exact result sentence not found verbatim in app.js"

UNQUALIFIED_RE='\b(Shipped|Verified|Live)\b'
UNQUALIFIED_HIT=0
for f in "$INDEX_HTML" "$APP_JS" "$README_MD"; do
  grep -qE "$UNQUALIFIED_RE" "$f" && UNQUALIFIED_HIT=1
done
[[ "$UNQUALIFIED_HIT" -eq 0 ]] && ok "no unqualified Shipped/Verified/Live claim anywhere in the prototype" || bad "found an unqualified Shipped/Verified/Live token"

# =============================================================================
# Section 4 — static scan of styles.css
# =============================================================================
echo
echo "static scan (styles.css)"

check_css_clean() {
  ! grep -qiE '@import|url\(\s*["'"'"']?(https?:)?//' "$1"
}
check_css_clean "$STYLES_CSS" && ok "no @import and no remote/protocol-relative url(...) in styles.css" || bad "@import or remote/protocol-relative url(...) found in styles.css"

# =============================================================================
# Section 5 — mutation witnesses D-G (AC10): run the SAME check function
# against a deliberately broken copy of the real file and confirm it now
# fails, proving the grep-based sensor above is not vacuous.
# =============================================================================
echo
echo "mutation witnesses (static channels + wording)"

# D — network/external navigation surface. Covers a network request API AND
# an external-navigation assignment separately (Codex round-1 finding: a
# fetch()-only mutant proves nothing about navigation detection).
check_forbidden_js "$APP_JS" && ok "the real app.js has no forbidden channel to start with (baseline for D)" || bad "the real app.js already trips the forbidden-channel sensor — cannot run mutation witness D"

NET_MUTATIONS=(
  'fetch("https://example.invalid/exfiltrate");'
  'window.location = "https://example.invalid/";'
  $'window.location =\n  "https://example.invalid/";'
  'new WebSocket("wss://example.invalid");'
  'window.open("https://example.invalid/");'
)
NET_ALL_CAUGHT=1
for mutation in "${NET_MUTATIONS[@]}"; do
  mutant_file="$TMP_DIR/app.mutant-net-$(echo "$mutation" | cksum | cut -d' ' -f1).js"
  cp "$APP_JS" "$mutant_file"
  printf '\n%s\n' "$mutation" >> "$mutant_file"
  check_forbidden_js "$mutant_file" && NET_ALL_CAUGHT=0
done
[[ "$NET_ALL_CAUGHT" -eq 1 ]] && ok "mutation witness (network/external-navigation channel): fetch, single-line and multiline window.location assignment, WebSocket, and window.open are each individually detected" || bad "mutation witness (network/external-navigation channel) missed at least one injected channel"

# D2 — false-positive control: ordinary, non-navigating code that merely
# mentions "location" as a property name, a read, or a comparison must NOT
# trip the sensor (Codex round-2 finding: an earlier, broader regex flagged
# `const current = window.location;`, `window.location === cached`,
# `model.location = "local"`, and even a string literal containing the text
# "window.location" — none of which perform navigation).
BENIGN_LOCATION_SNIPPETS=(
  'var current = window.location;'
  'if (window.location === cached) { return; }'
  'model.location = "local";'
  'var msg = "window.location";'
)
BENIGN_ALL_CLEAN=1
for snippet in "${BENIGN_LOCATION_SNIPPETS[@]}"; do
  benign_file="$TMP_DIR/app.benign-net-$(echo "$snippet" | cksum | cut -d' ' -f1).js"
  cp "$APP_JS" "$benign_file"
  printf '\n%s\n' "$snippet" >> "$benign_file"
  check_forbidden_js "$benign_file" || BENIGN_ALL_CLEAN=0
done
[[ "$BENIGN_ALL_CLEAN" -eq 1 ]] && ok "false-positive control: a plain window.location read/comparison, an unrelated .location property, and a string literal all pass cleanly (no navigation is actually performed)" || bad "the forbidden-channel sensor false-positives on ordinary, non-navigating code"

# E — removed simulation disclaimer.
MUTANT_HTML_NODISCLAIMER="$TMP_DIR/index.mutant-nodisclaimer.html"
grep -vF 'no GitHub connection' "$INDEX_HTML" > "$MUTANT_HTML_NODISCLAIMER"
if grep -qF 'no GitHub connection' "$INDEX_HTML" && ! grep -qF 'no GitHub connection' "$MUTANT_HTML_NODISCLAIMER"; then
  ok "mutation witness (removed disclaimer): stripping the boundary banner is detected; the real index.html still has it"
else
  bad "mutation witness (removed disclaimer) did not discriminate real file from mutant"
fi

# F — innerHTML.
MUTANT_JS_INNERHTML="$TMP_DIR/app.mutant-innerhtml.js"
cp "$APP_JS" "$MUTANT_JS_INNERHTML"
printf '\ndocument.getElementById("x").innerHTML = "<b>y</b>";\n' >> "$MUTANT_JS_INNERHTML"
if check_forbidden_js "$APP_JS" && ! check_forbidden_js "$MUTANT_JS_INNERHTML"; then
  ok "mutation witness (innerHTML): an injected innerHTML assignment is detected; the real app.js stays clean"
else
  bad "mutation witness (innerHTML) did not discriminate real file from mutant"
fi

# G — unqualified shipped result.
MUTANT_JS_SHIPPED="$TMP_DIR/app.mutant-shipped.js"
sed "s/Demo complete\\. No code was changed or deployed\\./Shipped./" "$APP_JS" > "$MUTANT_JS_SHIPPED"
REAL_HAS_EXACT=$(grep -cF "'Demo complete. No code was changed or deployed.'" "$APP_JS")
MUTANT_HAS_EXACT=$(grep -cF "'Demo complete. No code was changed or deployed.'" "$MUTANT_JS_SHIPPED")
MUTANT_HAS_SHIPPED=$(grep -cE '\bShipped\b' "$MUTANT_JS_SHIPPED")
if [[ "$REAL_HAS_EXACT" -ge 1 && "$MUTANT_HAS_EXACT" -eq 0 && "$MUTANT_HAS_SHIPPED" -ge 1 ]]; then
  ok "mutation witness (unqualified shipped result): a swapped-in 'Shipped.' result is detected on both counts"
else
  bad "mutation witness (unqualified shipped result) did not discriminate real file from mutant"
fi

# =============================================================================
# Section 6 — syntax sanity (bash -n / node --check), matching the rest of
# the suite's own toolchain expectations.
# =============================================================================
echo
echo "syntax sanity"

bash -n "$SCRIPT_DIR/owner-journey.test.sh" && ok "this test script parses under bash -n" || bad "this test script fails bash -n"
node --check "$APP_JS" >/dev/null 2>&1 && ok "app.js parses under node --check" || bad "app.js fails node --check"

echo
echo "owner-journey.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
