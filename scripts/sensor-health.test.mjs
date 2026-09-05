#!/usr/bin/env node
// sensor-health.test.mjs — #256 matrix + coordinator gaps.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  REQUIRED_REPO_OWNED_PATHS,
  REASON,
  SCHEMA_ID,
  STANDING_ISSUE_NUMBER,
  STATES,
  assessRun,
  buildFingerprint,
  classifySensor,
  compareUpdatedAtThenId,
  evaluateTargetJobs,
  freezeContext,
  isExemptNonTargetSkip,
  joinPolicies,
  loadRegistryFile,
  partitionRuns,
  PAGES_WORKFLOW_PATH,
  publishStandingUnknown,
  renderIssueBody,
  repoRootFromModule,
  runSensorHealthAudit,
  selectLatestRun,
  shouldComment,
  validateRegistry,
} from "./sensor-health-lib.mjs";
{
  const entry = process.argv[1];
  let isMain = false;
  try {
    isMain = entry && pathToFileURL(resolve(entry)).href === import.meta.url;
  } catch {
    isMain = false;
  }
  if (isMain) {
    const unknown = process.argv.slice(2).filter((a) => a.startsWith("-"));
    if (unknown.length) {
      console.error(
        `sensor-health.test: unknown flag: ${unknown.join(" ")}\nusage: node --test scripts/sensor-health.test.mjs`
      );
      process.exit(2);
    }
  }
}
const ROOT = repoRootFromModule(import.meta.url);
const OBS = new Date("2026-08-30T12:00:00.000Z");
const HEAD = "fde8246169cfb6d2af1ed93276eb5b350c3f94eb";
const OLD_HEAD = "06e49cf900922aeb38cf2550f3ece911dfe1bff3";
const reg = () => loadRegistryFile(ROOT);
const selfGate = () =>
  reg().policies.find((p) => p.path === ".github/workflows/gibson-self-gate.yml");
function ctx(sha = HEAD) {
  const c = freezeContext({
    repo: { full_name: "The-AIE/the-gibson", default_branch: "main" },
    branch: { name: "main", commit: { sha } },
    observationTime: OBS,
    expectedFullName: "The-AIE/the-gibson",
  });
  assert.equal(c.ok, true);
  return c;
}
function run(p) {
  return {
    id: p.id,
    head_sha: p.sha ?? HEAD,
    head_branch: p.branch ?? "main",
    event: p.event ?? "push",
    status: p.status ?? "completed",
    conclusion: p.conclusion ?? "success",
    updated_at: p.updated_at ?? "2026-08-30T11:00:00Z",
    created_at: p.created_at ?? "2026-08-30T10:00:00Z",
    actor: { login: p.actor ?? "mrhinkle" },
  };
}
function job(p) {
  return {
    id: p.id,
    name: p.name,
    status: p.status ?? "completed",
    conclusion: p.conclusion ?? "success",
  };
}
function res(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
    async text() {
      return typeof body === "string" ? body : JSON.stringify(body);
    },
    headers: { get() { return null; } },
  };
}
const WFS = [
  { id: 1, name: "Gibson self-gate", path: ".github/workflows/gibson-self-gate.yml", state: "active" },
  { id: 2, name: "Sensor health", path: ".github/workflows/sensor-health.yml", state: "active" },
  { id: 3, name: "Code security", path: "dynamic/github-code-scanning/code-security-risk-assessment", state: "active" },
  { id: 4, name: "pages", path: "dynamic/pages/pages-build-deployment", state: "active" },
];
function head(sha = HEAD, has_pages = true) {
  return [
    {
      match: (u, m) => m === "GET" && /\/repos\/The-AIE\/the-gibson$/.test(u),
      respond: () =>
        res(200, {
          full_name: "The-AIE/the-gibson",
          default_branch: "main",
          has_pages,
        }),
    },
    {
      match: (u, m) => m === "GET" && /\/branches\/main$/.test(u),
      respond: () => res(200, { name: "main", commit: { sha } }),
    },
  ];
}
function fetch(handlers) {
  return async (url, init = {}) => {
    const u = String(url);
    const method = (init.method || "GET").toUpperCase();
    for (const h of handlers) {
      if (h.match(u, method, init)) return h.respond(u, method, init);
    }
    return res(500, { message: `unhandled ${method} ${u}` });
  };
}
function classifyGate(runs, jobs) {
  return classifySensor({
    name: "Gibson self-gate",
    path: ".github/workflows/gibson-self-gate.yml",
    policy: selfGate(),
    runs,
    jobs,
    ctx: ctx(),
  });
}
/** Shared green self-gate/sensor-health/code-scanning fetch handlers. */
function greenCoreHandlers(has_pages, workflows = WFS, { emptyPages = false } = {}) {
  const success = run({ id: 10, updated_at: "2026-08-30T11:00:00Z" });
  return [
    ...head(HEAD, has_pages),
    { match: (u) => /\/actions\/workflows\?/.test(u), respond: () => res(200, { workflows }) },
    {
      match: (u) => /\/workflows\/1\/runs\?/.test(u),
      respond: () => res(200, { workflow_runs: [success] }),
    },
    {
      match: (u) => /\/runs\/10\/jobs/.test(u),
      respond: () => res(200, { jobs: [job({ id: 77, name: "sensors" })] }),
    },
    {
      match: (u) => /\/workflows\/[234]\/runs\?/.test(u),
      respond: (u) => {
        if (emptyPages && /\/workflows\/4\/runs\?/.test(u)) {
          return res(200, { workflow_runs: [] });
        }
        return res(200, {
          workflow_runs: [
            run({
              id: 400 + Number(u.match(/workflows\/(\d+)/)[1]),
              event: u.includes("/workflows/2/") ? "schedule" : "dynamic",
              updated_at: "2026-08-30T10:00:00Z",
            }),
          ],
        });
      },
    },
  ];
}
function emptyRunHandlers(repoFields) {
  return [
    {
      match: (u, m) => m === "GET" && /\/repos\/The-AIE\/the-gibson$/.test(u),
      respond: () =>
        res(200, { full_name: "The-AIE/the-gibson", default_branch: "main", ...repoFields }),
    },
    {
      match: (u, m) => m === "GET" && /\/branches\/main$/.test(u),
      respond: () => res(200, { name: "main", commit: { sha: HEAD } }),
    },
    { match: (u) => /\/actions\/workflows\?/.test(u), respond: () => res(200, { workflows: WFS }) },
    { match: (u) => /\/workflows\/\d+\/runs\?/.test(u), respond: () => res(200, { workflow_runs: [] }) },
    { match: (u) => /\/jobs/.test(u), respond: () => res(200, { jobs: [] }) },
  ];
}
describe("production registry", () => {
  it("loads required rows and rejects empty/altered semantics", () => {
    const r = reg();
    assert.equal(r.schemaId, SCHEMA_ID);
    for (const p of REQUIRED_REPO_OWNED_PATHS) {
      assert.ok(r.policies.some((x) => x.path === p), p);
    }
    const sg = selfGate();
    assert.deepEqual([sg.mode, sg.events, sg.targetChecks], ["current-head", ["push"], ["sensors"]]);
    const pages = r.policies.find((p) => p.path === "dynamic/pages/pages-build-deployment");
    assert.deepEqual(pages.enabledWhen, { repoField: "has_pages", equals: true });
    assert.throws(
      () =>
        validateRegistry({
          ...r,
          policies: r.policies.map((p) =>
            p.path === pages.path ? { ...p, enabledWhen: { repoField: "has_pages", equals: false } } : p
          ),
        }),
      /equals must be exactly boolean true/
    );
    assert.throws(
      () =>
        validateRegistry({
          ...r,
          policies: r.policies.map((p) =>
            p.path === sg.path ? { ...p, enabledWhen: { repoField: "has_pages", equals: true } } : p
          ),
        }),
      /enabledWhen is allowed only/
    );
    assert.throws(
      () => validateRegistry({ ...r, policies: r.policies.map((p) => (p.path === sg.path ? { ...p, events: [] } : p)) }),
      /events must be non-empty/
    );
    assert.throws(
      () => validateRegistry({ ...r, policies: r.policies.filter((p) => p.path !== sg.path) }),
      /missing required repo-owned/
    );
    assert.throws(
      () =>
        validateRegistry({
          ...r,
          policies: r.policies.map((p) => (p.path === sg.path ? { ...p, targetChecks: ["other"] } : p)),
        }),
      /targetChecks must remain/
    );
  });
});
describe("matrix 1-5 current-head", () => {
  const cases = [
    {
      name: "1 older-head green + current-head red => FAILING",
      runs: [
        run({ id: 100, sha: OLD_HEAD, conclusion: "success", updated_at: "2026-08-26T12:00:00Z" }),
        run({ id: 200, sha: HEAD, conclusion: "failure", updated_at: "2026-08-29T12:00:00Z" }),
      ],
      filterHead: true,
      jobs: [job({ id: 1, name: "sensors", conclusion: "failure" })],
      state: STATES.FAILING,
      reason: REASON.CURRENT_HEAD_RED,
      id: 200,
    },
    {
      name: "2 older-head red + current-head green => OK",
      runs: [
        run({
          id: 200,
          sha: OLD_HEAD,
          conclusion: "failure",
          updated_at: "2026-08-29T12:00:00Z",
        }),
        run({ id: 201, sha: HEAD, conclusion: "success" }),
      ],
      filterHead: true,
      jobs: [job({ id: 2, name: "sensors" })],
      state: STATES.OK,
      id: 201,
      jobsIds: [2],
    },
    {
      name: "3 no qualifying current-head run => UNKNOWN",
      runs: [run({ id: 1, sha: OLD_HEAD })],
      state: STATES.UNKNOWN,
      reason: REASON.CURRENT_HEAD_ABSENT,
    },
    {
      name: "4 updated_at later success wins",
      runs: [
        run({ id: 10, conclusion: "failure", created_at: "2026-08-30T11:30:00Z", updated_at: "2026-08-30T11:30:00Z" }),
        run({ id: 11, conclusion: "success", created_at: "2026-08-30T10:00:00Z", updated_at: "2026-08-30T11:45:00Z" }),
      ],
      jobs: [job({ id: 3, name: "sensors" })],
      state: STATES.OK,
      id: 11,
    },
    {
      name: "5 updated_at later failure wins",
      runs: [
        run({ id: 20, conclusion: "success", created_at: "2026-08-30T11:30:00Z", updated_at: "2026-08-30T11:30:00Z" }),
        run({ id: 21, conclusion: "failure", created_at: "2026-08-30T10:00:00Z", updated_at: "2026-08-30T11:50:00Z" }),
      ],
      jobs: [job({ id: 4, name: "sensors", conclusion: "failure" })],
      state: STATES.FAILING,
      id: 21,
    },
  ];
  for (const c of cases) {
    it(c.name, () => {
      const policy = selfGate();
      const runs = c.filterHead
        ? partitionRuns(c.runs, policy, ctx(), { enforceHead: true }).qualifying
        : c.runs;
      if (c.id != null) assert.equal(selectLatestRun(c.runs).id, c.id);
      const row = classifyGate(runs, c.jobs);
      assert.equal(row.state, c.state);
      if (c.reason) assert.equal(row.reasonClass, c.reason);
      if (c.id != null) assert.equal(row.selectedRunId, c.id);
      if (c.jobsIds) assert.deepEqual(row.selectedJobIds, c.jobsIds);
    });
  }
});
describe("matrix 6-9 pr-sample / freshness", () => {
  const pr = {
    path: ".github/workflows/pr-sensors.yml",
    mode: "pr-sample",
    events: ["pull_request"],
    windowDays: 14,
    targetActors: ["mrhinkle", "gibson-bot"],
  };
  const fresh = {
    path: ".github/workflows/sensor-health.yml",
    mode: "freshness",
    events: ["schedule", "workflow_dispatch"],
    windowDays: 2,
  };
  const skip = (id) =>
    run({
      id,
      event: "pull_request",
      conclusion: "skipped",
      actor: "dependabot[bot]",
      updated_at: "2026-08-29T10:00:00Z",
    });
  it("6 target failure among skips: FAILING then BLIND", () => {
    const two = [
      ...[1, 2, 3, 4].map(skip),
      run({ id: 50, event: "pull_request", conclusion: "failure", updated_at: "2026-08-29T11:00:00Z" }),
      run({ id: 51, event: "pull_request", conclusion: "failure", updated_at: "2026-08-29T12:00:00Z" }),
    ];
    assert.equal(classifySensor({ name: "pr", path: pr.path, policy: pr, runs: two, ctx: ctx() }).state, STATES.FAILING);
    const three = [
      ...two,
      run({ id: 52, event: "pull_request", conclusion: "cancelled", updated_at: "2026-08-29T13:00:00Z" }),
    ];
    const blind = classifySensor({ name: "pr", path: pr.path, policy: pr, runs: three, ctx: ctx() });
    assert.equal(blind.state, STATES.BLIND);
    assert.equal(blind.reasonClass, REASON.NEVER_GREEN);
  });
  it("7 declared skips => IDLE; 8 undeclared skips => BLIND", () => {
    const skips = [1, 2, 3].map(skip);
    assert.ok(isExemptNonTargetSkip(skips[0], pr));
    assert.equal(classifySensor({ name: "pr", path: pr.path, policy: pr, runs: skips, ctx: ctx() }).state, STATES.IDLE);
    const bare = { path: pr.path, mode: "pr-sample", events: ["pull_request"], windowDays: 14 };
    assert.equal(isExemptNonTargetSkip(skips[0], bare), false);
    assert.equal(classifySensor({ name: "pr", path: bare.path, policy: bare, runs: skips, ctx: ctx() }).state, STATES.BLIND);
  });
  it("9 freshness outside window => IDLE", () => {
    const row = classifySensor({
      name: "s",
      path: fresh.path,
      policy: fresh,
      runs: [run({ id: 9, event: "schedule", updated_at: "2026-08-20T10:00:00Z" })],
      ctx: ctx(),
      evidenceComplete: true,
    });
    assert.equal(row.state, STATES.IDLE);
    assert.equal(row.reasonClass, REASON.IDLE_WINDOW);
  });
});
describe("matrix 10-13 audit integration", () => {
  it("10 API/malformed/path-drift/cap => UNKNOWN + nonzero", async () => {
    const r = reg();
    const r403 = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: r,
      observationTime: OBS,
      fetchImpl: fetch([{ match: () => true, respond: () => res(403, { message: "nope" }) }]),
    });
    assert.equal(r403.exitCode, 1);
    const rMal = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: r,
      observationTime: OBS,
      fetchImpl: fetch([
        ...head(),
        { match: (u) => u.includes("/actions/workflows?"), respond: () => res(200, { workflows: null }) },
      ]),
    });
    assert.equal(rMal.exitCode, 1);
    const rDrift = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: r,
      observationTime: OBS,
      fetchImpl: fetch([
        ...head(),
        {
          match: (u) => u.includes("/actions/workflows?"),
          respond: () =>
            res(200, {
              workflows: [{ id: 99, name: "renamed", path: ".github/workflows/renamed.yml", state: "active" }],
            }),
        },
      ]),
    });
    assert.equal(rDrift.exitCode, 1);
    assert.ok(rDrift.report.rows.some((x) => x.reasonClass === REASON.CONFIGURED_WORKFLOW_MISSING));
    assert.ok(rDrift.report.rows.some((x) => x.reasonClass === REASON.UNCONFIGURED_WORKFLOW));
    const rCap = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: r,
      observationTime: OBS,
      runPageCap: 2,
      perPage: 2,
      fetchImpl: fetch([
        ...head(),
        {
          match: (u) => u.includes("/actions/workflows?"),
          respond: () =>
            res(200, {
              workflows: [
                { id: 1, name: "a", path: "a.yml", state: "active" },
                { id: 2, name: "b", path: "b.yml", state: "active" },
              ],
            }),
        },
      ]),
    });
    assert.equal(rCap.exitCode, 1);
    assert.ok(rCap.report.rows.some((x) => x.reasonClass === REASON.PAGINATION_CAP));
    assert.ok(rCap.report.budget.capsHit >= 1);
  });
  it("11 #212 evidence + fingerprint suppresses duplicate comment", async () => {
    let body = "old";
    let comments = 0;
    let patches = 0;
    const success = run({ id: 33099423902, updated_at: "2026-08-30T11:00:00Z" });
    const impl = fetch([
      ...head(),
      { match: (u) => /\/actions\/workflows\?/.test(u), respond: () => res(200, { workflows: WFS }) },
      { match: (u) => /\/workflows\/1\/runs\?/.test(u), respond: () => res(200, { workflow_runs: [success] }) },
      {
        match: (u) => /\/runs\/33099423902\/jobs/.test(u),
        respond: () => res(200, { jobs: [job({ id: 77, name: "sensors" })] }),
      },
      {
        match: (u) => /\/workflows\/[234]\/runs\?/.test(u),
        respond: (u) =>
          res(200, {
            workflow_runs: [
              run({
                id: 400 + Number(u.match(/workflows\/(\d+)/)[1]),
                event: u.includes("/workflows/2/") ? "schedule" : "dynamic",
                updated_at: "2026-08-30T10:00:00Z",
              }),
            ],
          }),
      },
      {
        match: (u, m) => m === "GET" && /\/issues\/212$/.test(u),
        respond: () => res(200, { number: 212, state: "open", body }),
      },
      {
        match: (u, m) => m === "PATCH" && /\/issues\/212$/.test(u),
        respond: (_u, _m, init) => {
          patches += 1;
          body = JSON.parse(init.body).body;
          return res(200, { number: 212, body });
        },
      },
      {
        match: (u, m) => m === "POST" && /\/issues\/212\/comments$/.test(u),
        respond: () => {
          comments += 1;
          return res(201, { id: 1 });
        },
      },
    ]);
    const first = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      post: true,
      issueNumber: STANDING_ISSUE_NUMBER,
      fetchImpl: impl,
    });
    assert.equal(first.posted && first.commented && comments === 1, true);
    assert.match(first.report.body, /33099423902/);
    assert.match(first.report.body, new RegExp(HEAD));
    assert.match(first.report.body, /2026-08-30T11:00:00Z/);
    assert.match(first.report.body, /2026-08-30T12:00:00.000Z/);
    assert.equal(first.report.fingerprint, "clean");
    const second = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      post: true,
      issueNumber: STANDING_ISSUE_NUMBER,
      fetchImpl: impl,
    });
    assert.equal(second.posted, true);
    assert.equal(second.commented, false);
    assert.equal(comments, 1);
    assert.ok(patches >= 2);
    assert.equal(shouldComment(body, second.report.fingerprint), false);
  });
  it("12 head drift retries once then UNKNOWN", async () => {
    let n = 0;
    const result = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      maxHeadRetries: 1,
      fetchImpl: fetch([
        {
          match: (u, m) => m === "GET" && /\/repos\/The-AIE\/the-gibson$/.test(u),
          respond: () =>
            res(200, {
              full_name: "The-AIE/the-gibson",
              default_branch: "main",
              has_pages: true,
            }),
        },
        {
          match: (u, m) => m === "GET" && /\/branches\/main$/.test(u),
          respond: () => {
            n += 1;
            const shas = [HEAD, OLD_HEAD, HEAD, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"];
            return res(200, { name: "main", commit: { sha: shas[Math.min(n - 1, 3)] } });
          },
        },
        { match: (u) => /\/actions\/workflows\?/.test(u), respond: () => res(200, { workflows: WFS }) },
        { match: (u) => /\/workflows\/\d+\/runs\?/.test(u), respond: () => res(200, { workflow_runs: [] }) },
        { match: (u) => /\/jobs/.test(u), respond: () => res(200, { jobs: [] }) },
      ]),
    });
    assert.equal(result.exitCode, 1);
    assert.ok(result.report.rows.some((r) => r.reasonClass === REASON.HEAD_DRIFT));
    assert.ok(n >= 3);
  });
  it("13 empty optional arrays / missing configured workflow => UNKNOWN", () => {
    const base = reg();
    assert.throws(
      () =>
        validateRegistry({
          ...base,
          policies: [
            ...base.policies,
            { path: "x.yml", mode: "pr-sample", events: ["pull_request"], windowDays: 1, targetActors: [] },
          ],
        }),
      /targetActors must be non-empty/
    );
    const { rows } = joinPolicies([{ id: 1, name: "only", path: "other.yml", state: "active" }], base.policies);
    assert.ok(rows.some((r) => r.joinError === REASON.CONFIGURED_WORKFLOW_MISSING));
    assert.ok(rows.some((r) => r.joinError === REASON.UNCONFIGURED_WORKFLOW));
    assert.ok(
      rows
        .map((r) =>
          classifySensor({
            name: r.name,
            path: r.path,
            policy: r.policy,
            runs: [],
            ctx: ctx(),
            joinError: r.joinError,
          })
        )
        .every((c) => c.state === STATES.UNKNOWN)
    );
  });
});
describe("matrix 14 + mutations + fingerprint", () => {
  it("14 missing/ambiguous UNKNOWN; skipped/neutral/failed FAILING", () => {
    const p = selfGate();
    const runs = [run({ id: 5 })];
    assert.equal(
      classifySensor({ name: "g", path: p.path, policy: p, runs, ctx: ctx(), jobs: [job({ id: 1, name: "other" })] }).state,
      STATES.UNKNOWN
    );
    assert.equal(
      classifySensor({
        name: "g",
        path: p.path,
        policy: p,
        runs,
        ctx: ctx(),
        jobs: [job({ id: 1, name: "sensors" }), job({ id: 2, name: "sensors" })],
      }).state,
      STATES.UNKNOWN
    );
    for (const conclusion of ["skipped", "neutral", "failure"]) {
      const row = classifySensor({
        name: "g",
        path: p.path,
        policy: p,
        runs,
        ctx: ctx(),
        jobs: [job({ id: 9, name: "sensors", conclusion })],
      });
      assert.equal(row.state, STATES.FAILING);
      assert.equal(row.reasonClass, REASON.CURRENT_HEAD_RED);
    }
    const ev = evaluateTargetJobs([job({ id: 1, name: "sensors", status: "in_progress", conclusion: null })], ["sensors"]);
    assert.equal(ev.ok, false);
    assert.equal(ev.failing, false);
  });
  it("mutations: SHA filter, updated_at order, skip qualification, cap", () => {
    const policy = selfGate();
    const c = ctx();
    const runs = [
      run({ id: 1, sha: OLD_HEAD, updated_at: "2026-08-30T11:59:00Z" }),
      run({ id: 2, sha: HEAD, conclusion: "failure", updated_at: "2026-08-30T11:00:00Z" }),
    ];
    assert.deepEqual(
      partitionRuns(runs, policy, c, { enforceHead: true }).qualifying.map((r) => r.id),
      [2]
    );
    assert.equal([...runs].sort(compareUpdatedAtThenId)[0].id, 1);
    const ordered = [
      run({ id: 1, conclusion: "failure", created_at: "2026-08-30T12:00:00Z", updated_at: "2026-08-30T10:00:00Z" }),
      run({ id: 2, conclusion: "success", created_at: "2026-08-30T09:00:00Z", updated_at: "2026-08-30T11:00:00Z" }),
    ];
    assert.equal(selectLatestRun(ordered).id, 2);
    const pr = {
      path: "p.yml",
      mode: "pr-sample",
      events: ["pull_request"],
      windowDays: 14,
      targetActors: ["human"],
    };
    const skips = [1, 2, 3].map((id) =>
      run({ id, event: "pull_request", conclusion: "skipped", actor: "dependabot[bot]", updated_at: "2026-08-29T10:00:00Z" })
    );
    assert.equal(partitionRuns(skips, pr, c, { enforceWindow: true }).qualifying.length, 0);
    assert.equal(
      partitionRuns(skips, { path: pr.path, mode: "pr-sample", events: ["pull_request"], windowDays: 14 }, c, {
        enforceWindow: true,
      }).qualifying.length,
      3
    );
    const fresh = { path: "s.yml", mode: "freshness", events: ["schedule"], windowDays: 2 };
    assert.equal(
      classifySensor({ name: "s", path: fresh.path, policy: fresh, runs: [], ctx: c, evidenceComplete: true }).state,
      STATES.IDLE
    );
    const capped = classifySensor({
      name: "s",
      path: fresh.path,
      policy: fresh,
      runs: [],
      ctx: c,
      evidenceComplete: false,
      capExhausted: true,
    });
    assert.equal(capped.state, STATES.UNKNOWN);
    assert.equal(capped.reasonClass, REASON.PAGINATION_CAP);
  });
  it("fingerprint/body helpers and registry file", () => {
    assert.equal(buildFingerprint([{ state: STATES.OK, path: "a.yml" }]), "clean");
    assert.equal(
      buildFingerprint([
        { state: STATES.OK, path: "a.yml" },
        { state: STATES.FAILING, path: "b.yml", reasonClass: REASON.CURRENT_HEAD_RED },
      ]),
      `FAILING:b.yml:${REASON.CURRENT_HEAD_RED}`
    );
    const body = renderIssueBody({
      context: {
        fullName: "The-AIE/the-gibson",
        defaultBranch: "main",
        headSha: HEAD,
        observationTimeIso: OBS.toISOString(),
      },
      rows: [
        {
          name: "g",
          path: "b.yml",
          state: STATES.FAILING,
          reasonClass: REASON.CURRENT_HEAD_RED,
          detail: "red",
          selectedRunId: 1,
          headSha: HEAD,
          conclusion: "failure",
          updatedAt: "2026-08-30T11:00:00Z",
        },
      ],
      fingerprint: `FAILING:b.yml:${REASON.CURRENT_HEAD_RED}`,
      budget: { requests: 3, pages: 2, capsHit: 0, cacheHits: 1 },
    });
    assert.match(body, /Budget: requests=3 pages=2/);
    assert.match(body, /sensor-health-fingerprint/);
    assert.equal(JSON.parse(readFileSync(join(ROOT, "config/sensor-health-observation.v1.json"), "utf8")).policies.length, 4);
  });
});
describe("coordinator gap controls", () => {
  const fresh = { path: "p.yml", mode: "freshness", events: ["schedule"], windowDays: 2 };
  it("malformed / unknown conclusion / pending-only => UNKNOWN", () => {
    const c = ctx();
    const poisoned = classifySensor({
      name: "s",
      path: fresh.path,
      policy: fresh,
      ctx: c,
      evidenceComplete: true,
      runs: [
        run({ id: 1, event: "schedule", updated_at: "2026-08-29T09:00:00Z" }),
        { id: 2, event: "schedule", status: "completed", conclusion: "success", updated_at: "not-a-date" },
      ],
    });
    assert.equal(poisoned.state, STATES.UNKNOWN);
    assert.equal(poisoned.reasonClass, REASON.MALFORMED_EVIDENCE);
    const weird = classifySensor({
      name: "s",
      path: fresh.path,
      policy: fresh,
      ctx: c,
      evidenceComplete: true,
      runs: [{ id: 3, event: "schedule", status: "completed", conclusion: "weird", updated_at: "2026-08-29T10:00:00Z" }],
    });
    assert.equal(weird.state, STATES.UNKNOWN);
    const pendingRun = {
      id: 4,
      event: "schedule",
      status: "in_progress",
      conclusion: null,
      updated_at: "2026-08-29T10:00:00Z",
    };
    const pending = classifySensor({
      name: "s",
      path: fresh.path,
      policy: fresh,
      ctx: c,
      evidenceComplete: true,
      runs: [pendingRun],
    });
    assert.equal(pending.state, STATES.UNKNOWN);
    assert.notEqual(pending.state, STATES.IDLE);
    assert.equal(assessRun(pendingRun, fresh, c, { enforceWindow: true }).kind, "pending");
  });
  it("exact full_name and duplicate active paths", () => {
    const mismatch = freezeContext({
      repo: { full_name: "other/repo", default_branch: "main" },
      branch: { name: "main", commit: { sha: HEAD } },
      observationTime: OBS,
      expectedFullName: "The-AIE/the-gibson",
    });
    assert.equal(mismatch.ok, false);
    assert.equal(mismatch.reasonClass, REASON.MALFORMED_EVIDENCE);
    const { rows } = joinPolicies(
      [
        { id: 1, name: "a", path: ".github/workflows/gibson-self-gate.yml", state: "active" },
        { id: 2, name: "a2", path: ".github/workflows/gibson-self-gate.yml", state: "active" },
      ],
      reg().policies
    );
    assert.ok(
      rows
        .filter((r) => r.path === ".github/workflows/gibson-self-gate.yml")
        .every((r) => r.joinError === REASON.MALFORMED_EVIDENCE)
    );
  });
  it("freshness cap after in-window success page => UNKNOWN", async () => {
    const result = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      runPageCap: 3,
      perPage: 2,
      fetchImpl: async (url) => {
        const u = String(url);
        if (/\/repos\/The-AIE\/the-gibson$/.test(u)) {
          return res(200, {
            full_name: "The-AIE/the-gibson",
            default_branch: "main",
            has_pages: true,
          });
        }
        if (/\/branches\/main$/.test(u)) return res(200, { name: "main", commit: { sha: HEAD } });
        if (/\/actions\/workflows\?/.test(u)) {
          const page = Number(new URL(u).searchParams.get("page") || 1);
          const pp = Number(new URL(u).searchParams.get("per_page") || 100);
          return res(200, { workflows: WFS.slice((page - 1) * pp, page * pp) });
        }
        if (/\/workflows\/2\/runs\?/.test(u)) {
          return res(200, {
            workflow_runs: [
              run({ id: 900, event: "schedule", updated_at: "2026-08-30T10:00:00Z" }),
              run({ id: 901, event: "schedule", updated_at: "2026-08-30T09:00:00Z" }),
            ],
          });
        }
        if (/\/workflows\/1\/runs\?/.test(u)) {
          return res(200, { workflow_runs: [run({ id: 100, updated_at: "2026-08-30T11:00:00Z" })] });
        }
        if (/\/jobs/.test(u)) return res(200, { jobs: [job({ id: 1, name: "sensors" })] });
        if (/\/workflows\/[34]\/runs\?/.test(u)) {
          return res(200, {
            workflow_runs: [run({ id: 800, event: "dynamic", updated_at: "2026-08-30T10:00:00Z" })],
          });
        }
        return res(500, { message: u });
      },
    });
    const row = result.report.rows.find((r) => r.path === ".github/workflows/sensor-health.yml");
    assert.ok(row);
    assert.equal(row.state, STATES.UNKNOWN);
    assert.equal(row.reasonClass, REASON.PAGINATION_CAP);
    assert.equal(result.exitCode, 1);
    assert.ok(result.report.budget.capsHit >= 1);
  });
  it("registry failure publishes UNKNOWN to #212 by number only", async () => {
    const paths = [];
    const result = await publishStandingUnknown({
      token: "t",
      repository: "The-AIE/the-gibson",
      observationTime: OBS,
      reasonClass: REASON.POLICY_INVALID,
      detail: "policies must be non-empty",
      fetchImpl: async (url, init = {}) => {
        const u = String(url);
        paths.push(`${(init.method || "GET").toUpperCase()} ${u}`);
        if (/\/issues\/212$/.test(u) && (!init.method || init.method === "GET")) {
          return res(200, { number: 212, state: "open", body: "prior" });
        }
        if (/\/issues\/212$/.test(u) && init.method === "PATCH") {
          assert.match(JSON.parse(init.body).body, /UNKNOWN/);
          return res(200, { number: 212 });
        }
        if (/\/comments$/.test(u)) return res(201, { id: 1 });
        return res(500, { message: "no" });
      },
    });
    assert.equal(result.posted, true);
    assert.equal(result.exitCode, 1);
    assert.ok(paths.every((p) => !p.includes("/issues?") && !/title/.test(p)));
    assert.ok(paths.some((p) => p.includes("/issues/212")));
  });
  it("join/jobs/skip structural false-signals => UNKNOWN (not exempt/FAILING)", () => {
    const { rows } = joinPolicies(
      [null, { id: 1, name: "Gibson self-gate", path: selfGate().path, state: "active" }],
      [selfGate()]
    );
    assert.ok(rows.some((r) => r.joinError === REASON.MALFORMED_EVIDENCE && r.path === ""));
    assert.ok(rows.some((r) => r.path === selfGate().path && r.joinError == null));
    assert.equal(classifySensor({ name: "m", path: "(malformed)", policy: null, runs: [], ctx: ctx(), joinError: REASON.MALFORMED_EVIDENCE }).state, STATES.UNKNOWN);
    const p = selfGate();
    const weird = classifySensor({ name: "g", path: p.path, policy: p, runs: [run({ id: 5 })], ctx: ctx(), jobs: [job({ id: 1, name: "sensors", conclusion: "weird" })] });
    assert.equal(weird.state, STATES.UNKNOWN);
    assert.equal(weird.reasonClass, REASON.MALFORMED_EVIDENCE);
    const noConc = evaluateTargetJobs([{ id: 1, name: "sensors", status: "completed", conclusion: null }], ["sensors"]);
    assert.equal(noConc.failing, false);
    assert.equal(noConc.reasonClass, REASON.MALFORMED_EVIDENCE);
    const badId = evaluateTargetJobs([{ id: "x", name: "sensors", status: "completed", conclusion: "success" }], ["sensors"]);
    assert.equal(badId.failing, false);
    const fail = evaluateTargetJobs([job({ id: 1, name: "sensors", conclusion: "cancelled" })], ["sensors"]);
    assert.equal(fail.failing, true);
    const pr = { path: "p.yml", mode: "pr-sample", events: ["pull_request"], windowDays: 14, targetActors: ["human"] };
    const c = ctx();
    const missingEvent = { id: 1, status: "completed", conclusion: "skipped", actor: { login: "dependabot[bot]" }, updated_at: "2026-08-29T10:00:00Z" };
    assert.equal(isExemptNonTargetSkip(missingEvent, pr), false);
    assert.equal(assessRun(missingEvent, pr, c, { enforceWindow: true }).kind, "malformed");
    const missingStatus = { id: 2, event: "pull_request", conclusion: "skipped", actor: { login: "dependabot[bot]" }, updated_at: "2026-08-29T10:00:00Z" };
    assert.equal(isExemptNonTargetSkip(missingStatus, pr), false);
    assert.equal(assessRun(missingStatus, pr, c, { enforceWindow: true }).kind, "malformed");
  });
  it("default-branch change with same SHA is HEAD_DRIFT after one retry", async () => {
    let n = 0;
    const result = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      maxHeadRetries: 1,
      fetchImpl: fetch([
        {
          match: (u, m) => m === "GET" && /\/repos\/The-AIE\/the-gibson$/.test(u),
          respond: () => {
            n += 1;
            return res(200, { full_name: "The-AIE/the-gibson", default_branch: n === 1 || n === 3 ? "main" : "master", has_pages: true });
          },
        },
        {
          match: (u, m) => m === "GET" && /\/branches\/(main|master)$/.test(u),
          respond: (u) => res(200, { name: u.includes("/branches/master") ? "master" : "main", commit: { sha: HEAD } }),
        },
        ...emptyRunHandlers({ has_pages: true }).slice(2),
      ]),
    });
    assert.equal(result.exitCode, 1);
    assert.ok(result.report.rows.some((r) => r.reasonClass === REASON.HEAD_DRIFT));
    assert.ok(n >= 3);
  });
  it("16 has_pages:false excludes historical API-active Pages workflow", async () => {
    const result = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      fetchImpl: fetch(greenCoreHandlers(false)),
    });
    assert.equal(result.exitCode, 0);
    assert.ok(result.report.rows.every((r) => r.state === STATES.OK));
    assert.ok(!result.report.rows.some((r) => r.path === PAGES_WORKFLOW_PATH));
    assert.deepEqual(result.report.exclusions, [
      { path: PAGES_WORKFLOW_PATH, name: PAGES_WORKFLOW_PATH, evidence: "repo.has_pages=false" },
    ]);
    assert.match(result.report.body, /Excluded \(capability disabled\)/);
    assert.match(result.report.body, /repo\.has_pages=false/);
    assert.equal(
      result.report.fingerprint,
      `EXCLUDED:${PAGES_WORKFLOW_PATH}:repo.has_pages=false`
    );
  });
  it("17 has_pages:true active/no-run => IDLE; missing workflow => UNKNOWN", async () => {
    const idle = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      fetchImpl: fetch(greenCoreHandlers(true, WFS, { emptyPages: true })),
    });
    const pagesIdle = idle.report.rows.find((r) => r.path === PAGES_WORKFLOW_PATH);
    assert.ok(pagesIdle);
    assert.equal(pagesIdle.state, STATES.IDLE);
    assert.equal(idle.exitCode, 1);
    assert.equal(idle.report.exclusions.length, 0);
    const missing = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      fetchImpl: fetch(
        greenCoreHandlers(
          true,
          WFS.filter((w) => w.path !== PAGES_WORKFLOW_PATH)
        )
      ),
    });
    const pagesMissing = missing.report.rows.find((r) => r.path === PAGES_WORKFLOW_PATH);
    assert.ok(pagesMissing);
    assert.equal(pagesMissing.state, STATES.UNKNOWN);
    assert.equal(pagesMissing.reasonClass, REASON.CONFIGURED_WORKFLOW_MISSING);
    assert.equal(missing.exitCode, 1);
  });
  it("18 missing/non-boolean has_pages, unsupported enabledWhen, capability drift => UNKNOWN", async () => {
    const missingHp = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      fetchImpl: fetch(emptyRunHandlers({})),
    });
    assert.equal(missingHp.exitCode, 1);
    assert.ok(missingHp.report.rows.some((r) => r.path === PAGES_WORKFLOW_PATH && r.state === STATES.UNKNOWN));
    assert.equal(missingHp.report.exclusions.length, 0);
    const nonBool = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      fetchImpl: fetch(emptyRunHandlers({ has_pages: "yes" })),
    });
    assert.equal(nonBool.exitCode, 1);
    assert.equal(nonBool.report.exclusions.length, 0);
    assert.throws(
      () =>
        validateRegistry({
          ...reg(),
          policies: reg().policies.map((p) =>
            p.path === PAGES_WORKFLOW_PATH
              ? { ...p, enabledWhen: { repoField: "fork", equals: true } }
              : p
          ),
        }),
      /repoField must be exactly/
    );
    let n = 0;
    const drift = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      maxHeadRetries: 1,
      fetchImpl: fetch([
        {
          match: (u, m) => m === "GET" && /\/repos\/The-AIE\/the-gibson$/.test(u),
          respond: () => {
            n += 1;
            const hp = n === 1 || n === 3 ? false : true;
            return res(200, {
              full_name: "The-AIE/the-gibson",
              default_branch: "main",
              has_pages: hp,
            });
          },
        },
        {
          match: (u, m) => m === "GET" && /\/branches\/main$/.test(u),
          respond: () => res(200, { name: "main", commit: { sha: HEAD } }),
        },
        { match: (u) => /\/actions\/workflows\?/.test(u), respond: () => res(200, { workflows: WFS }) },
        { match: (u) => /\/workflows\/\d+\/runs\?/.test(u), respond: () => res(200, { workflow_runs: [] }) },
        { match: (u) => /\/jobs/.test(u), respond: () => res(200, { jobs: [] }) },
      ]),
    });
    assert.equal(drift.exitCode, 1);
    assert.ok(drift.report.rows.some((r) => r.reasonClass === REASON.HEAD_DRIFT));
    assert.ok(n >= 3);
  });
  it("malformed workflow state/id cannot be OK, exclusion-only, or exit 0", async () => {
    const direct = joinPolicies(
      [{ id: 4, name: "pages", path: PAGES_WORKFLOW_PATH, state: null }],
      [selfGate()]
    );
    assert.ok(
      direct.rows.some(
        (r) => r.path === PAGES_WORKFLOW_PATH && r.joinError === REASON.MALFORMED_EVIDENCE
      )
    );
    const noId = joinPolicies(
      [{ name: "pages", path: PAGES_WORKFLOW_PATH, state: "active" }],
      [selfGate()]
    );
    assert.ok(
      noId.rows.some(
        (r) => r.path === PAGES_WORKFLOW_PATH && r.joinError === REASON.MALFORMED_EVIDENCE
      )
    );
    const malformedPages = { id: 4, name: "pages", path: PAGES_WORKFLOW_PATH, state: null };
    const result = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      fetchImpl: fetch(greenCoreHandlers(false, [WFS[0], WFS[1], WFS[2], malformedPages])),
    });
    assert.equal(result.exitCode, 1);
    assert.ok(
      result.report.rows.some(
        (r) => r.path === PAGES_WORKFLOW_PATH && r.state === STATES.UNKNOWN && r.reasonClass === REASON.MALFORMED_EVIDENCE
      )
    );
    assert.ok(result.report.exclusions.some((e) => e.path === PAGES_WORKFLOW_PATH));
    assert.ok(result.report.rows.some((r) => r.state !== STATES.OK));
  });
  it("exclusion change comment lists path/evidence and does not call excluded healthy", async () => {
    let commentBody = null;
    const result = await runSensorHealthAudit({
      token: "t",
      repository: "The-AIE/the-gibson",
      registry: reg(),
      observationTime: OBS,
      post: true,
      issueNumber: STANDING_ISSUE_NUMBER,
      fetchImpl: fetch([
        ...greenCoreHandlers(false),
        {
          match: (u, m) => m === "GET" && /\/issues\/212$/.test(u),
          respond: () => res(200, { number: 212, state: "open", body: "prior without fingerprint" }),
        },
        {
          match: (u, m) => m === "PATCH" && /\/issues\/212$/.test(u),
          respond: () => res(200, { number: 212 }),
        },
        {
          match: (u, m) => m === "POST" && /\/issues\/212\/comments$/.test(u),
          respond: (_u, _m, init) => {
            commentBody = JSON.parse(init.body).body;
            return res(201, { id: 1 });
          },
        },
      ]),
    });
    assert.equal(result.posted, true);
    assert.equal(result.commented, true);
    assert.match(commentBody, /All expected sensors are OK/);
    assert.match(commentBody, new RegExp(PAGES_WORKFLOW_PATH));
    assert.match(commentBody, /repo\.has_pages=false/);
    assert.equal(/all previously reported sensors are healthy again/i.test(commentBody), false);
  });
});
