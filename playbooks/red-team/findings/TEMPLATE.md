# Red-Team Findings — <TARGET> — <YYYY-MM-DD>


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../../../AGENTS.md). This file must not add, drop, or weaken those rules.

**Run by:** <name / agent>
**Target build:** <preview URL or commit SHA>
**Verdict:** NOT READY | READY FOR THIRD-PARTY REVIEW

## Run stamp (audit trail)

Fill every row for a real run. Leave placeholders only on unused drafts.
Never put secret values, local credential paths, real PII, production-write
claims, or absolute private home paths in this ledger.

| Field | Value |
|---|---|
| Target commit (full immutable SHA) | `<40-char lowercase hex>` |
| Target URL classification | `preview \| local \| non-production` (never production write) |
| Goose CLI version | e.g. `1.45.0` |
| Goose CLI binary digest (sha256) | `<64-char hex of the verified release asset or installed binary>` |
| Recipe schema / version | e.g. `1.0.0` |
| Recipe SHA-256 | `<sha256 of playbooks/recipes/red-team.yaml bytes>` |
| Toolchain-lock SHA-256 | `<sha256 of playbooks/recipes/red-team.toolchain.json bytes>` |
| Target-profile SHA-256 | `<sha256 of the exact target profile file bytes>` |
| Start UTC | `YYYY-MM-DDTHH:MM:SSZ` |
| End UTC | `YYYY-MM-DDTHH:MM:SSZ` |
| Supervised mode | `yes \| no` (Mark-authorized #28 lab only when yes) |
| Transcript / evidence reference | sanitized artifact id or relative path — no secrets, no private home paths, no real PII |

Canonical digest commands (macOS; do not commit generated digests):

```bash
shasum -a 256 playbooks/recipes/red-team.yaml | awk '{print $1}'
shasum -a 256 playbooks/recipes/red-team.toolchain.json | awk '{print $1}'
shasum -a 256 playbooks/red-team/targets/<profile>.md | awk '{print $1}'
```

## Summary
- Critical: <n>   High: <n>   Medium: <n>   Low: <n>
- Phase-2 automated sweep: <green / red — list what's red>
- Offline recipe sensor: <green / not applicable>
- Official Goose `recipe validate`: <ran / NOT RUN>
- Live execution: <not authorized \| Mark-authorized #28 lab>

## Findings

### [SEVERITY] Short title
- **Subsystem:** auth | payments | pii | injection | infra | business-logic
- **Where:** file:line or route
- **Repro:** exact steps or request to reproduce
- **Impact:** what an attacker gets (money, data, access)
- **Fix:** proposed remediation
- **Status:** open | fixed | re-tested-clean
- **Issue:** #<github-issue>

<!-- repeat per finding, Critical/High first -->

## Re-test log
- <date> — re-ran Phase <n> after fix for <finding>; result: <clean / still open>
