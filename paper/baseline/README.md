# Frozen baselines (captured 2026-08-15)

First-party measurements frozen before the H1–H7 windows close. Reproducible:
each artifact names its exact command.

## Merge-audit baseline (H1/H4)

`cos-merge-audit-50-2026-08-15.md` — `node scripts/audit-merges.mjs --repo
The-AIE/conference-os --limit 50` at 2026-08-15. Note: this window already
includes 2026-08-14/15 merges (the first partially-harnessed days), so it is a
conservative baseline — the pre-harness era looks *better* in it than it was.
A 100–150-merge deep window was attempted three times and blocked by GitHub
GraphQL 504s; retry as a follow-up for a cleaner pre/post split.

## Detection-latency baseline (H2)

| Incident | Broken/blind from | Detected & tracked | Undetected |
| --- | --- | --- | --- |
| clerk-authz-matrix (required lane, never green) | lane added 2026-07-26 | cos#1336, 2026-08-14 | 19 days (entire life) |
| Release workflow (startup_failure on tags) | 2026-08-01 | cos#1344, 2026-08-15 | 14 days |
| preview-deploy-smoke (never green) | first run 2026-08-11 | sensor report, 2026-08-15 | 4 days |
| Org-transfer doc/config breakage | ~2026-08-11 | fixed 2026-08-15 (cos#1338) | ~4 days |

Historical mean ≈ 10 days. Pre-registered target (H2): ≤ 1 day.

Sources: lane-creation commit dates (`git log --diff-filter=A`), run histories
(`gh run list`), issue timestamps.
