#!/usr/bin/env node
/**
 * Offline gh fixture map for delivery-receipt collect tests.
 * Writes dir/map.json. Transport only; collect still allowlists and records pages.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const HEAD = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
export const BASE = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
export const MERGE = "cccccccccccccccccccccccccccccccccccccccc";

function commit(sha, message, login = "aie-agent-lanes-grok[bot]") {
  return {
    sha,
    author: { login },
    committer: { login },
    commit: { message, verification: { verified: true } },
  };
}

export function defaultMap(overrides = {}) {
  const pull = {
    number: 1,
    state: "closed",
    merged: true,
    merged_at: "2026-10-13T12:00:00Z",
    merge_commit_sha: MERGE,
    commits: 2,
    head: { sha: HEAD },
    base: { sha: BASE, ref: "main" },
    labels: [{ name: "tier-c" }],
  };
  const map = {
    "repos/example/example": { ok: true, body: [{ default_branch: "main" }] },
    headers: { ok: true, stdout: "HTTP/2 200\r\nx-github-api-version: 2022-11-28\r\n\r\n{}\n" },
    "repos/example/example/pulls/1": { ok: true, body: [pull] },
    "repos/example/example/pulls/1/commits?per_page=100": {
      ok: true,
      body: [[commit(`${"d".repeat(39)}1`, "feat: one\n\nAgent-Vendor: grok\n")]],
    },
    "repos/example/example/pulls/1/reviews?per_page=100": { ok: true, body: [[]] },
    "repos/example/example/issues/1/comments?per_page=100": { ok: true, body: [[]] },
    [`repos/example/example/commits/${HEAD}/pulls?per_page=100`]: {
      ok: true,
      body: [[{ number: 1, state: "closed", head: { sha: HEAD } }]],
    },
    "repos/example/example/issues/1/timeline?per_page=100": { ok: true, body: [[]] },
    "repos/example/example/pulls/1/files?per_page=100": {
      ok: true,
      body: [[{ filename: "scripts/delivery-receipt.mjs" }]],
    },
    [`repos/example/example/commits/${HEAD}/check-runs?per_page=100`]: {
      ok: true,
      body: [{ check_runs: [], total_count: 0 }],
    },
    [`repos/example/example/commits/${HEAD}/statuses?per_page=100`]: { ok: true, body: [[]] },
    [`repos/example/example/commits/${HEAD}/status?per_page=100`]: {
      ok: true,
      body: [{ state: "success", statuses: [], total_count: 0, sha: HEAD }],
    },
    "repos/example/example/branches/main/protection/required_status_checks": {
      ok: true,
      body: [{ checks: [{ context: "sensors", app_id: 15368 }] }],
    },
    "repos/example/example/rules/branches/main": {
      ok: true,
      body: [[{
        type: "required_status_checks",
        parameters: { required_status_checks: [{ context: "claim-isolation", app_id: 15368 }] },
      }]],
    },
    "graphql:closing-issues": {
      ok: true,
      body: { data: { repository: { pullRequest: { closingIssuesReferences: { nodes: [{ number: 160 }] } } } } },
    },
    "graphql:comment-editors": {
      ok: true,
      body: {
        data: {
          repository: {
            pullRequest: {
              comments: { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } },
            },
          },
        },
      },
    },
  };
  return { ...map, ...overrides };
}

export function writeCollectFixture(dir, overrides = {}) {
  mkdirSync(dir, { recursive: true });
  const map = defaultMap(overrides);
  writeFileSync(join(dir, "map.json"), `${JSON.stringify(map)}\n`);
  return { HEAD, BASE, MERGE, map };
}

const outDir = process.argv[2];
if (outDir) {
  const extra = process.argv[3] ? JSON.parse(process.argv[3]) : {};
  writeCollectFixture(outDir, extra);
  process.stdout.write(`${outDir}\n`);
}
