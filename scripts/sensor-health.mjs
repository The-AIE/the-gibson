#!/usr/bin/env node
// sensor-health.mjs — daily CI sensor-health audit.
//
// Doctrine (The-AIE/the-gibson #210): a required lane that has never been
// green is BLIND, not passing — its failures carry no information because
// nobody is reacting to them. This loop makes blindness visible within a day
// instead of after weeks (see conference-os#1336, where the authz matrix was
// red for its entire life and nobody noticed the sensor had never worked).
//
// Classification per active workflow (sampled from its most recent runs):
//   BLIND   — >=3 completed runs, zero successes ever in the sample.
//   FAILING — was green once, but latest completed run failed and no
//             success within the last SENSOR_WINDOW_DAYS days.
//   IDLE    — no completed runs in the window (informational only).
//   OK      — everything else.
//
// Advisory first, per doctrine: the job itself stays green; findings land in
// a standing issue that is updated in place, with a comment (=notification)
// only when the finding set actually changes.
//
// Env: GITHUB_TOKEN, GITHUB_REPOSITORY. Flags: --post (upsert issue; without
// it, prints the report and exits), SENSOR_WINDOW_DAYS (default 14).

const TOKEN = process.env.GITHUB_TOKEN;
const REPO = process.env.GITHUB_REPOSITORY;
const WINDOW_DAYS = Number(process.env.SENSOR_WINDOW_DAYS || 14);
const POST = process.argv.includes("--post");
const ISSUE_TITLE = "🩺 Sensor health (daily)";
const RUN_SAMPLE = 100;
const MIN_RUNS_FOR_BLIND = 3;

if (!TOKEN || !REPO) {
  console.error("sensor-health: GITHUB_TOKEN and GITHUB_REPOSITORY are required");
  process.exit(1);
}

async function gh(path, init = {}) {
  const res = await fetch(`https://api.github.com${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      ...(init.headers || {}),
    },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`GET ${path} -> ${res.status}: ${body.slice(0, 200)}`);
  }
  return res.json();
}

function classify(runs) {
  const completed = runs.filter((r) => r.status === "completed");
  const successes = completed.filter((r) => r.conclusion === "success");
  const cutoff = Date.now() - WINDOW_DAYS * 86400_000;
  const inWindow = completed.filter((r) => new Date(r.created_at).getTime() >= cutoff);
  const successInWindow = successes.some(
    (r) => new Date(r.created_at).getTime() >= cutoff
  );
  const latest = completed[0] ?? null;

  if (completed.length >= MIN_RUNS_FOR_BLIND && successes.length === 0) {
    return { state: "BLIND", detail: `${completed.length} completed runs sampled, never green` };
  }
  if (
    successes.length > 0 &&
    latest &&
    latest.conclusion !== "success" &&
    !successInWindow &&
    inWindow.length > 0
  ) {
    const lastGreen = successes[0]?.created_at?.slice(0, 10) ?? "unknown";
    return { state: "FAILING", detail: `latest run ${latest.conclusion}; last green ${lastGreen}` };
  }
  if (inWindow.length === 0) {
    const last = latest
      ? `; latest ever: ${latest.conclusion} ${latest.created_at?.slice(0, 10)}`
      : "";
    const warn = latest && latest.conclusion !== "success" ? " ⚠️" : "";
    return { state: "IDLE", detail: `no completed runs in ${WINDOW_DAYS}d${last}${warn}` };
  }
  const lastGreen = successes[0]?.created_at?.slice(0, 10) ?? "n/a";
  return { state: "OK", detail: `last green ${lastGreen}` };
}

async function main() {
  const { workflows } = await gh(`/repos/${REPO}/actions/workflows?per_page=100`);
  const active = workflows.filter((w) => w.state === "active");
  const rows = [];
  for (const wf of active) {
    const { workflow_runs } = await gh(
      `/repos/${REPO}/actions/workflows/${wf.id}/runs?per_page=${RUN_SAMPLE}`
    );
    rows.push({ name: wf.name, path: wf.path, ...classify(workflow_runs) });
  }

  const order = { BLIND: 0, FAILING: 1, IDLE: 2, OK: 3 };
  rows.sort((a, b) => order[a.state] - order[b.state] || a.name.localeCompare(b.name));

  const findings = rows.filter((r) => r.state === "BLIND" || r.state === "FAILING");
  const fingerprint = findings
    .map((f) => `${f.state}:${f.path}`)
    .sort()
    .join("|") || "clean";

  const icon = { BLIND: "🔴", FAILING: "🟠", IDLE: "⚪", OK: "🟢" };
  const lines = [
    `Daily sensor-health audit for \`${REPO}\` — window ${WINDOW_DAYS}d, sample ${RUN_SAMPLE} runs/workflow.`,
    "",
    "A **BLIND** sensor has never been green: its failures carry no information and whatever it guards is unverified. Doctrine: The-AIE/the-gibson#210.",
    "",
    "| Sensor | State | Detail |",
    "| --- | --- | --- |",
    ...rows.map((r) => `| ${r.name} (\`${r.path}\`) | ${icon[r.state]} ${r.state} | ${r.detail} |`),
    "",
    findings.length === 0
      ? "**No blind or failing sensors.**"
      : `**${findings.length} sensor(s) need attention.** A blind sensor is fixed by making the lane pass or deleting it — never by ignoring it.`,
    "",
    `<!-- sensor-health-fingerprint: ${fingerprint} -->`,
  ];
  const body = lines.join("\n");

  if (!POST) {
    console.log(body);
    return;
  }

  const issues = await gh(
    `/repos/${REPO}/issues?state=all&per_page=100&labels=sensor-health`
  );
  let issue = issues.find((i) => i.title === ISSUE_TITLE && !i.pull_request);
  if (issue && issue.state === "closed") {
    await gh(`/repos/${REPO}/issues/${issue.number}`, {
      method: "PATCH",
      body: JSON.stringify({ state: "open" }),
    });
  }

  try {
    await gh(`/repos/${REPO}/labels`, {
      method: "POST",
      body: JSON.stringify({
        name: "sensor-health",
        color: "d93f0b",
        description: "Daily CI sensor-health audit (gibson#210)",
      }),
    });
  } catch {
    /* label already exists */
  }

  if (!issue) {
    issue = await gh(`/repos/${REPO}/issues`, {
      method: "POST",
      body: JSON.stringify({ title: ISSUE_TITLE, body, labels: ["sensor-health"] }),
    });
    console.log(`created issue #${issue.number}`);
    return;
  }

  const prev = (issue.body || "").match(/<!-- sensor-health-fingerprint: (.*) -->/);
  const changed = !prev || prev[1] !== fingerprint;
  await gh(`/repos/${REPO}/issues/${issue.number}`, {
    method: "PATCH",
    body: JSON.stringify({ body }),
  });
  if (changed) {
    const delta =
      findings.length === 0
        ? "All previously reported sensors are healthy again. ✅"
        : `Finding set changed. Current: ${findings.map((f) => `${f.state} ${f.name}`).join("; ")}.`;
    await gh(`/repos/${REPO}/issues/${issue.number}/comments`, {
      method: "POST",
      body: JSON.stringify({ body: delta }),
    });
    console.log(`updated issue #${issue.number} (finding set changed — comment posted)`);
  } else {
    console.log(`updated issue #${issue.number} (no change)`);
  }
}

main().catch((err) => {
  console.error(String(err));
  process.exit(1);
});
