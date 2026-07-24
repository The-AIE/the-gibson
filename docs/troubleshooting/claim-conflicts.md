# Claim conflicts

## Symptoms

- `claim.sh` exits: scope overlap with live claim
- Two worktrees both editing `schema.prisma`
- Stale claim row >24h with no activity

## Why

Claims isolate *logical* scope; worktrees isolate *files* ([docs/05](../05-concurrency.md)).
Racing a live claim re-creates L-001.

## Checklist

| Check | Action |
|---|---|
| Read `docs/active-work.md` | Find overlapping scope tokens |
| Same hot file | Serialize with `Blocked by #N`; don't parallelize |
| Stale >24h | Verify worktree/branch activity; renew timestamp **or** release after verification |
| Wrong session | Never strip someone else's claim without verification |
| Label without row | `release-claim.sh` or manual: remove label + fix table |

## Recovery

```bash
# See live claims
cat docs/active-work.md

# If your claim is done
./scripts/release-claim.sh <issue>

# If conflict: different issue or wait — never force
```

## Human gate

G13 — two agents want conflicting approaches and re-queue didn't resolve → decision
card for Mark.
