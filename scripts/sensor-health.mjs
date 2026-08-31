#!/usr/bin/env node
// sensor-health.mjs — daily CI sensor-health audit (#210 / #256).
// Fail-closed: nonzero unless every configured/active row is OK.
// Standing issue #212 is updated by number only.
import {
  DEFAULT_RUN_PAGE_CAP,
  loadRegistryFile,
  publishStandingUnknown,
  REASON,
  REGISTRY_REL,
  repoRootFromModule,
  runSensorHealthAudit,
  STANDING_ISSUE_NUMBER,
} from "./sensor-health-lib.mjs";
const KNOWN_FLAGS = new Set(["--post"]);
const unknown = process.argv.slice(2).filter((a) => !KNOWN_FLAGS.has(a));
if (unknown.length > 0) {
  console.error(
    `sensor-health: unknown flag: ${unknown.join(" ")}\nusage: node scripts/sensor-health.mjs [--post]`
  );
  process.exit(2);
}
const TOKEN = process.env.GITHUB_TOKEN;
const REPO = process.env.GITHUB_REPOSITORY;
const POST = process.argv.includes("--post");
const RUN_PAGE_CAP = Number(process.env.SENSOR_RUN_PAGE_CAP || DEFAULT_RUN_PAGE_CAP);
if (!TOKEN || !REPO) {
  console.error("sensor-health: GITHUB_TOKEN and GITHUB_REPOSITORY are required");
  process.exit(1);
}
async function main() {
  const repoRoot = repoRootFromModule(import.meta.url);
  let registry;
  try {
    registry = loadRegistryFile(repoRoot, REGISTRY_REL);
  } catch (err) {
    console.error(`sensor-health: ${err.message}`);
    if (POST) {
      const failed = await publishStandingUnknown({
        token: TOKEN,
        repository: REPO,
        reasonClass:
          err.code === "E_POLICY" ? REASON.POLICY_INVALID : REASON.MALFORMED_EVIDENCE,
        detail: err.message,
      });
      if (failed.report?.body) console.log(failed.report.body);
      if (failed.posted) {
        console.log(
          `sensor-health: updated issue #${STANDING_ISSUE_NUMBER} with UNKNOWN (${
            failed.commented ? "comment posted" : "no comment"
          })`
        );
      } else {
        console.error(
          `sensor-health: could not update issue #${STANDING_ISSUE_NUMBER}: ${
            failed.postError || "unknown"
          }`
        );
      }
    }
    process.exit(1);
  }
  const result = await runSensorHealthAudit({
    token: TOKEN,
    repository: REPO,
    registry,
    post: POST,
    issueNumber: STANDING_ISSUE_NUMBER,
    runPageCap:
      Number.isFinite(RUN_PAGE_CAP) && RUN_PAGE_CAP > 0
        ? RUN_PAGE_CAP
        : DEFAULT_RUN_PAGE_CAP,
    observationTime: new Date(),
  });
  const { report, posted, commented, postError, exitCode } = result;
  console.log(report.body);
  console.log(
    `sensor-health: budget requests=${report.budget.requests} pages=${report.budget.pages} capsHit=${report.budget.capsHit} cacheHits=${report.budget.cacheHits}`
  );
  if (POST) {
    if (posted) {
      console.log(
        `sensor-health: updated issue #${STANDING_ISSUE_NUMBER}${
          commented
            ? " (finding set changed — comment posted)"
            : " (no comment; fingerprint unchanged)"
        }`
      );
    } else {
      console.error(
        `sensor-health: could not update issue #${STANDING_ISSUE_NUMBER}: ${
          postError || "unknown"
        }`
      );
    }
  }
  process.exit(exitCode ?? 1);
}
main().catch((err) => {
  console.error(String(err?.stack || err));
  process.exit(1);
});
