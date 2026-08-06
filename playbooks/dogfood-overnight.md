---
title: "Playbook · Overnight dogfood"
nav_exclude: true
role: operator
inputs:
  - Gibson clone on a machine with one runner CLI (prefer Grok flat-rate)
  - Target repo (often Gibson itself) with a matching origin
  - Open backlog issues that are not parked behind human lab gates
outputs:
  - Preflight green from scripts/dogfood-prep.sh
  - Overnight loop journal under <repo>/gibson/journal.md
  - Evidence copy under memory/dogfood/ after review
  - At least one merged PR (done criterion for issue #96)
gates:
  - Preflight must pass before --run
  - --run requires --confirm YES
  - Kill switch: touch <repo>/gibson/HALT or GIBSON_HALT=1
  - Do not dogfood parked Goose live-path issues (#28/#33/#36) without lab approval
forbidden:
  - Unattended --run without confirm
  - Publishing marketing artifacts (docs/14)
  - Force-push, secrets, production destroy
sources:
  - docs/11-solo-loop.md
  - docs/21-operator-readiness.md
  - issue #96
---

# Overnight dogfood — operator playbook (#96)

> 🙂 **In plain English:** run the fleet on itself overnight, with a kill switch
> and a morning review. This is how we prove the harness, not a demo slide.

## Parked work (do not include in the overnight backlog)

| Issue | Why parked |
|---|---|
| #28 / #33 / #36 | Live Goose path — operator deferred testing |
| Mark-gated publish | Outward public artifacts (docs/14) |

Prefer open, non-parked enhancement/bug work or Phase-2 demo Tier A issues.

## 1. Preflight (no model spend)

```bash
GIBSON=~/Code/the-gibson
$GIBSON/scripts/dogfood-prep.sh \
  --repo "$GIBSON" \
  --repo-slug mrhinkle/the-gibson \
  --runner grok \
  --max-iterations 20 \
  --error-budget 5 \
  --solo-platform \
  --check-only
```

Fix every `FAIL` line before continuing.

## 2. Launch (explicit confirm)

```bash
$GIBSON/scripts/dogfood-prep.sh \
  --repo "$GIBSON" \
  --repo-slug mrhinkle/the-gibson \
  --runner grok \
  --max-iterations 20 \
  --error-budget 5 \
  --solo-platform \
  --run --confirm YES
```

Single-model primary path: `--solo-platform` (#69) so Law 5 does not deadlock
when only one vendor CLI is installed.

## 3. Kill switches

| Switch | How |
|---|---|
| Local file | `touch <repo>/gibson/HALT` |
| Env | `GIBSON_HALT=1` |
| Remote (when gh works) | `gibson-halt` label or `.gibson-halt` sentinel |

## 4. Morning review

1. Read `<repo>/gibson/journal.md` — failures verbatim (Law 8).
2. List PRs opened overnight; review with a **different** agent when available.
3. Copy journal + short notes into `memory/dogfood/YYYY-MM-DD.md` using the
   template in `memory/dogfood/README.md`.
4. File lessons for anything the harness missed (Law 9).

## Done for issue #96

- [ ] Preflight green on the dogfood host
- [ ] Overnight run completed or halted under budget (not a silent hang)
- [ ] Journal committed under `memory/dogfood/`
- [ ] ≥1 PR merged with no human keyboard between start and PR review
