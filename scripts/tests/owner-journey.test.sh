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

# Forbidden-channel sensor: a purpose-built JavaScript tokenizer/lexer, not
# an ERE. Twelve review rounds showed that matching formatter whitespace,
# nested grouping, helper-call arguments, and ||/?? fallbacks with a flattened
# regex does not converge; the owner replaced that mechanism. The ERE is not
# retained as a decision path.
#
# The lexer emits identifier, punctuation/operator, and literal tokens and
# ignores whitespace and comments. Text inside strings, regex bodies, and
# template-literal raw portions is not executable. ${...} interpolations are
# tokenized, including nested templates and braces. Malformed or lexically
# indeterminate input fails closed (nonzero), never reports clean.
#
# Member-access classification (the receiver immediately left of . / ?. or a
# computed [...]):
#   - direct and arbitrarily parenthesized window/location/document are visible
#   - top-level || / ?? fallbacks are visible through grouping; any reachable
#     operand that is the relevant global makes the access forbidden
#   - call results are opaque: a global used only as an argument to
#     adapter(...) / snapshot(...) does not make the call's return value that
#     global. Do not descend through call-argument parentheses.
#   - && is not a fallback; (window && other)?.open has other as the receiver
# Identifier matches are exact ($ and alnum are identifier characters), so
# prefetchData, mainwindow, $new, Worker$Factory are not the forbidden names.
# window.location assignment is distinct from a read or === comparison.
# document.location and location.href/assign/replace are member access.
# Constant computed members (window["open"]) are detected; a non-constant
# computed key on a relevant global fails closed. The whole file is tokenized
# and checked before the function returns clean (no grep -q / SIGPIPE).
check_forbidden_js() {
  OJ_FORBIDDEN_TARGET="$1" node --input-type=commonjs <<'NODE'
'use strict';
/**
 * Bounded JavaScript tokenizer + forbidden-channel detector for issue #348.
 * Not a full parser. Fail closed on malformed or lexically indeterminate input.
 */
const fs = require('fs');

function mapOf(keys) {
  const o = Object.create(null);
  for (let i = 0; i < keys.length; i++) o[keys[i]] = true;
  return o;
}

const FORBIDDEN_IDENTS = mapOf([
  'XMLHttpRequest', 'sendBeacon', 'WebSocket', 'EventSource',
  'ServiceWorker', 'serviceWorker', 'importScripts'
]);

const RELEVANT_GLOBALS = mapOf(['window', 'location', 'document']);

const NOT_CALLEE = mapOf([
  'if', 'else', 'while', 'for', 'switch', 'catch', 'function',
  'return', 'void', 'typeof', 'delete', 'await', 'case', 'do',
  'try', 'finally', 'with', 'class', 'const', 'let', 'var',
  'new', 'throw', 'yield', 'in', 'instanceof', 'of',
  'extends', 'static', 'default', 'export', 'from',
  'break', 'continue', 'debugger'
]);

const ASSIGN_OPS = mapOf([
  '=', '+=', '-=', '*=', '/=', '%=', '**=',
  '&=', '|=', '^=', '<<=', '>>=', '>>>=',
  '&&=', '||=', '??='
]);

const LOCATION_PROPS = mapOf(['href', 'assign', 'replace']);

function isIdentStart(c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c === '_' || c === '$';
}
function isIdentPart(c) {
  return isIdentStart(c) || (c >= '0' && c <= '9');
}
function isDigit(c) { return c >= '0' && c <= '9'; }
function isHex(c) {
  return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
function isLineTerm(c) { return c === '\n' || c === '\r' || c === '\u2028' || c === '\u2029'; }

function canStartRegex(last) {
  if (!last) return true;
  if (last.kind === 'ident') {
    return !!NOT_CALLEE[last.value] && last.value !== 'this' && last.value !== 'super';
  }
  if (last.kind !== 'punct') return false;
  const v = last.value;
  if (v === ')' || v === ']' || v === '++' || v === '--') return false;
  return true;
}

function tokenize(src) {
  const tokens = [];
  const n = src.length;
  let i = 0;
  let last = null;
  const interp = [];

  function emit(tok) {
    tokens.push(tok);
    last = tok;
  }
  function peek(k) { return i + k < n ? src[i + k] : ''; }
  function fail(msg) { return { ok: false, error: msg, tokens: tokens }; }

  if (i < n && src.charCodeAt(0) === 0xFEFF) i = 1;
  if (src[0] === '#' && src[1] === '!') {
    while (i < n && !isLineTerm(src[i])) i++;
  }

  while (i < n) {
    const c = src[i];

    if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f' || c === '\v' ||
        c === '\u00a0' || c === '\u2028' || c === '\u2029') {
      i++;
      continue;
    }

    if (c === '/' && peek(1) === '/') {
      i += 2;
      while (i < n && !isLineTerm(src[i])) i++;
      continue;
    }
    if (c === '/' && peek(1) === '*') {
      i += 2;
      let closed = false;
      while (i < n) {
        if (src[i] === '*' && peek(1) === '/') { i += 2; closed = true; break; }
        i++;
      }
      if (!closed) return fail('unterminated-block-comment');
      continue;
    }

    if (c === '/' && canStartRegex(last)) {
      i++;
      let inClass = false;
      let closed = false;
      while (i < n) {
        const r = src[i];
        if (isLineTerm(r)) return fail('unterminated-regex');
        if (r === '\\') {
          i += 1;
          if (i >= n) return fail('unterminated-regex');
          i += 1;
          continue;
        }
        if (r === '[' && !inClass) { inClass = true; i++; continue; }
        if (r === ']' && inClass) { inClass = false; i++; continue; }
        if (r === '/' && !inClass) { i++; closed = true; break; }
        i++;
      }
      if (!closed) return fail('unterminated-regex');
      while (i < n && ((src[i] >= 'a' && src[i] <= 'z') || (src[i] >= 'A' && src[i] <= 'Z'))) i++;
      emit({ kind: 'regex', value: '/' });
      continue;
    }

    if (c === "'" || c === '"') {
      const q = c;
      i++;
      let value = '';
      let closed = false;
      while (i < n) {
        const s = src[i];
        if (isLineTerm(s) && s !== '\u2028' && s !== '\u2029') return fail('unterminated-string');
        if (s === '\\') {
          const u = unescapeOne(src, i);
          if (!u.ok) return fail(u.error);
          value += u.ch;
          i = u.next;
          continue;
        }
        if (s === q) { i++; closed = true; break; }
        value += s;
        i++;
      }
      if (!closed) return fail('unterminated-string');
      emit({ kind: 'string', value: value });
      continue;
    }

    if (c === '`') {
      const t = lexTemplate(src, i, emit, interp);
      if (!t.ok) return fail(t.error);
      i = t.next;
      last = tokens.length ? tokens[tokens.length - 1] : last;
      continue;
    }

    if (isIdentStart(c)) {
      let j = i + 1;
      while (j < n && isIdentPart(src[j])) j++;
      emit({ kind: 'ident', value: src.slice(i, j) });
      i = j;
      continue;
    }

    if (isDigit(c) || (c === '.' && isDigit(peek(1)))) {
      const num = lexNumber(src, i);
      if (!num.ok) return fail(num.error);
      emit({ kind: 'number', value: num.value });
      i = num.next;
      continue;
    }

    const op = lexOperator(src, i);
    if (!op.ok) return fail(op.error || 'unexpected-char');
    if (op.value === '}' && interp.length && interp[interp.length - 1] === 0) {
      interp.pop();
      const resumed = resumeTemplate(src, op.next, emit, interp);
      if (!resumed.ok) return fail(resumed.error);
      i = resumed.next;
      last = tokens.length ? tokens[tokens.length - 1] : last;
      continue;
    }
    if (op.value === '{') {
      if (interp.length) interp[interp.length - 1] += 1;
    } else if (op.value === '}') {
      if (interp.length) {
        interp[interp.length - 1] -= 1;
        if (interp[interp.length - 1] < 0) return fail('unbalanced-brace');
      }
    }
    emit({ kind: 'punct', value: op.value });
    i = op.next;
  }

  if (interp.length) return fail('unterminated-template-interpolation');
  const bal = delimiterBalance(tokens);
  if (!bal.ok) return fail(bal.error);
  return { ok: true, tokens: tokens };
}

function delimiterBalance(tokens) {
  let dp = 0, db = 0, dc = 0;
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.kind !== 'punct') continue;
    if (t.value === '(') dp++;
    else if (t.value === ')') dp--;
    else if (t.value === '[') db++;
    else if (t.value === ']') db--;
    else if (t.value === '{') dc++;
    else if (t.value === '}') dc--;
    if (dp < 0 || db < 0 || dc < 0) return { ok: false, error: 'unbalanced-delimiter' };
  }
  if (dp !== 0 || db !== 0 || dc !== 0) return { ok: false, error: 'unbalanced-delimiter' };
  return { ok: true };
}

function unescapeOne(src, i) {
  // i points at backslash
  const n = src.length;
  if (i + 1 >= n) return { ok: false, error: 'unterminated-escape' };
  const e = src[i + 1];
  if (e === 'n') return { ok: true, ch: '\n', next: i + 2 };
  if (e === 'r') return { ok: true, ch: '\r', next: i + 2 };
  if (e === 't') return { ok: true, ch: '\t', next: i + 2 };
  if (e === 'b') return { ok: true, ch: '\b', next: i + 2 };
  if (e === 'f') return { ok: true, ch: '\f', next: i + 2 };
  if (e === 'v') return { ok: true, ch: '\v', next: i + 2 };
  if (e === '0') return { ok: true, ch: '\0', next: i + 2 };
  if (e === '\\' || e === "'" || e === '"' || e === '`' || e === '$' || e === '/') {
    return { ok: true, ch: e, next: i + 2 };
  }
  if (e === 'x') {
    if (i + 3 >= n || !isHex(src[i + 2]) || !isHex(src[i + 3])) {
      return { ok: false, error: 'bad-hex-escape' };
    }
    return { ok: true, ch: String.fromCharCode(parseInt(src.slice(i + 2, i + 4), 16)), next: i + 4 };
  }
  if (e === 'u') {
    if (src[i + 2] === '{') {
      let j = i + 3;
      let hex = '';
      while (j < n && isHex(src[j])) { hex += src[j]; j++; }
      if (!hex || src[j] !== '}') return { ok: false, error: 'bad-unicode-escape' };
      const cp = parseInt(hex, 16);
      if (cp > 0x10FFFF) return { ok: false, error: 'bad-unicode-escape' };
      return { ok: true, ch: String.fromCodePoint(cp), next: j + 1 };
    }
    if (i + 5 >= n) return { ok: false, error: 'bad-unicode-escape' };
    const h = src.slice(i + 2, i + 6);
    if (![h[0], h[1], h[2], h[3]].every(isHex)) return { ok: false, error: 'bad-unicode-escape' };
    return { ok: true, ch: String.fromCharCode(parseInt(h, 16)), next: i + 6 };
  }
  if (isLineTerm(e)) {
    let next = i + 2;
    if (e === '\r' && src[i + 2] === '\n') next++;
    return { ok: true, ch: '', next: next };
  }
  return { ok: true, ch: e, next: i + 2 };
}

function lexTemplate(src, i, emit, interp) {
  // i points at opening backtick. Raw text is not executable. ${ starts interpolation.
  return resumeTemplateFrom(src, i + 1, emit, interp);
}

function resumeTemplate(src, i, emit, interp) {
  return resumeTemplateFrom(src, i, emit, interp);
}

function resumeTemplateFrom(src, i, emit, interp) {
  const n = src.length;
  let raw = '';
  let hasInterp = false;
  while (i < n) {
    const c = src[i];
    if (c === '\\') {
      const u = unescapeOne(src, i);
      if (!u.ok) return { ok: false, error: u.error };
      raw += u.ch;
      i = u.next;
      continue;
    }
    if (c === '`') {
      i++;
      if (!hasInterp) emit({ kind: 'string', value: raw, template: true });
      else emit({ kind: 'template', value: '' });
      return { ok: true, next: i };
    }
    if (c === '$' && src[i + 1] === '{') {
      hasInterp = true;
      i += 2;
      interp.push(0);
      return { ok: true, next: i };
    }
    raw += c;
    i++;
  }
  return { ok: false, error: 'unterminated-template' };
}

function lexNumber(src, i) {
  const n = src.length;
  const start = i;
  if (src[i] === '0' && (src[i + 1] === 'x' || src[i + 1] === 'X')) {
    i += 2;
    if (i >= n || !isHex(src[i])) return { ok: false, error: 'bad-number' };
    while (i < n && (isHex(src[i]) || src[i] === '_')) i++;
    return { ok: true, value: src.slice(start, i), next: i };
  }
  if (src[i] === '0' && (src[i + 1] === 'b' || src[i + 1] === 'B' || src[i + 1] === 'o' || src[i + 1] === 'O')) {
    i += 2;
    if (i >= n || !isDigit(src[i])) return { ok: false, error: 'bad-number' };
    while (i < n && (isDigit(src[i]) || src[i] === '_')) i++;
    return { ok: true, value: src.slice(start, i), next: i };
  }
  if (src[i] === '.') {
    i++;
    while (i < n && (isDigit(src[i]) || src[i] === '_')) i++;
  } else {
    while (i < n && (isDigit(src[i]) || src[i] === '_')) i++;
    if (src[i] === '.') {
      i++;
      while (i < n && (isDigit(src[i]) || src[i] === '_')) i++;
    }
  }
  if (src[i] === 'e' || src[i] === 'E') {
    i++;
    if (src[i] === '+' || src[i] === '-') i++;
    if (i >= n || !isDigit(src[i])) return { ok: false, error: 'bad-number' };
    while (i < n && (isDigit(src[i]) || src[i] === '_')) i++;
  }
  if (src[i] === 'n') i++;
  return { ok: true, value: src.slice(start, i), next: i };
}

function lexOperator(src, i) {
  const n = src.length;
  const c = src[i];
  const c2 = i + 1 < n ? src[i + 1] : '';
  const c3 = i + 2 < n ? src[i + 2] : '';
  const c4 = i + 3 < n ? src[i + 3] : '';

  function take(len) {
    return { ok: true, value: src.slice(i, i + len), next: i + len };
  }

  if (c === '.' && c2 === '.' && c3 === '.') return take(3);
  if (c === '?' && c2 === '?' && c3 === '=') return take(3);
  if (c === '?' && c2 === '?') return take(2);
  if (c === '?' && c2 === '.') {
    if (isDigit(c3)) return take(1);
    return take(2);
  }
  if (c === '=' && c2 === '=' && c3 === '=') return take(3);
  if (c === '!' && c2 === '=' && c3 === '=') return take(3);
  if (c === '=' && c2 === '=') return take(2);
  if (c === '!' && c2 === '=') return take(2);
  if (c === '=' && c2 === '>') return take(2);
  if (c === '&' && c2 === '&' && c3 === '=') return take(3);
  if (c === '|' && c2 === '|' && c3 === '=') return take(3);
  if (c === '&' && c2 === '&') return take(2);
  if (c === '|' && c2 === '|') return take(2);
  if (c === '+' && c2 === '+') return take(2);
  if (c === '-' && c2 === '-') return take(2);
  if (c === '*' && c2 === '*' && c3 === '=') return take(3);
  if (c === '*' && c2 === '*') return take(2);
  if (c === '<' && c2 === '<' && c3 === '=') return take(3);
  if (c === '>' && c2 === '>' && c3 === '>' && c4 === '=') return take(4);
  if (c === '>' && c2 === '>' && c3 === '>') return take(3);
  if (c === '>' && c2 === '>' && c3 === '=') return take(3);
  if (c === '<' && c2 === '<') return take(2);
  if (c === '>' && c2 === '>') return take(2);
  if (c === '<' && c2 === '=') return take(2);
  if (c === '>' && c2 === '=') return take(2);
  if (c === '+' && c2 === '=') return take(2);
  if (c === '-' && c2 === '=') return take(2);
  if (c === '*' && c2 === '=') return take(2);
  if (c === '/' && c2 === '=') return take(2);
  if (c === '%' && c2 === '=') return take(2);
  if (c === '&' && c2 === '=') return take(2);
  if (c === '|' && c2 === '=') return take(2);
  if (c === '^' && c2 === '=') return take(2);

  const singles = '()[]{};,~?:.,<>=!+-*/%&|^';
  if (singles.indexOf(c) !== -1) return take(1);
  return { ok: false, error: 'unexpected-char:' + JSON.stringify(c) };
}

function matchingOpen(tokens, closeIdx) {
  const close = tokens[closeIdx].value;
  const open = close === ')' ? '(' : close === ']' ? '[' : '{';
  let depth = 0;
  for (let i = closeIdx; i >= 0; i--) {
    const t = tokens[i];
    if (t.kind !== 'punct') continue;
    if (t.value === close) depth++;
    else if (t.value === open) {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function matchingClose(tokens, openIdx) {
  const open = tokens[openIdx].value;
  const close = open === '(' ? ')' : open === '[' ? ']' : '}';
  let depth = 0;
  for (let i = openIdx; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.kind !== 'punct') continue;
    if (t.value === open) depth++;
    else if (t.value === close) {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function isDotTok(t) {
  return t && t.kind === 'punct' && (t.value === '.' || t.value === '?.');
}

function isCallCalleeSuffix(before) {
  if (!before) return false;
  if (before.kind === 'ident') return !NOT_CALLEE[before.value];
  if (before.kind === 'punct') {
    return before.value === ')' || before.value === ']' || before.value === '?.';
  }
  return false;
}

function splitTopLevel(tokens, start, end, opSet) {
  const parts = [];
  let dp = 0, db = 0, dc = 0;
  let partStart = start;
  for (let i = start; i <= end; i++) {
    const t = tokens[i];
    if (t.kind !== 'punct') continue;
    const v = t.value;
    if (v === '(') dp++;
    else if (v === ')') dp--;
    else if (v === '[') db++;
    else if (v === ']') db--;
    else if (v === '{') dc++;
    else if (v === '}') dc--;
    else if (dp === 0 && db === 0 && dc === 0 && opSet[v]) {
      parts.push({ start: partStart, end: i - 1 });
      partStart = i + 1;
    }
    if (dp < 0 || db < 0 || dc < 0) return { ok: false, parts: [] };
  }
  parts.push({ start: partStart, end: end });
  return { ok: true, parts: parts };
}

function hasTopLevel(tokens, start, end, opSet) {
  const s = splitTopLevel(tokens, start, end, opSet);
  return s.ok && s.parts.length > 1;
}

function possibleGlobals(tokens, start, end, ctx) {
  const empty = new Set();
  if (ctx.indeterminate) return empty;
  if (start > end) { ctx.indeterminate = true; return empty; }

  const orSplit = splitTopLevel(tokens, start, end, { '||': 1, '??': 1 });
  if (!orSplit.ok) { ctx.indeterminate = true; return empty; }
  if (orSplit.parts.length > 1) {
    const union = new Set();
    for (let p = 0; p < orSplit.parts.length; p++) {
      const part = orSplit.parts[p];
      possibleGlobals(tokens, part.start, part.end, ctx).forEach(function (g) { union.add(g); });
    }
    return union;
  }

  const andSplit = splitTopLevel(tokens, start, end, { '&&': 1 });
  if (!andSplit.ok) { ctx.indeterminate = true; return empty; }
  if (andSplit.parts.length > 1) {
    const last = andSplit.parts[andSplit.parts.length - 1];
    return possibleGlobals(tokens, last.start, last.end, ctx);
  }

  if (hasTopLevel(tokens, start, end, { '?': 1, ',': 1 })) {
    ctx.indeterminate = true;
    return empty;
  }

  const lhs = consumeExprEndingAt(tokens, end, ctx);
  if (ctx.indeterminate) return empty;
  if (lhs.start !== start) {
    ctx.indeterminate = true;
    return empty;
  }
  return lhs.globals;
}

function consumeExprEndingAt(tokens, end, ctx) {
  const empty = new Set();
  if (ctx.indeterminate) return { start: 0, globals: empty };
  if (end < 0 || end >= tokens.length) { ctx.indeterminate = true; return { start: 0, globals: empty }; }
  const tok = tokens[end];

  if (tok.kind === 'punct' && tok.value === ')') {
    const open = matchingOpen(tokens, end);
    if (open < 0) { ctx.indeterminate = true; return { start: 0, globals: empty }; }
    const before = open > 0 ? tokens[open - 1] : null;
    if (isCallCalleeSuffix(before)) {
      let calleeEnd = open - 1;
      if (before.value === '?.') calleeEnd = open - 2;
      const callee = consumeExprEndingAt(tokens, calleeEnd, ctx);
      return { start: callee.start, globals: empty };
    }
    const inner = possibleGlobals(tokens, open + 1, end - 1, ctx);
    let start = open;
    if (before && before.kind === 'ident' && before.value === 'new') start = open - 1;
    return { start: start, globals: inner };
  }

  if (tok.kind === 'punct' && tok.value === ']') {
    const open = matchingOpen(tokens, end);
    if (open < 0) { ctx.indeterminate = true; return { start: 0, globals: empty }; }
    const obj = consumeExprEndingAt(tokens, open - 1, ctx);
    return { start: obj.start, globals: empty };
  }

  if (tok.kind === 'punct' && tok.value === '}') {
    const open = matchingOpen(tokens, end);
    if (open < 0) { ctx.indeterminate = true; return { start: 0, globals: empty }; }
    return { start: open, globals: empty };
  }

  if (tok.kind === 'ident') {
    if (end > 0 && isDotTok(tokens[end - 1])) {
      const obj = consumeExprEndingAt(tokens, end - 2, ctx);
      return { start: obj.start, globals: empty };
    }
    const names = new Set();
    if (RELEVANT_GLOBALS[tok.value]) names.add(tok.value);
    let start = end;
    if (end > 0 && tokens[end - 1].kind === 'ident' && tokens[end - 1].value === 'new') {
      start = end - 1;
    }
    return { start: start, globals: names };
  }

  if (tok.kind === 'string' || tok.kind === 'number' || tok.kind === 'regex' || tok.kind === 'template') {
    return { start: end, globals: empty };
  }

  ctx.indeterminate = true;
  return { start: end, globals: empty };
}

function constantKey(tokens, start, end) {
  if (start !== end) return null;
  const t = tokens[start];
  if (t.kind === 'string') return t.value;
  if (t.kind === 'number') return t.value;
  return null;
}

function isComputedMemberOpen(tokens, i) {
  if (i === 0) return false;
  const before = tokens[i - 1];
  if (before.kind === 'ident') return true;
  if (before.kind === 'string' || before.kind === 'number' || before.kind === 'template' || before.kind === 'regex') {
    return true;
  }
  if (before.kind === 'punct') {
    return before.value === ')' || before.value === ']' || before.value === '?.';
  }
  return false;
}

function isAssignAfter(tokens, idx) {
  if (idx >= tokens.length) return false;
  return tokens[idx].kind === 'punct' && !!ASSIGN_OPS[tokens[idx].value];
}

function constructorIdent(tokens, afterNew) {
  let i = afterNew;
  while (i < tokens.length && tokens[i].kind === 'punct' && tokens[i].value === '(') {
    const before = i > 0 ? tokens[i - 1] : null;
    if (before && before.kind === 'ident' && before.value !== 'new' && !NOT_CALLEE[before.value]) {
      break;
    }
    if (before && isCallCalleeSuffix(before) && !(before.kind === 'ident' && before.value === 'new')) {
      break;
    }
    const close = matchingClose(tokens, i);
    if (close < 0) return null;
    i = i + 1;
  }
  if (i < tokens.length && tokens[i].kind === 'ident') return tokens[i].value;
  return null;
}

function detect(tokens) {
  const ctx = { indeterminate: false };
  const hits = [];

  function hit(kind) { hits.push(kind); }

  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    const next = i + 1 < tokens.length ? tokens[i + 1] : null;
    const prev = i > 0 ? tokens[i - 1] : null;

    if (tok.kind === 'ident' && FORBIDDEN_IDENTS[tok.value]) {
      hit('ident:' + tok.value);
    }

    if (tok.kind === 'ident' && tok.value === 'fetch') {
      if (next && next.kind === 'punct' && next.value === '(') hit('fetch-call');
      else if (next && next.kind === 'punct' && next.value === '?.' &&
               i + 2 < tokens.length && tokens[i + 2].kind === 'punct' && tokens[i + 2].value === '(') {
        hit('fetch-call');
      }
    }

    if (tok.kind === 'ident' && tok.value === 'import') {
      if (next && next.kind === 'punct' && next.value === '(') hit('dynamic-import');
    }

    if (tok.kind === 'ident' && tok.value === 'new') {
      const ctor = constructorIdent(tokens, i + 1);
      if (ctor === 'Worker') hit('new-Worker');
    }

    if (tok.kind === 'ident' && tok.value === 'location' && !isDotTok(prev)) {
      if (isAssignAfter(tokens, i + 1)) hit('bare-location-assign');
    }

    if (tok.kind === 'punct' && (tok.value === '.' || tok.value === '?.')) {
      checkMember(tokens, i, ctx, hit);
      if (ctx.indeterminate) return { ok: false, error: 'indeterminate-member', hits: hits };
    }

    if (tok.kind === 'punct' && tok.value === '[' && isComputedMemberOpen(tokens, i)) {
      checkComputed(tokens, i, ctx, hit);
      if (ctx.indeterminate) return { ok: false, error: 'indeterminate-computed', hits: hits };
    }
  }

  return { ok: true, hits: hits };
}

function receiverGlobals(tokens, objEnd, ctx) {
  const rec = consumeExprEndingAt(tokens, objEnd, ctx);
  if (ctx.indeterminate) return new Set();
  return rec.globals;
}

function checkMember(tokens, dotIndex, ctx, hit) {
  if (dotIndex < 1) return;
  const prop = tokens[dotIndex + 1];
  if (!prop || prop.kind !== 'ident') return;
  const name = prop.value;
  const globals = receiverGlobals(tokens, dotIndex - 1, ctx);
  if (ctx.indeterminate) return;
  const assign = isAssignAfter(tokens, dotIndex + 2);
  applyMemberRule(name, globals, assign, hit);
}

function checkComputed(tokens, openIdx, ctx, hit) {
  const close = matchingClose(tokens, openIdx);
  if (close < 0) { ctx.indeterminate = true; return; }
  const globals = receiverGlobals(tokens, openIdx - 1, ctx);
  if (ctx.indeterminate) return;
  const key = constantKey(tokens, openIdx + 1, close - 1);
  if (key === null) {
    if (globals.has('window') || globals.has('location') || globals.has('document')) {
      ctx.indeterminate = true;
    }
    return;
  }
  const assign = isAssignAfter(tokens, close + 1);
  applyMemberRule(key, globals, assign, hit);
}

function applyMemberRule(name, globals, assign, hit) {
  if (name === 'open' && globals.has('window')) hit('window.open');
  if (name === 'location' && globals.has('document')) hit('document.location');
  if (name === 'location' && globals.has('window') && assign) hit('window.location=');
  if (LOCATION_PROPS[name] && globals.has('location')) hit('location.' + name);
  if (name === 'innerHTML' && assign) hit('innerHTML=');
}

function checkSource(src) {
  const lex = tokenize(src);
  if (!lex.ok) return { exit: 2, error: lex.error, hits: [] };
  const det = detect(lex.tokens);
  if (!det.ok) return { exit: 2, error: det.error, hits: det.hits || [] };
  if (det.hits.length) return { exit: 1, error: null, hits: det.hits };
  return { exit: 0, error: null, hits: [] };
}

const file = process.env.OJ_FORBIDDEN_TARGET;
if (!file) {
  process.stderr.write('forbidden-js-check: missing target path\n');
  process.exit(2);
}
let src;
try { src = fs.readFileSync(file, 'utf8'); }
catch (e) {
  process.stderr.write('forbidden-js-check: read failed\n');
  process.exit(2);
}
const result = checkSource(src);
if (process.env.OJ_FORBIDDEN_DEBUG) {
  process.stderr.write(JSON.stringify(result) + '\n');
}
process.exit(result.exit);

NODE
}

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
  $'fetch\n("https://example.invalid/exfiltrate");'
  'window.location = "https://example.invalid/";'
  $'window.location =\n  "https://example.invalid/";'
  $'window\n  .location =\n  "https://example.invalid/";'
  'new WebSocket("wss://example.invalid");'
  $'new\n  Worker("worker.js");'
  'window.open("https://example.invalid/");'
  $'import\n("https://example.invalid/exfiltrate.mjs");'
  # Proactive control for the round-7 dot-normalization fix: a real
  # window.open(...) call reformatted with the dot at end-of-line must
  # still be caught, not just tolerated as a false-positive fix.
  $'window.\n  open("https://example.invalid/");'
  # Codex round-8 finding: optional chaining still performs real navigation
  # when the left side exists, as it always does for window/location.
  'window?.open("https://example.invalid/");'
  'location?.assign("https://example.invalid/");'
  'location?.replace("https://example.invalid/");'
  # Codex round-9 finding: a parenthesized or guarded optional-chain base
  # still executes when the parenthesized expression evaluates to the real
  # object.
  '(window)?.open("https://example.invalid/");'
  '(shouldOpen && window)?.open("https://example.invalid/");'
  '(location)?.assign("https://example.invalid/");'
  '(document)?.location;'
  # Codex round-10 finding: formatter whitespace between nested closers,
  # and `||` fallbacks that still evaluate to the real global.
  '((window) )?.open("https://example.invalid/");'
  '((window) ).location = "https://example.invalid/";'
  '((location) )?.href;'
  '((location) )?.assign("https://example.invalid/");'
  '((location) )?.replace("https://example.invalid/");'
  '((document) )?.location;'
  $'(\n  (window)\n)?.open("https://example.invalid/");'
  '(window || fallbackWindow)?.open("https://example.invalid/");'
  '(location || fallbackLocation).href;'
  '(document || fallbackDocument)?.location;'
  # Codex round-11 finding: closers BEFORE the fallback operator still
  # evaluate to the real global when it is truthy.
  '((window) || fallbackWindow)?.open("https://example.invalid/");'
  '((location) ?? fallbackLocation)?.assign("https://example.invalid/");'
  '((document) || fallbackDocument)?.location;'
  '((window) || (fallbackWindow))?.open("https://example.invalid/");'
  # Codex round-12 finding: grouped || fallback with closers before the
  # operator, split across lines. The receiver can still be window.
  $'((window) || (\n  fallbackWindow\n))?.open("https://example.invalid/");'
)
NET_ALL_CAUGHT=1
for mutation in "${NET_MUTATIONS[@]}"; do
  mutant_file="$TMP_DIR/app.mutant-net-$(echo "$mutation" | cksum | cut -d' ' -f1).js"
  cp "$APP_JS" "$mutant_file"
  printf '\n%s\n' "$mutation" >> "$mutant_file"
  check_forbidden_js "$mutant_file" && NET_ALL_CAUGHT=0
done
[[ "$NET_ALL_CAUGHT" -eq 1 ]] && ok "mutation witness (network/external-navigation channel): fetch (plain and paren-split), single-line/multiline/dot-split window.location assignment, WebSocket, split new Worker, window.open, and paren-split import() are each individually detected" || bad "mutation witness (network/external-navigation channel) missed at least one injected channel"

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
  # Codex round-4 finding: a `new`-suffixed identifier immediately followed
  # by an unrelated `Worker.reset()` call on the next line, once flattened
  # to one line, contains the literal substring "new Worker" purely by
  # coincidence — this constructs no worker.
  $'const renew = true\nconst Worker = { reset() {} }\nconst shouldRenew = renew\nWorker.reset()'
  # Codex round-5 findings: "window" had no LEFT identifier boundary, so an
  # identifier merely ENDING in "window" false-matched...
  $'const mainwindow = {};\nmainwindow\n  .location = "local";'
  # ...and grep's `\b` does not know `$` is a legal JS identifier character,
  # so a `$`-prefixed variable before "Worker"...
  $'const $new = true;\nconst Worker = { reset() {} };\nconst shouldRenew = $new\nWorker.reset()'
  # ...and a `$`-suffixed class name after "new" both slipped past a
  # `\b`-only boundary.
  $'class Worker$Factory {}\nconst localObject = new Worker$Factory();'
  # Proactive control (same root cause, not yet demonstrated by Codex but
  # closed by the same both-sided-boundary fix): an identifier merely
  # ending in "fetch" is not a call to the forbidden global.
  'function prefetchData() { return 1; }'
  # Codex round-6 finding: the TERMINAL identifier in each member-access
  # alternative had no right boundary, so a longer, unrelated property name
  # starting with that word substring-matched.
  'function inspect(window) { return window.opened; }'
  'function inspect(location) { return location.hrefCache; }'
  'function inspect(document) { return document.locationCache; }'
  'location.assignment();'
  'location.replacement();'
  # Codex round-7 finding: an ordinary dot-at-end-of-line reformat puts a
  # SPACE (not a dot) immediately before "location" once flattened, which
  # the bare-location exclusion's single-preceding-character check missed.
  $'const model = {};\nmodel.\n  location = "local";'
  # Proactive control for the same fix, other direction: an identifier
  # merely SHARING "window" via a dot-at-end-of-line split is still not the
  # global object.
  $'const w = window;\nw.\n  location = "local";'
  # Codex round-10 finding: a helper that takes the global as an argument
  # and returns some other receiver is not a grouped-global member access.
  'adapter(window)?.open("local-panel");'
  'snapshot(location).href;'
  'adapter(location).replace("local-state");'
  'snapshot(document).location;'
  'adapter(window).location = "local-state";'
  # Codex round-11 finding: grouped fallbacks inside a helper argument
  # are still helper-return member access, not grouped-global receivers.
  'adapter((window || fallbackWindow))?.open("local-panel");'
  'snapshot((location || fallbackLocation)).href;'
  'adapter((location ?? fallbackLocation)).replace("local-state");'
  'snapshot((document || fallbackDocument)).location;'
  'adapter(((window)))?.open("local-panel");'
  # Codex round-12 finding: helper call whose argument is a grouped
  # fallback, with the call parens themselves split across lines. .open
  # is invoked on the helper return value, not on window.
  $'adapter(\n  (window || fallbackWindow)\n)?.open("local-panel");'
)
BENIGN_ALL_CLEAN=1
for snippet in "${BENIGN_LOCATION_SNIPPETS[@]}"; do
  benign_file="$TMP_DIR/app.benign-net-$(echo "$snippet" | cksum | cut -d' ' -f1).js"
  cp "$APP_JS" "$benign_file"
  printf '\n%s\n' "$snippet" >> "$benign_file"
  check_forbidden_js "$benign_file" || BENIGN_ALL_CLEAN=0
done
[[ "$BENIGN_ALL_CLEAN" -eq 1 ]] && ok "false-positive control: plain reads/comparisons, unrelated properties, string literals, \$-containing identifiers, a coincidental cross-line \"new...Worker\" substring, and longer property names sharing a prefix with a forbidden term all pass cleanly" || bad "the forbidden-channel sensor false-positives on ordinary, non-navigating code"


# Tokenizer/expression adversarial matrix. Each case is appended to a copy of
# the real app.js and run through the same check_forbidden_js. Every claimed
# lexer/expression branch has a dedicated case.
echo
echo "tokenizer/expression adversarial matrix"

assert_forbidden_snippet() {
  local name="$1"
  local snippet="$2"
  local mutant_file
  mutant_file="$TMP_DIR/app.lex-mut-$(echo "$name" | cksum | cut -d' ' -f1).js"
  cp "$APP_JS" "$mutant_file"
  printf '\n%s\n' "$snippet" >> "$mutant_file"
  if check_forbidden_js "$mutant_file"; then
    bad "tokenizer mutation missed: $name"
  else
    ok "tokenizer mutation detected: $name"
  fi
}

assert_clean_snippet() {
  local name="$1"
  local snippet="$2"
  local benign_file
  benign_file="$TMP_DIR/app.lex-benign-$(echo "$name" | cksum | cut -d' ' -f1).js"
  cp "$APP_JS" "$benign_file"
  printf '\n%s\n' "$snippet" >> "$benign_file"
  if check_forbidden_js "$benign_file"; then
    ok "tokenizer control clean: $name"
  else
    bad "tokenizer false-red: $name"
  fi
}

assert_clean_snippet "forbidden names in a line comment" '// fetch("https://example.invalid/"); XMLHttpRequest; window.open("x");'
assert_clean_snippet "forbidden names in a block comment" '/* new Worker("w.js"); location.assign("x"); innerHTML = "y"; */'
assert_clean_snippet "forbidden names in an ordinary string" 'var msg = "window.open(x) fetch(y) new Worker";'
assert_clean_snippet "forbidden names in template raw text" 'var t = `location.assign("x") window.open("y")`;'
assert_clean_snippet "forbidden names in a regex literal" 'var r = /new Worker/; var r2 = /window\.open/;'
assert_forbidden_snippet "forbidden expression inside template interpolation" 'var t = `${window.open("x")}`;'
assert_forbidden_snippet "comments between receiver/operator/property" 'window/*c*/./*c*/open("https://example.invalid/");'
assert_forbidden_snippet "line comments in a fallback chain" $'(window // left\n  || /* mid */ fallbackWindow)?.open("https://example.invalid/");'
assert_forbidden_snippet "nested grouping around window" '(((window)))?.open("https://example.invalid/");'
assert_forbidden_snippet "|| later operand is window" '(fallbackWindow || window)?.open("https://example.invalid/");'
assert_forbidden_snippet "?? later operand is window" '(fallbackWindow ?? window)?.open("https://example.invalid/");'
assert_forbidden_snippet "?? first operand is window" '(window ?? fallbackWindow)?.open("https://example.invalid/");'
assert_forbidden_snippet "&& proceeding operand is window" '(other && window)?.open("https://example.invalid/");'
assert_clean_snippet "&& is not a fallback operator" '(window && other)?.open("local-panel");'
assert_clean_snippet "helper call with nested grouped fallback argument" $'adapter(\n  ((window) || (\n    fallbackWindow\n  ))\n)?.open("local-panel");'
assert_clean_snippet "longer $-legal identifiers" $'function $fetch() { return 1; }\nconst importScripts$ = 1;\nconst XMLHttpRequest2 = {};'
assert_clean_snippet "terminal-property prefixes remain distinct" $'window.opened();\nlocation.hrefCache;\nlocation.assignment();\nlocation.replacement();\ndocument.locationCache;'
assert_forbidden_snippet "constant computed window.open" 'window["open"]("https://example.invalid/");'
assert_forbidden_snippet "constant computed window.location assignment" "window['location'] = 'https://example.invalid/';"
assert_clean_snippet "constant computed decoy opened" 'window["opened"]("local-panel");'
assert_clean_snippet "constant computed decoy other receiver" 'foo["open"]("local-panel");'
assert_forbidden_snippet "XMLHttpRequest identifier" 'var X = XMLHttpRequest;'
assert_forbidden_snippet "sendBeacon identifier" 'navigator.sendBeacon("https://example.invalid/");'
assert_forbidden_snippet "EventSource identifier" 'new EventSource("/events");'
assert_forbidden_snippet "ServiceWorker identifier" 'var r = ServiceWorker;'
assert_forbidden_snippet "serviceWorker identifier" 'navigator.serviceWorker.register("sw.js");'
assert_forbidden_snippet "importScripts identifier" 'importScripts("worker.js");'
assert_forbidden_snippet "bare location assignment" 'location = "https://example.invalid/";'
assert_forbidden_snippet "grouped new Worker" 'new (Worker)("worker.js");'
assert_forbidden_snippet "fail closed on unterminated string" 'var x = "unterminated'

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
