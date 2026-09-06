// app.js — Gibson owner-journey prototype (issue #348)
//
// WHAT THIS IS
//   A dependency-free, local, clickable simulation of the intended Gibson
//   product journey: connect -> readiness -> request -> blueprint -> work ->
//   preview -> decision -> result. It never talks to a real repository, never
//   runs an agent, and never causes any outcome outside this browser tab.
//
// WHY THE MODEL IS SPLIT FROM THE DOM
//   The top half of this file (up to "DOM WIRING") is a pure state model:
//   plain data plus functions of (state, action, payload) -> state, with no
//   reference to `window`, `document`, or storage. It is exported through
//   CommonJS when a Node `require()` loads it (module.exports below) so
//   scripts/tests/owner-journey.test.sh can exercise the exact same reducer
//   the browser runs — not a reimplementation of it. In a browser, `module`
//   is undefined, so that export is a no-op and only the DOM-wiring half
//   (guarded by `typeof document !== "undefined"`) ever executes.
//
// CLOSED-SHAPE CONTRACT (see the parent issue for the authoritative table)
//   Only the transitions enumerated in TRANSITIONS below are legal. Anything
//   else — an unknown action, an invalid payload, an out-of-order work
//   substage, a tampered persisted value — fails closed: the reducer returns
//   the input state unchanged (or, for storage, resets to `connect` with an
//   accessible notice). There is no code path from this prototype to a
//   network request, a real repository, or an external navigation.
'use strict';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Both the localStorage key AND the "schema" field stored under it. Keeping
// them identical means there is exactly one namespaced string to reason
// about, and reset() only ever has one key to remove.
var SCHEMA = 'gibson.owner-journey-prototype.local.v1';
var STORAGE_KEY = SCHEMA;

var STORAGE_MAX_BYTES = 256;
var REQUEST_MAX_BYTES = 4096;
var FEEDBACK_MAX_BYTES = 2048;

// The only selectable examples. Nothing here is a real repository — these
// are static labels for the simulation, not identifiers Gibson resolves
// against GitHub.
var ALLOWLISTED_PROJECTS = [
  {
    id: 'demo-storefront',
    name: 'Storefront Demo',
    summary: 'A small example storefront web app.'
  },
  {
    id: 'demo-support-portal',
    name: 'Support Portal Demo',
    summary: 'A small example customer-support ticketing app.'
  },
  {
    id: 'demo-internal-crm',
    name: 'Internal CRM Demo',
    summary: 'A small example internal customer-record app.'
  }
];

var WORK_SUBSTAGES = ['understanding', 'planning', 'building', 'checking', 'ready_for_review'];

var WORK_SUBSTAGE_LABELS = {
  understanding: 'Understanding',
  planning: 'Planning',
  building: 'Building',
  checking: 'Checking',
  ready_for_review: 'Ready for review'
};

// The exact, required Result copy (AC8). Qualified deliberately: no
// unqualified real-world completion, confirmation, or production-status
// claim appears anywhere in this prototype.
var RESULT_TEXT = 'Demo complete. No code was changed or deployed.';

var SAFE_WAIT_NOTICE = 'Nothing was approved. Waiting changes nothing, and you can look again before deciding.';
var INVALID_STORAGE_NOTICE = 'Saved project selection could not be used, so this demo restarted at Connect.';
var STORAGE_UNAVAILABLE_NOTICE = 'Local storage is unavailable in this browser, so nothing will be remembered between visits.';

// The complete Ask Contract card shown at `decision`. Static content only —
// never derived from user text — so there is no path from typed input to an
// authoritative-sounding claim.
var ASK_CONTRACT = {
  asking: 'Approve this simulated demo so it can show a completed run.',
  whatItDoes: 'Marks this local demo as approved and moves on to the Result screen. No repository, deployment, credential, or account is touched.',
  why: 'Approval is the only way to see the full simulated journey through to its result in this prototype.',
  risksUndo: 'None: nothing is written outside this browser tab. Reset (top of every screen) clears the one thing this demo ever saves at any time.',
  recommendation: 'Approve when you are ready to see the simulated result. Choose Wait if you want to keep reviewing the preview first.',
  safeWait: SAFE_WAIT_NOTICE,
  destination: 'Nowhere outside this browser tab. This demo has no GitHub connection, so there is no real destination to send anything to.',
  evidenceStatus: 'Simulated only: no real check, build, test, or deployment evidence exists behind this card.'
};

// ---------------------------------------------------------------------------
// Small pure helpers
// ---------------------------------------------------------------------------

// UTF-8 byte length, measured the way the contract requires: TextEncoder in
// the browser, Buffer.byteLength in Node. Never a character-length proxy —
// those two diverge for any non-ASCII text.
function utf8ByteLength(str) {
  if (typeof TextEncoder !== 'undefined') {
    return new TextEncoder().encode(str).length;
  }
  if (typeof Buffer !== 'undefined') {
    return Buffer.byteLength(str, 'utf8');
  }
  /* istanbul ignore next -- neither runtime primitive is ever absent in the
     two environments this file actually runs in (a modern browser or Node);
     kept only as a last-resort so this never throws. */
  return String(str).length;
}

function isValidProjectId(id) {
  if (typeof id !== 'string') return false;
  for (var i = 0; i < ALLOWLISTED_PROJECTS.length; i += 1) {
    if (ALLOWLISTED_PROJECTS[i].id === id) return true;
  }
  return false;
}

function projectById(id) {
  for (var i = 0; i < ALLOWLISTED_PROJECTS.length; i += 1) {
    if (ALLOWLISTED_PROJECTS[i].id === id) return ALLOWLISTED_PROJECTS[i];
  }
  return null;
}

function isValidRequestText(text) {
  return typeof text === 'string' && text.trim().length > 0 && utf8ByteLength(text) <= REQUEST_MAX_BYTES;
}

function isValidFeedbackText(text) {
  return typeof text === 'string' && text.trim().length > 0 && utf8ByteLength(text) <= FEEDBACK_MAX_BYTES;
}

// The exact-shape check for a persisted value: exactly the two keys
// `schema` and `projectId`, the exact schema string, and an allowlisted
// project id. Anything else — an extra key, a renamed key, a stale/foreign
// schema, an unknown project id — is rejected.
function isValidPersisted(parsed) {
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return false;
  var keys = Object.keys(parsed);
  if (keys.length !== 2) return false;
  if (keys.indexOf('schema') === -1 || keys.indexOf('projectId') === -1) return false;
  if (parsed.schema !== SCHEMA) return false;
  if (typeof parsed.projectId !== 'string') return false;
  if (!isValidProjectId(parsed.projectId)) return false;
  return true;
}

// The single writer for the persisted value, so the shape and key order
// stay identical wherever this is called from.
function serializePersisted(projectId) {
  return JSON.stringify({ schema: SCHEMA, projectId: projectId });
}

function assign(state, patch) {
  var next = {
    screen: state.screen,
    projectId: state.projectId,
    requestText: state.requestText,
    feedback: state.feedback,
    notice: state.notice
  };
  var key;
  for (key in patch) {
    if (Object.prototype.hasOwnProperty.call(patch, key)) next[key] = patch[key];
  }
  return next;
}

function withNotice(state, notice) {
  return assign(state, { notice: notice });
}

function initialState() {
  return { screen: 'connect', projectId: null, requestText: null, feedback: [], notice: null };
}

// ---------------------------------------------------------------------------
// Hydration — explicitly NOT a workflow transition (see the contract's
// "Persistence and trust boundary" section). It only ever produces `connect`
// (nothing, or something invalid, was saved) or `request` (a valid binding
// was saved). No other screen is ever reachable from a page load.
// ---------------------------------------------------------------------------

// rawValue is exactly what `localStorage.getItem(STORAGE_KEY)` returns:
// a string when present, or `null` when the key does not exist. `null`
// is an ordinary first visit, not an error, so it carries no notice.
function hydrate(rawValue) {
  if (rawValue === null || rawValue === undefined) return initialState();
  if (typeof rawValue !== 'string') return withNotice(initialState(), INVALID_STORAGE_NOTICE);
  if (utf8ByteLength(rawValue) > STORAGE_MAX_BYTES) return withNotice(initialState(), INVALID_STORAGE_NOTICE);
  var parsed;
  try {
    parsed = JSON.parse(rawValue);
  } catch (e) {
    return withNotice(initialState(), INVALID_STORAGE_NOTICE);
  }
  if (!isValidPersisted(parsed)) return withNotice(initialState(), INVALID_STORAGE_NOTICE);
  return { screen: 'request', projectId: parsed.projectId, requestText: null, feedback: [], notice: null };
}

// Used when reading storage itself threw (private-mode / disabled storage).
// Distinct from "nothing was saved" so the accessible notice only appears
// when something actually went wrong.
function hydrateUnavailable() {
  return withNotice(initialState(), STORAGE_UNAVAILABLE_NOTICE);
}

// ---------------------------------------------------------------------------
// The reducer. Every legal pair from the contract's transition table is one
// `if` below; everything else falls through to "return state unchanged".
// `reset` is handled once, before the per-screen switch, because it is legal
// from every state alike.
// ---------------------------------------------------------------------------

function transition(state, action, payload) {
  if (!state || typeof state.screen !== 'string') return initialState();

  if (action === 'reset') return initialState();

  switch (state.screen) {
    case 'connect':
      if (action === 'select_project' && isValidProjectId(payload)) {
        return assign(state, { screen: 'readiness', projectId: payload, notice: null });
      }
      return state;

    case 'readiness':
      if (action === 'continue') return assign(state, { screen: 'request', notice: null });
      if (action === 'back') return assign(state, { screen: 'connect', notice: null });
      return state;

    case 'request':
      if (action === 'create_blueprint' && isValidRequestText(payload)) {
        return assign(state, { screen: 'blueprint', requestText: payload, notice: null });
      }
      if (action === 'back') return assign(state, { screen: 'readiness', notice: null });
      return state;

    case 'blueprint':
      // Defense in depth: `request` already gates entry to `blueprint` on a
      // valid request, but `start_demo` re-checks it so a direct/adversarial
      // call can never open `work` on invalid or missing input.
      if (action === 'start_demo' && isValidRequestText(state.requestText)) {
        return assign(state, { screen: 'work:understanding', notice: null });
      }
      if (action === 'back') return assign(state, { screen: 'request', notice: null });
      return state;

    case 'work:understanding':
    case 'work:planning':
    case 'work:building':
    case 'work:checking':
      if (action === 'advance_work') {
        var current = state.screen.slice('work:'.length);
        var idx = WORK_SUBSTAGES.indexOf(current);
        return assign(state, { screen: 'work:' + WORK_SUBSTAGES[idx + 1], notice: null });
      }
      return state;

    case 'work:ready_for_review':
      if (action === 'open_preview') return assign(state, { screen: 'preview', notice: null });
      return state;

    case 'preview':
      if (action === 'submit_feedback' && isValidFeedbackText(payload)) {
        return assign(state, { screen: 'preview', feedback: state.feedback.concat([payload]), notice: null });
      }
      if (action === 'continue') return assign(state, { screen: 'decision', notice: null });
      if (action === 'back') return assign(state, { screen: 'work:ready_for_review', notice: null });
      return state;

    case 'decision':
      if (action === 'approve_demo') return assign(state, { screen: 'result', notice: null });
      if (action === 'wait') return assign(state, { screen: 'decision', notice: SAFE_WAIT_NOTICE });
      if (action === 'back') return assign(state, { screen: 'preview', notice: null });
      return state;

    case 'result':
      // Terminal: only `reset` (handled above) leaves this screen.
      return state;

    default:
      return state;
  }
}

// ---------------------------------------------------------------------------
// CommonJS export for Node tests. A no-op in a browser, where `module` is
// undefined.
// ---------------------------------------------------------------------------

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    SCHEMA: SCHEMA,
    STORAGE_KEY: STORAGE_KEY,
    STORAGE_MAX_BYTES: STORAGE_MAX_BYTES,
    REQUEST_MAX_BYTES: REQUEST_MAX_BYTES,
    FEEDBACK_MAX_BYTES: FEEDBACK_MAX_BYTES,
    ALLOWLISTED_PROJECTS: ALLOWLISTED_PROJECTS,
    WORK_SUBSTAGES: WORK_SUBSTAGES,
    WORK_SUBSTAGE_LABELS: WORK_SUBSTAGE_LABELS,
    RESULT_TEXT: RESULT_TEXT,
    SAFE_WAIT_NOTICE: SAFE_WAIT_NOTICE,
    INVALID_STORAGE_NOTICE: INVALID_STORAGE_NOTICE,
    STORAGE_UNAVAILABLE_NOTICE: STORAGE_UNAVAILABLE_NOTICE,
    ASK_CONTRACT: ASK_CONTRACT,
    utf8ByteLength: utf8ByteLength,
    isValidProjectId: isValidProjectId,
    projectById: projectById,
    isValidRequestText: isValidRequestText,
    isValidFeedbackText: isValidFeedbackText,
    isValidPersisted: isValidPersisted,
    serializePersisted: serializePersisted,
    initialState: initialState,
    hydrate: hydrate,
    hydrateUnavailable: hydrateUnavailable,
    transition: transition
  };
}

// ---------------------------------------------------------------------------
// DOM WIRING — browser only. `typeof document === "undefined"` in Node, so
// none of this ever runs there; it exists solely to drive the page.
// ---------------------------------------------------------------------------

if (typeof document !== 'undefined') {
  (function () {
    var state = initialState();

    function byId(id) {
      return document.getElementById(id);
    }

    function screenBaseName(screen) {
      return screen.indexOf('work:') === 0 ? 'work' : screen;
    }

    function setText(id, text) {
      var el = byId(id);
      if (el) el.textContent = text;
    }

    function loadPersisted() {
      try {
        var raw = window.localStorage.getItem(STORAGE_KEY);
        return hydrate(raw);
      } catch (e) {
        return hydrateUnavailable();
      }
    }

    function savePersisted(projectId) {
      try {
        window.localStorage.setItem(STORAGE_KEY, serializePersisted(projectId));
      } catch (e) {
        // Storage may be unavailable (private mode, quota, disabled). The
        // demo still works for this session; it just will not be
        // remembered next time. No user-visible error is required for a
        // best-effort convenience write.
      }
    }

    function clearPersisted() {
      try {
        window.localStorage.removeItem(STORAGE_KEY);
      } catch (e) {
        // Same best-effort reasoning as savePersisted.
      }
    }

    function clearFeedbackList() {
      var list = byId('preview-feedback-list');
      if (!list) return;
      while (list.firstChild) list.removeChild(list.firstChild);
    }

    function renderFeedbackList() {
      var list = byId('preview-feedback-list');
      if (!list) return;
      clearFeedbackList();
      state.feedback.forEach(function (entry, index) {
        var item = document.createElement('li');
        item.textContent = 'Feedback ' + (index + 1) + ': ' + entry;
        list.appendChild(item);
      });
    }

    function renderNotice() {
      var el = byId('app-notice');
      if (!el) return;
      if (state.notice) {
        el.textContent = state.notice;
        el.hidden = false;
      } else {
        el.textContent = '';
        el.hidden = true;
      }
    }

    function renderWork() {
      var substage = state.screen.indexOf('work:') === 0 ? state.screen.slice('work:'.length) : null;
      WORK_SUBSTAGES.forEach(function (name) {
        var li = byId('work-step-' + name);
        if (!li) return;
        var isActive = name === substage;
        var isDone = substage !== null && WORK_SUBSTAGES.indexOf(name) < WORK_SUBSTAGES.indexOf(substage);
        li.classList.toggle('is-active', isActive);
        li.classList.toggle('is-done', isDone);
        if (isActive) {
          li.setAttribute('aria-current', 'step');
        } else {
          li.removeAttribute('aria-current');
        }
      });
      var actionButton = byId('work-action');
      if (actionButton && substage) {
        if (substage === 'ready_for_review') {
          actionButton.textContent = 'Open preview';
          actionButton.dataset.action = 'open_preview';
        } else {
          actionButton.textContent = 'Advance to ' + WORK_SUBSTAGE_LABELS[WORK_SUBSTAGES[WORK_SUBSTAGES.indexOf(substage) + 1]];
          actionButton.dataset.action = 'advance_work';
        }
      }
    }

    function render() {
      var screens = document.querySelectorAll('.screen');
      for (var i = 0; i < screens.length; i += 1) screens[i].hidden = true;
      var base = screenBaseName(state.screen);
      var current = byId('screen-' + base);
      if (current) current.hidden = false;

      renderNotice();

      var project = projectById(state.projectId);
      setText('readiness-project-name', project ? project.name : '');
      setText('blueprint-project-name', project ? project.name : '');
      setText('blueprint-goal', state.requestText || '');

      var startDemoButton = byId('blueprint-start');
      if (startDemoButton) startDemoButton.disabled = !isValidRequestText(state.requestText);

      renderWork();
      renderFeedbackList();
    }

    function dispatch(action, payload) {
      if (action === 'reset') clearPersisted();
      state = transition(state, action, payload);
      if (action === 'select_project' && state.screen === 'readiness') {
        savePersisted(state.projectId);
      }
      render();
    }

    function wireClick(id, action, getPayload) {
      var el = byId(id);
      if (!el) return;
      el.addEventListener('click', function () {
        dispatch(action, getPayload ? getPayload() : undefined);
      });
    }

    function wireByteCounter(textareaId, counterId, max) {
      var textarea = byId(textareaId);
      var counter = byId(counterId);
      if (!textarea || !counter) return;
      var update = function () {
        var bytes = utf8ByteLength(textarea.value);
        counter.textContent = bytes + ' / ' + max + ' bytes';
        counter.classList.toggle('is-over', bytes > max);
      };
      textarea.addEventListener('input', update);
      update();
    }

    document.addEventListener('DOMContentLoaded', function () {
      // Project-selection buttons (static, one per allowlisted example).
      var projectButtons = document.querySelectorAll('[data-select-project]');
      for (var p = 0; p < projectButtons.length; p += 1) {
        (function (button) {
          button.addEventListener('click', function () {
            dispatch('select_project', button.getAttribute('data-select-project'));
          });
        })(projectButtons[p]);
      }

      wireClick('readiness-continue', 'continue');
      wireClick('readiness-back', 'back');

      wireClick('request-submit', 'create_blueprint', function () {
        return byId('request-text').value;
      });
      wireClick('request-back', 'back');
      wireByteCounter('request-text', 'request-counter', REQUEST_MAX_BYTES);
      byId('request-text').addEventListener('input', function () {
        var submit = byId('request-submit');
        if (submit) submit.disabled = !isValidRequestText(byId('request-text').value);
      });

      wireClick('blueprint-start', 'start_demo');
      wireClick('blueprint-back', 'back');

      var workAction = byId('work-action');
      if (workAction) {
        workAction.addEventListener('click', function () {
          dispatch(workAction.dataset.action || 'advance_work');
        });
      }

      wireClick('preview-submit-feedback', 'submit_feedback', function () {
        return byId('preview-feedback-text').value;
      });
      byId('preview-feedback-text').addEventListener('input', function () {
        var submit = byId('preview-submit-feedback');
        if (submit) submit.disabled = !isValidFeedbackText(byId('preview-feedback-text').value);
        var counter = byId('preview-feedback-counter');
        if (counter) {
          var bytes = utf8ByteLength(byId('preview-feedback-text').value);
          counter.textContent = bytes + ' / ' + FEEDBACK_MAX_BYTES + ' bytes';
          counter.classList.toggle('is-over', bytes > FEEDBACK_MAX_BYTES);
        }
      });
      wireClick('preview-continue', 'continue', function () { return undefined; });
      wireClick('preview-back', 'back');
      // Clear the feedback textbox after a successful submit so the byte
      // counter and submit button re-evaluate against an empty field.
      var submitFeedbackButton = byId('preview-submit-feedback');
      if (submitFeedbackButton) {
        submitFeedbackButton.addEventListener('click', function () {
          var textarea = byId('preview-feedback-text');
          if (textarea && isValidFeedbackText(textarea.value)) {
            textarea.value = '';
            textarea.dispatchEvent(new Event('input'));
          }
        });
      }

      wireClick('decision-approve', 'approve_demo');
      wireClick('decision-wait', 'wait');
      wireClick('decision-back', 'back');

      wireClick('result-reset', 'reset');

      var resetButtons = document.querySelectorAll('[data-reset]');
      for (var r = 0; r < resetButtons.length; r += 1) {
        resetButtons[r].addEventListener('click', function () {
          dispatch('reset');
        });
      }

      // Fill in the static Ask Contract card and decision-card copy once.
      setText('ask-contract-asking', ASK_CONTRACT.asking);
      setText('ask-contract-what', ASK_CONTRACT.whatItDoes);
      setText('ask-contract-why', ASK_CONTRACT.why);
      setText('ask-contract-risks', ASK_CONTRACT.risksUndo);
      setText('ask-contract-recommendation', ASK_CONTRACT.recommendation);
      setText('ask-contract-safe-wait', ASK_CONTRACT.safeWait);
      setText('ask-contract-destination', ASK_CONTRACT.destination);
      setText('ask-contract-evidence', ASK_CONTRACT.evidenceStatus);
      setText('result-text', RESULT_TEXT);

      state = loadPersisted();
      render();
    });
  })();
}
