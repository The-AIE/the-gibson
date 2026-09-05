(function (root) {
  "use strict";

  const STORAGE_KEY = "gibson.owner-journey-prototype.local.v1";
  const STORAGE_SCHEMA = "gibson.owner-journey-prototype.local.v1";
  const RESULT_COPY = "Demo complete. No code was changed or deployed.";
  const REQUEST_LIMIT = 4096;
  const FEEDBACK_LIMIT = 2048;
  const BINDING_LIMIT = 256;

  const PROJECTS = Object.freeze([
    Object.freeze({ id: "acme/storefront", label: "Acme / Storefront" }),
    Object.freeze({ id: "northstar/booking", label: "Northstar / Booking" }),
    Object.freeze({ id: "signal/customer-portal", label: "Signal / Customer portal" })
  ]);

  const WORK_STAGES = Object.freeze([
    "understanding",
    "planning",
    "building",
    "checking",
    "ready_for_review"
  ]);

  const WORK_LABELS = Object.freeze({
    understanding: "Understanding",
    planning: "Planning",
    building: "Building",
    checking: "Checking",
    ready_for_review: "Ready for review"
  });

  const JOURNEY = Object.freeze([
    Object.freeze({ screen: "connect", label: "Project" }),
    Object.freeze({ screen: "readiness", label: "Read-only check" }),
    Object.freeze({ screen: "request", label: "Request" }),
    Object.freeze({ screen: "blueprint", label: "Blueprint" }),
    Object.freeze({ screen: "work", label: "Work" }),
    Object.freeze({ screen: "preview", label: "Preview" }),
    Object.freeze({ screen: "decision", label: "Decision" }),
    Object.freeze({ screen: "result", label: "Release" })
  ]);

  const HEADINGS = Object.freeze({
    connect: "Connect a project",
    readiness: "Review the read-only check",
    request: "Describe your request",
    blueprint: "Review the blueprint",
    work: "Follow the work",
    preview: "Review the preview",
    decision: "Make the decision",
    result: "Release result"
  });

  const SUMMARIES = Object.freeze({
    connect: "Choose an example project to see what Gibson would ask to read—and what stays off limits.",
    readiness: "See the kind of readiness summary Gibson would give before accepting a request.",
    request: "Tell Gibson the outcome you want in the same language you would use with a teammate.",
    blueprint: "Confirm the goal, boundaries, and success criteria before any work begins.",
    work: "See meaningful progress without having to supervise agents, tools, or technical logs.",
    preview: "Judge the outcome, compare the experience, and leave feedback before any release decision.",
    decision: "Choose only after the consequence, evidence, recommendation, and safe alternative are clear.",
    result: "The walkthrough ends with an honest receipt of what did—and did not—happen."
  });

  function utf8Bytes(value) {
    const text = String(value);
    if (typeof TextEncoder !== "undefined") {
      return new TextEncoder().encode(text).length;
    }
    if (typeof Buffer !== "undefined") {
      return Buffer.byteLength(text, "utf8");
    }
    throw new Error("UTF-8 byte measurement is unavailable.");
  }

  function projectAllowed(projectId) {
    return PROJECTS.some(function (project) {
      return project.id === projectId;
    });
  }

  function initialState(notice) {
    return {
      screen: "connect",
      workStage: null,
      projectId: null,
      request: "",
      feedback: "",
      waitNotice: "",
      notice: notice || ""
    };
  }

  function evolve(state, changes) {
    return Object.assign({}, state, changes, { notice: "" });
  }

  function validateRequest(value) {
    if (typeof value !== "string") {
      return { ok: false, reason: "Enter a request in plain language." };
    }
    if (utf8Bytes(value) > REQUEST_LIMIT) {
      return { ok: false, reason: "Keep the request within 4,096 bytes." };
    }
    const trimmed = value.trim();
    if (!trimmed) {
      return { ok: false, reason: "Describe the outcome you want first." };
    }
    return { ok: true, value: trimmed };
  }

  function validateFeedback(value) {
    if (typeof value !== "string") {
      return { ok: false, reason: "Feedback must be text." };
    }
    if (utf8Bytes(value) > FEEDBACK_LIMIT) {
      return { ok: false, reason: "Keep feedback within 2,048 bytes." };
    }
    return { ok: true, value: value.trim() };
  }

  function transition(state, action) {
    if (!state || !action || typeof action.type !== "string") {
      return state;
    }

    if (action.type === "reset") {
      return initialState();
    }

    if (state.screen === "connect" && action.type === "select_project") {
      if (!projectAllowed(action.projectId)) {
        return state;
      }
      return evolve(state, { screen: "readiness", projectId: action.projectId });
    }

    if (state.screen === "readiness") {
      if (action.type === "continue") {
        return evolve(state, { screen: "request" });
      }
      if (action.type === "back") {
        return evolve(state, { screen: "connect" });
      }
      return state;
    }

    if (state.screen === "request") {
      if (action.type === "create_blueprint") {
        const requestCheck = validateRequest(action.request);
        if (!requestCheck.ok) {
          return state;
        }
        return evolve(state, { screen: "blueprint", request: requestCheck.value });
      }
      if (action.type === "back") {
        return evolve(state, { screen: "readiness" });
      }
      return state;
    }

    if (state.screen === "blueprint") {
      if (action.type === "start_demo") {
        return evolve(state, { screen: "work", workStage: WORK_STAGES[0] });
      }
      if (action.type === "back") {
        return evolve(state, { screen: "request" });
      }
      return state;
    }

    if (state.screen === "work") {
      const stageIndex = WORK_STAGES.indexOf(state.workStage);
      if (action.type === "advance_work" && stageIndex >= 0 && stageIndex < WORK_STAGES.length - 1) {
        return evolve(state, { workStage: WORK_STAGES[stageIndex + 1] });
      }
      if (action.type === "open_preview" && state.workStage === "ready_for_review") {
        return evolve(state, { screen: "preview" });
      }
      return state;
    }

    if (state.screen === "preview") {
      if (action.type === "submit_feedback") {
        const feedbackCheck = validateFeedback(action.feedback);
        if (!feedbackCheck.ok) {
          return state;
        }
        return evolve(state, { feedback: feedbackCheck.value });
      }
      if (action.type === "continue") {
        return evolve(state, { screen: "decision" });
      }
      if (action.type === "back") {
        return evolve(state, { screen: "work", workStage: "ready_for_review" });
      }
      return state;
    }

    if (state.screen === "decision") {
      if (action.type === "approve_demo") {
        return evolve(state, { screen: "result", waitNotice: "" });
      }
      if (action.type === "wait") {
        return evolve(state, {
          waitNotice: "Nothing changes while you wait. You can return to the preview or decide later."
        });
      }
      if (action.type === "back") {
        return evolve(state, { screen: "preview", waitNotice: "" });
      }
      return state;
    }

    return state;
  }

  function canonicalBinding(projectId) {
    return JSON.stringify({ schema: STORAGE_SCHEMA, projectId: projectId });
  }

  function bindingValid(raw) {
    if (typeof raw !== "string" || utf8Bytes(raw) > BINDING_LIMIT) {
      return false;
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (_error) {
      return false;
    }
    if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") {
      return false;
    }
    const keys = Object.keys(parsed).sort();
    if (keys.length !== 2 || keys[0] !== "projectId" || keys[1] !== "schema") {
      return false;
    }
    if (parsed.schema !== STORAGE_SCHEMA || !projectAllowed(parsed.projectId)) {
      return false;
    }
    return raw === canonicalBinding(parsed.projectId);
  }

  function discardBinding(storage) {
    try {
      storage.removeItem(STORAGE_KEY);
      return { ok: true, notice: "" };
    } catch (_error) {
      return {
        ok: false,
        notice: "Saved project access is unavailable. The prototype returned to a safe start."
      };
    }
  }

  function resolveStorage(host) {
    try {
      return host.localStorage;
    } catch (_error) {
      return {
        getItem: function () {
          throw new Error("Storage is unavailable.");
        },
        setItem: function () {
          throw new Error("Storage is unavailable.");
        },
        removeItem: function () {
          throw new Error("Storage is unavailable.");
        }
      };
    }
  }

  function hydrateBinding(storage) {
    let raw;
    try {
      raw = storage.getItem(STORAGE_KEY);
    } catch (_error) {
      return initialState("Saved project access is unavailable. Start again safely.");
    }

    if (raw === null) {
      return initialState();
    }
    if (!bindingValid(raw)) {
      const discarded = discardBinding(storage);
      return initialState(
        discarded.ok
          ? "An invalid saved project was cleared. Choose an example project to continue."
          : discarded.notice
      );
    }

    const projectId = JSON.parse(raw).projectId;
    return evolve(initialState(), { screen: "request", projectId: projectId });
  }

  function persistBinding(storage, projectId) {
    if (!projectAllowed(projectId)) {
      return { ok: false, notice: "Choose one of the example projects." };
    }
    const payload = canonicalBinding(projectId);
    if (utf8Bytes(payload) > BINDING_LIMIT) {
      return { ok: false, notice: "The example project could not be saved safely." };
    }
    try {
      storage.setItem(STORAGE_KEY, payload);
      return { ok: true, notice: "" };
    } catch (_error) {
      return {
        ok: false,
        notice: "Saved project access is unavailable. The prototype returned to a safe start."
      };
    }
  }

  const model = Object.freeze({
    STORAGE_KEY: STORAGE_KEY,
    STORAGE_SCHEMA: STORAGE_SCHEMA,
    RESULT_COPY: RESULT_COPY,
    REQUEST_LIMIT: REQUEST_LIMIT,
    FEEDBACK_LIMIT: FEEDBACK_LIMIT,
    BINDING_LIMIT: BINDING_LIMIT,
    PROJECTS: PROJECTS,
    WORK_STAGES: WORK_STAGES,
    WORK_LABELS: WORK_LABELS,
    JOURNEY: JOURNEY,
    HEADINGS: HEADINGS,
    initialState: initialState,
    transition: transition,
    validateRequest: validateRequest,
    validateFeedback: validateFeedback,
    utf8Bytes: utf8Bytes,
    canonicalBinding: canonicalBinding,
    bindingValid: bindingValid,
    hydrateBinding: hydrateBinding,
    persistBinding: persistBinding,
    discardBinding: discardBinding,
    resolveStorage: resolveStorage
  });

  if (typeof module !== "undefined" && module.exports) {
    module.exports = model;
  }

  if (!root || !root.document) {
    return;
  }

  const document = root.document;
  const screenRoot = document.getElementById("screen-root");
  const journeyRoot = document.getElementById("journey-steps");
  const liveStatus = document.getElementById("live-status");
  const resetButton = document.getElementById("reset-demo");
  const browserStorage = resolveStorage(root);
  let state = hydrateBinding(browserStorage);
  let screenNotice = "";

  function element(tagName, className, text) {
    const item = document.createElement(tagName);
    if (className) {
      item.className = className;
    }
    if (text !== undefined) {
      item.textContent = text;
    }
    return item;
  }

  function append(parent) {
    const children = Array.prototype.slice.call(arguments, 1);
    children.forEach(function (child) {
      if (child) {
        parent.appendChild(child);
      }
    });
    return parent;
  }

  function announce(message) {
    liveStatus.textContent = "";
    root.setTimeout(function () {
      liveStatus.textContent = message;
    }, 20);
  }

  function currentProject() {
    return PROJECTS.find(function (project) {
      return project.id === state.projectId;
    });
  }

  function screenHeader(screen, stepLabel) {
    const header = element("header", "screen-header");
    const kicker = element("p", "step-kicker", stepLabel + " · Simulation only");
    const heading = element("h1", "", HEADINGS[screen]);
    heading.id = "screen-title";
    heading.tabIndex = -1;
    const summary = element("p", "screen-summary", SUMMARIES[screen]);
    append(header, kicker, heading, summary);
    return header;
  }

  function notice(message, warning) {
    if (!message) {
      return null;
    }
    const box = element("div", warning ? "notice is-warning" : "notice");
    box.setAttribute("role", "status");
    append(box, element("span", "", warning ? "!" : "i"), element("span", "", message));
    return box;
  }

  function actionButton(label, onClick, secondary) {
    const button = element("button", secondary ? "button secondary" : "button", label);
    button.type = "button";
    button.addEventListener("click", onClick);
    return button;
  }

  function actions(primary, back) {
    const row = element("div", "actions");
    append(row, primary, back);
    return row;
  }

  function evidence(lines) {
    const details = element("details", "evidence");
    const summary = element("summary", "", "Evidence and boundaries");
    const list = element("ul");
    lines.forEach(function (line) {
      list.appendChild(element("li", "", line));
    });
    append(details, summary, list);
    return details;
  }

  function applyAction(action, announcement) {
    const next = transition(state, action);
    if (next === state) {
      return false;
    }
    state = next;
    screenNotice = "";
    render();
    if (announcement) {
      announce(announcement);
    }
    return true;
  }

  function renderJourney() {
    const currentIndex = JOURNEY.findIndex(function (step) {
      return step.screen === state.screen;
    });
    const fragment = document.createDocumentFragment();
    JOURNEY.forEach(function (step, index) {
      const item = element("li", "journey-step", step.label);
      if (index < currentIndex) {
        item.classList.add("is-complete");
      }
      if (index === currentIndex) {
        item.classList.add("is-current");
        item.setAttribute("aria-current", "step");
      }
      fragment.appendChild(item);
    });
    journeyRoot.replaceChildren(fragment);
  }

  function renderConnect() {
    const fragment = document.createDocumentFragment();
    append(fragment, screenHeader("connect", "Step 1 of 8"));
    append(fragment, notice(state.notice || screenNotice, true));

    const panel = element("section", "panel");
    panel.setAttribute("aria-labelledby", "project-label");
    const label = element("label", "field-label", "Example project");
    label.id = "project-label";
    label.htmlFor = "project-select";
    const select = element("select");
    select.id = "project-select";
    PROJECTS.forEach(function (project) {
      const option = element("option", "", project.label);
      option.value = project.id;
      select.appendChild(option);
    });
    const hint = element(
      "p",
      "field-hint",
      "These are fictional examples. Selecting one grants no access and contacts no service."
    );

    const permissionList = element("ul", "permission-list");
    [
      ["Read the selected project", "Future Gibson would request repository content and metadata for this project only."],
      ["No write permission", "Connecting would not authorize branches, pull requests, merges, releases, or deployments."],
      ["Owner decisions stay gated", "Secrets, billing, production, and other consequential actions would still require a clear ask."]
    ].forEach(function (copy) {
      const item = element("li", "permission-item");
      const body = element("div");
      append(body, element("strong", "", copy[0]), element("p", "", copy[1]));
      append(item, element("span", "permission-icon", "✓"), body);
      permissionList.appendChild(item);
    });

    const primary = actionButton("Connect example project", function () {
      const projectId = select.value;
      const saved = persistBinding(browserStorage, projectId);
      if (!saved.ok) {
        state = initialState(saved.notice);
        render();
        announce(saved.notice);
        return;
      }
      applyAction(
        { type: "select_project", projectId: projectId },
        "Example project selected. Showing the simulated read-only check."
      );
    });

    append(panel, label, select, hint, permissionList, actions(primary));
    append(
      panel,
      evidence([
        "No account, token, credential, or real repository is used.",
        "Only the selected example-project identifier is saved in this browser.",
        "This screen demonstrates the permission explanation; it does not grant permission."
      ])
    );
    append(fragment, panel);
    return fragment;
  }

  function renderReadiness() {
    const fragment = document.createDocumentFragment();
    append(fragment, screenHeader("readiness", "Step 2 of 8"));
    append(
      fragment,
      notice("Simulated check: Gibson did not inspect a repository or verify any real condition.", true)
    );
    const panel = element("section", "panel");
    const project = currentProject();
    append(panel, element("p", "field-label", project ? project.label : "Example project"));
    const checkList = element("ul", "check-list");
    [
      ["Project structure", "The selected project appears ready for a bounded request."],
      ["Safety boundaries", "Owner approval would remain required for consequential actions."],
      ["Starting recommendation", "Begin with one small, previewable product improvement."]
    ].forEach(function (copy) {
      const item = element("li", "check-item");
      const body = element("div");
      append(
        body,
        element("strong", "", copy[0]),
        element("p", "", copy[1]),
        element("span", "check-badge", "Simulated")
      );
      append(item, element("span", "check-icon", "✓"), body);
      checkList.appendChild(item);
    });
    const primary = actionButton("Continue to request", function () {
      applyAction({ type: "continue" }, "Ready for your request.");
    });
    const back = actionButton("Back", function () {
      applyAction({ type: "back" });
    }, true);
    append(panel, checkList, actions(primary, back));
    append(
      panel,
      evidence([
        "The three checks are illustrative copy, not results from an audit.",
        "No readiness score, timestamp, cost, or approval has been fabricated.",
        "Continuing authorizes no work; it only opens the request screen."
      ])
    );
    append(fragment, panel);
    return fragment;
  }

  function renderRequest() {
    const fragment = document.createDocumentFragment();
    append(fragment, screenHeader("request", "Step 3 of 8"));
    append(fragment, notice(state.notice || screenNotice, Boolean(screenNotice)));
    const panel = element("section", "panel");
    const label = element("label", "field-label", "What would you like to improve?");
    label.htmlFor = "request-input";
    const input = element("textarea");
    input.id = "request-input";
    input.maxLength = REQUEST_LIMIT;
    input.placeholder = "Example: Make the account sign-up experience clearer and easier to complete.";
    input.value = state.request;
    const count = element("p", "character-count");
    const updateCount = function () {
      count.textContent = utf8Bytes(input.value) + " / " + REQUEST_LIMIT + " bytes";
    };
    input.addEventListener("input", updateCount);
    updateCount();
    const hint = element(
      "p",
      "field-hint",
      "Describe the outcome. Gibson would turn it into boundaries and success criteria before work."
    );
    const primary = actionButton("Create blueprint", function () {
      const checked = validateRequest(input.value);
      if (!checked.ok) {
        screenNotice = checked.reason;
        announce(checked.reason);
        render();
        return;
      }
      applyAction(
        { type: "create_blueprint", request: input.value },
        "Blueprint created for review. No work has started."
      );
    });
    const back = actionButton("Back", function () {
      applyAction({ type: "back" });
    }, true);
    append(panel, label, input, count, hint, actions(primary, back));
    append(
      panel,
      evidence([
        "Request text is held in memory only and is not saved when this page closes or reloads.",
        "Text is treated only as display data; it cannot become a permission, destination, or status.",
        "Creating a blueprint is a planning step, not authorization to change code."
      ])
    );
    append(fragment, panel);
    return fragment;
  }

  function blueprintCard(title, body, wide) {
    const card = element("article", wide ? "blueprint-card is-wide" : "blueprint-card");
    append(card, element("h2", "", title), element("p", "", body));
    return card;
  }

  function renderBlueprint() {
    const fragment = document.createDocumentFragment();
    append(fragment, screenHeader("blueprint", "Step 4 of 8"));
    append(fragment, notice("Blueprint simulation: reviewing this does not authorize real work.", true));
    const panel = element("section", "panel");
    const grid = element("div", "blueprint-grid");
    append(
      grid,
      blueprintCard("Goal", state.request, true),
      blueprintCard("Scope", "One visible product improvement with a preview before any release decision."),
      blueprintCard("Success criteria", "The intended outcome is understandable, usable, and reversible."),
      blueprintCard("Assumptions", "Example project only; no production data, credentials, or external services."),
      blueprintCard("Owner decisions", "Review the preview. Decide whether to approve the demonstration or wait safely.")
    );
    const primary = actionButton("Start demonstration", function () {
      applyAction({ type: "start_demo" }, "Demonstration started at Understanding.");
    });
    const back = actionButton("Edit request", function () {
      applyAction({ type: "back" });
    }, true);
    append(panel, grid, actions(primary, back));
    append(
      panel,
      evidence([
        "The blueprint is explanatory product copy, not an implementation contract or agent instruction.",
        "No worker, repository, or external tool starts from this button.",
        "A production Gibson would preserve the agreed boundary and surface later owner decisions explicitly."
      ])
    );
    append(fragment, panel);
    return fragment;
  }

  function renderWork() {
    const fragment = document.createDocumentFragment();
    append(fragment, screenHeader("work", "Step 5 of 8"));
    append(fragment, notice("Simulated progress: no agent is running and no project files are changing.", true));
    const panel = element("section", "panel");
    const currentIndex = WORK_STAGES.indexOf(state.workStage);
    const list = element("ol", "work-stage-list");
    WORK_STAGES.forEach(function (stage, index) {
      const item = element("li", "work-stage");
      const number = element("span", "work-stage-number", index < currentIndex ? "✓" : String(index + 1));
      const body = element("div");
      const description = index < currentIndex ? "Complete in this simulation" : index === currentIndex ? "Current simulated stage" : "Waiting";
      append(body, element("strong", "", WORK_LABELS[stage]), element("small", "", description));
      if (index < currentIndex) {
        item.classList.add("is-complete");
      }
      if (index === currentIndex) {
        item.classList.add("is-current");
      }
      append(item, number, body);
      if (index === currentIndex) {
        item.appendChild(element("span", "status-tag", "Simulated"));
      }
      list.appendChild(item);
    });

    let primary;
    if (state.workStage === "ready_for_review") {
      primary = actionButton("Open preview", function () {
        applyAction({ type: "open_preview" }, "Preview ready for your review.");
      });
    } else {
      primary = actionButton("Advance demonstration", function () {
        applyAction({ type: "advance_work" }, "Advanced to the next simulated work stage.");
      });
    }
    append(panel, list, actions(primary));
    append(
      panel,
      evidence([
        "Stages advance only in order; the demonstration cannot skip directly to a decision or result.",
        "Technical agent logs are intentionally absent from the default owner experience.",
        "Every completed marker on this screen is explicitly scoped to the simulation."
      ])
    );
    append(fragment, panel);
    return fragment;
  }

  function previewCard(title, improved) {
    const card = element("article", "preview-card");
    const preview = element("div", improved ? "preview-window after" : "preview-window");
    append(
      preview,
      element("h3", "", improved ? "Create your account" : "Sign up"),
      element(
        "p",
        "",
        improved ? "Two quick steps. You can review everything before finishing." : "Enter your information below."
      ),
      element("div", "mock-field"),
      element("div", "mock-field"),
      element("div", "mock-action", improved ? "Continue securely" : "Submit")
    );
    append(card, element("h2", "", title), preview);
    return card;
  }

  function renderPreview() {
    const fragment = document.createDocumentFragment();
    append(fragment, screenHeader("preview", "Step 6 of 8"));
    append(fragment, notice("Visual simulation: this preview is not generated from or linked to a real project.", true));
    const panel = element("section", "panel");
    const grid = element("div", "preview-grid");
    append(grid, previewCard("Before", false), previewCard("Proposed", true));

    const feedback = element("div", "feedback-panel");
    const label = element("label", "field-label", "Preview feedback (optional)");
    label.htmlFor = "feedback-input";
    const input = element("textarea");
    input.id = "feedback-input";
    input.maxLength = FEEDBACK_LIMIT;
    input.placeholder = "Example: Keep the clearer heading, but make the button less prominent.";
    input.value = state.feedback;
    const count = element("p", "character-count");
    const updateCount = function () {
      count.textContent = utf8Bytes(input.value) + " / " + FEEDBACK_LIMIT + " bytes";
    };
    input.addEventListener("input", updateCount);
    updateCount();
    const save = actionButton("Save feedback locally", function () {
      const checked = validateFeedback(input.value);
      if (!checked.ok) {
        screenNotice = checked.reason;
        announce(checked.reason);
        render();
        return;
      }
      applyAction(
        { type: "submit_feedback", feedback: input.value },
        "Feedback held for this browser session only."
      );
    }, true);
    append(feedback, label, input, count, save);
    if (state.feedback) {
      append(feedback, element("p", "feedback-receipt", "Saved for this session: " + state.feedback));
    }

    const primary = actionButton("Continue to decision", function () {
      applyAction({ type: "continue" }, "Decision card ready.");
    });
    const back = actionButton("Back to work", function () {
      applyAction({ type: "back" });
    }, true);
    append(panel, grid, feedback, actions(primary, back));
    append(
      panel,
      evidence([
        "The before-and-after cards are handcrafted examples, not screenshots or deployed pages.",
        "Feedback is treated as text and held in memory only; it cannot change authority or status.",
        "Continuing opens a decision explanation. It does not approve or release anything."
      ])
    );
    append(fragment, panel);
    return fragment;
  }

  function decisionItem(title, body, wide) {
    const item = element("article", wide ? "decision-card-item is-wide" : "decision-card-item");
    append(item, element("h2", "", title), element("p", "", body));
    return item;
  }

  function renderDecision() {
    const fragment = document.createDocumentFragment();
    append(fragment, screenHeader("decision", "Step 7 of 8"));
    append(fragment, notice(state.waitNotice, false));
    const panel = element("section", "panel");
    const lead = element("div", "decision-lead");
    const leadCopy = element("div");
    append(
      leadCopy,
      element("h2", "", "Release the proposed experience?"),
      element("p", "", "This card demonstrates how Gibson would ask before a consequential action.")
    );
    append(lead, leadCopy, element("span", "simulation-badge", "Simulation only"));

    const grid = element("div", "decision-grid");
    append(
      grid,
      decisionItem("What I'm asking", "Approve the demonstration so you can see the final prototype receipt.", true),
      decisionItem("What it does", "Moves this local walkthrough to its final result screen. No other system changes."),
      decisionItem("Why", "Completes the owner journey and demonstrates an explicit release checkpoint."),
      decisionItem("Risks / undo", "No real-world risk. Reset returns the prototype to the first screen and clears its project binding."),
      decisionItem("Recommendation", "Approve the demonstration if the journey is clear; otherwise return to the preview."),
      decisionItem("Safe wait", "Waiting changes nothing. The prototype remains on this decision screen."),
      decisionItem("Destination", "This browser tab only. There is no branch, pull request, environment, or deployment."),
      decisionItem("Evidence status", "Prototype screens exercised; no repository, automated check, review, or release evidence asserted.")
    );

    const primary = actionButton("Approve demonstration", function () {
      applyAction({ type: "approve_demo" }, "Demonstration complete. No code was changed or deployed.");
    });
    const wait = actionButton("Wait safely", function () {
      applyAction({ type: "wait" }, "Nothing changed. Waiting is safe.");
    }, true);
    const back = actionButton("Back to preview", function () {
      applyAction({ type: "back" });
    }, true);
    const row = element("div", "actions");
    append(row, primary, wait, back);
    append(panel, lead, grid, row);
    append(
      panel,
      evidence([
        "Approve and Wait are local demonstration controls, not authorization or approval records.",
        "Neither control contacts a service, navigates elsewhere, writes project data, or starts a release.",
        "The evidence status explicitly avoids asserting checks that did not occur."
      ])
    );
    append(fragment, panel);
    return fragment;
  }

  function renderResult() {
    const fragment = document.createDocumentFragment();
    append(fragment, screenHeader("result", "Step 8 of 8"));
    const panel = element("section", "panel");
    append(
      panel,
      element("div", "result-mark", "✓"),
      element("p", "result-statement", RESULT_COPY),
      element(
        "p",
        "screen-summary",
        "You experienced Gibson's intended path from a plain-language request to an owner-controlled decision."
      )
    );
    const primary = actionButton("Start again", function () {
      const discarded = discardBinding(browserStorage);
      state = initialState(discarded.notice);
      screenNotice = "";
      render();
      announce(discarded.ok ? "Prototype reset." : discarded.notice);
    });
    append(panel, actions(primary));
    append(
      panel,
      evidence([
        "The result certifies only that the local walkthrough reached its final screen.",
        "No code, repository, permission, review, approval record, environment, or deployment was created.",
        "A production receipt would need authoritative evidence that this prototype intentionally does not invent."
      ])
    );
    append(fragment, panel);
    return fragment;
  }

  const renderers = Object.freeze({
    connect: renderConnect,
    readiness: renderReadiness,
    request: renderRequest,
    blueprint: renderBlueprint,
    work: renderWork,
    preview: renderPreview,
    decision: renderDecision,
    result: renderResult
  });

  function render() {
    renderJourney();
    const renderer = renderers[state.screen] || renderConnect;
    screenRoot.replaceChildren(renderer());
    const heading = document.getElementById("screen-title");
    if (heading) {
      heading.focus();
    }
  }

  resetButton.addEventListener("click", function () {
    const discarded = discardBinding(browserStorage);
    state = transition(state, { type: "reset" });
    if (!discarded.ok) {
      state.notice = discarded.notice;
    }
    screenNotice = "";
    render();
    announce(discarded.ok ? "Prototype reset." : discarded.notice);
  });

  render();
})(typeof globalThis !== "undefined" ? globalThis : this);
