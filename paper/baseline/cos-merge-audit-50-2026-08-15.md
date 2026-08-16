# Merge audit: The-AIE/conference-os

Generated 2026-08-15T17:55:28.596Z. Cohort: **50** merges by `merged_at` (newest first).

**Advisory grade: D (66.4/100).** Grade never fails the process; use `--strict` for deterministic policy violations only.

## Summary

| Signal | Result |
| --- | ---: |
| quality READY at merge | 49/50 |
| build-e2e-required READY at merge | 50/50 observed |
| PR-head Preview | IN_FLIGHT 45, LEGACY_MISSING 3, UNKNOWN 2 |
| Main integration Preview | IN_FLIGHT 48, LEGACY_MISSING 2 |
| Release/Production evidence | LEGACY_MISSING 50 |
| In-flight check at merge | 46/50 |
| In-flight later failed | 0/50 |
| Exact-head review evidence | 50/50 |
| Review path | none 2, owner-attestation 31, provider-evidence-comment 2, trusted-provider-review 15 |
| Avoidable owner attestations | 13/44 (provider approval preceded: 5, later: 8, unknown: 0) |
| Independent exact-head review | 14/50 |
| Formal GitHub approvals | 16/50 |
| Burst merges (≤60s pairs) | 11 pairs / 14 PRs |
| Duplicate head groups | 0 (0 PRs) |
| Branch lag | fresh 25, lagged-1-10 23, lagged-gt-10 2 |
| On `release` ancestry | 0/50 (unknown 0) |
| PRs with policy violations | 0/50 |

## Topology notes

- **PR-head Preview** — canonical `conference-os-vercel` check on the PR head SHA.
- **Main integration Preview** — same project on the merge commit after land on `main`. Integration evidence only; **not** Production under the intended `release` topology.
- **Release / Production** — merge commit ancestor of `release` when the ref exists. Full Production READY needs Vercel deploy verification (outside this GitHub-only, no-secrets script).
- **At-merge state** uses `completedAt` / `startedAt` vs `merged_at`. Eventual green after merge does not rewrite a red or in-flight merge decision.

## Deterministic policy violations

_None._

## Duplicate heads

_None._

## Burst merges (≤60s)

| PRs | Δ seconds |
| --- | --- |
| #1269 / #1270 | 16 |
| #1272 / #1273 | 9 |
| #1285 / #1286 | 9 |
| #1292 / #1295 | 6 |
| #1291 / #1292 | 13 |
| #1292 / #1294 | 50 |
| #1291 / #1295 | 7 |
| #1294 / #1295 | 44 |
| #1291 / #1294 | 37 |
| #1297 / #1298 | 7 |
| #1303 / #1319 | 54 |

## Per-merge detail

| PR | Merged | quality | e2e | PR Preview | main Preview | lag | review | flags |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [#1345](https://github.com/The-AIE/conference-os/pull/1345) | 2026-08-15 16:06:33Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact+indep | in-flight |
| [#1342](https://github.com/The-AIE/conference-os/pull/1342) | 2026-08-15 14:25:41Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(3) | exact+indep | in-flight |
| [#1338](https://github.com/The-AIE/conference-os/pull/1338) | 2026-08-15 14:21:11Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(5) | exact+indep | in-flight |
| [#1324](https://github.com/The-AIE/conference-os/pull/1324) | 2026-08-14 23:04:45Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact+indep | in-flight |
| [#1332](https://github.com/The-AIE/conference-os/pull/1332) | 2026-08-14 22:29:17Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact+indep | in-flight |
| [#1335](https://github.com/The-AIE/conference-os/pull/1335) | 2026-08-14 21:30:56Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(4) | exact+indep | in-flight |
| [#1331](https://github.com/The-AIE/conference-os/pull/1331) | 2026-08-14 21:04:05Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1307](https://github.com/The-AIE/conference-os/pull/1307) | 2026-08-12 19:02:13Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1308](https://github.com/The-AIE/conference-os/pull/1308) | 2026-08-12 16:13:14Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1311](https://github.com/The-AIE/conference-os/pull/1311) | 2026-08-12 15:53:52Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1318](https://github.com/The-AIE/conference-os/pull/1318) | 2026-08-12 15:37:52Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1323](https://github.com/The-AIE/conference-os/pull/1323) | 2026-08-12 15:28:14Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1305](https://github.com/The-AIE/conference-os/pull/1305) | 2026-08-12 15:09:33Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1304](https://github.com/The-AIE/conference-os/pull/1304) | 2026-08-12 14:12:42Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1314](https://github.com/The-AIE/conference-os/pull/1314) | 2026-08-12 12:30:09Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1320](https://github.com/The-AIE/conference-os/pull/1320) | 2026-08-12 10:06:08Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1319](https://github.com/The-AIE/conference-os/pull/1319) | 2026-08-12 09:11:39Z | READY | READY | LEGACY_MISSING | IN_FLIGHT | lagged-1-10(1) | exact | — |
| [#1303](https://github.com/The-AIE/conference-os/pull/1303) | 2026-08-12 09:10:45Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(2) | exact | in-flight |
| [#1317](https://github.com/The-AIE/conference-os/pull/1317) | 2026-08-11 19:09:12Z | READY | READY | LEGACY_MISSING | LEGACY_MISSING | fresh(0) | exact | — |
| [#1316](https://github.com/The-AIE/conference-os/pull/1316) | 2026-08-11 18:47:19Z | IN_FLIGHT | READY | LEGACY_MISSING | LEGACY_MISSING | fresh(0) | exact | in-flight |
| [#1301](https://github.com/The-AIE/conference-os/pull/1301) | 2026-08-11 08:37:15Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1300](https://github.com/The-AIE/conference-os/pull/1300) | 2026-08-11 03:18:52Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(3) | exact | in-flight |
| [#1299](https://github.com/The-AIE/conference-os/pull/1299) | 2026-08-11 03:03:08Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact+indep | in-flight |
| [#1298](https://github.com/The-AIE/conference-os/pull/1298) | 2026-08-11 02:34:26Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(1) | exact | in-flight |
| [#1297](https://github.com/The-AIE/conference-os/pull/1297) | 2026-08-11 02:34:19Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(5) | exact | in-flight |
| [#1296](https://github.com/The-AIE/conference-os/pull/1296) | 2026-08-11 01:38:12Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1294](https://github.com/The-AIE/conference-os/pull/1294) | 2026-08-10 23:40:00Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(5) | exact+indep | in-flight |
| [#1291](https://github.com/The-AIE/conference-os/pull/1291) | 2026-08-10 23:39:23Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(4) | exact+indep | in-flight |
| [#1295](https://github.com/The-AIE/conference-os/pull/1295) | 2026-08-10 23:39:16Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(1) | exact | in-flight |
| [#1292](https://github.com/The-AIE/conference-os/pull/1292) | 2026-08-10 23:39:10Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact+indep | in-flight |
| [#1288](https://github.com/The-AIE/conference-os/pull/1288) | 2026-08-10 22:25:28Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(1) | exact+indep | in-flight |
| [#1287](https://github.com/The-AIE/conference-os/pull/1287) | 2026-08-10 22:24:19Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1284](https://github.com/The-AIE/conference-os/pull/1284) | 2026-08-10 21:16:40Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(2) | exact | in-flight |
| [#1285](https://github.com/The-AIE/conference-os/pull/1285) | 2026-08-10 21:13:55Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(1) | exact | in-flight |
| [#1286](https://github.com/The-AIE/conference-os/pull/1286) | 2026-08-10 21:13:46Z | READY | READY | UNKNOWN | IN_FLIGHT | fresh(0) | exact | — |
| [#1283](https://github.com/The-AIE/conference-os/pull/1283) | 2026-08-10 19:12:48Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1281](https://github.com/The-AIE/conference-os/pull/1281) | 2026-08-10 17:55:48Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(1) | exact | in-flight |
| [#1282](https://github.com/The-AIE/conference-os/pull/1282) | 2026-08-10 17:48:46Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1280](https://github.com/The-AIE/conference-os/pull/1280) | 2026-08-10 16:55:47Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(2) | exact | in-flight |
| [#1278](https://github.com/The-AIE/conference-os/pull/1278) | 2026-08-10 16:36:52Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(1) | exact+indep | in-flight |
| [#1279](https://github.com/The-AIE/conference-os/pull/1279) | 2026-08-10 16:33:27Z | READY | READY | UNKNOWN | IN_FLIGHT | fresh(0) | exact+indep | — |
| [#1277](https://github.com/The-AIE/conference-os/pull/1277) | 2026-08-10 14:29:26Z | READY | READY | IN_FLIGHT | IN_FLIGHT | fresh(0) | exact | in-flight |
| [#1274](https://github.com/The-AIE/conference-os/pull/1274) | 2026-08-10 11:54:49Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(5) | exact | in-flight |
| [#1266](https://github.com/The-AIE/conference-os/pull/1266) | 2026-08-10 11:45:23Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(7) | exact | in-flight |
| [#1273](https://github.com/The-AIE/conference-os/pull/1273) | 2026-08-10 11:30:40Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-gt-10(23) | exact | in-flight |
| [#1272](https://github.com/The-AIE/conference-os/pull/1272) | 2026-08-10 11:30:31Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-gt-10(21) | exact | in-flight |
| [#1267](https://github.com/The-AIE/conference-os/pull/1267) | 2026-08-10 11:23:59Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(7) | exact+indep | in-flight |
| [#1275](https://github.com/The-AIE/conference-os/pull/1275) | 2026-08-10 10:06:24Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(6) | exact | in-flight |
| [#1270](https://github.com/The-AIE/conference-os/pull/1270) | 2026-08-10 09:30:41Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(4) | exact | in-flight |
| [#1269](https://github.com/The-AIE/conference-os/pull/1269) | 2026-08-10 09:30:25Z | READY | READY | IN_FLIGHT | IN_FLIGHT | lagged-1-10(2) | exact | in-flight |

See `docs/runbooks/merge-cadence.md` (merge audit section) and parent issue #774 packet E / child #827.

