# Pre-registered predictions — does the harness do what we claim?

Registered 2026-08-15, before the measurement windows close. The reading list is
frozen as of this date; these predictions derive from the doctrine (gibson#210) and
the adopted findings, and they are stated so that the readouts below can confirm
**or falsify** them. No prediction may be edited after its window opens; a wrong
prediction is reported as wrong.

## Instruments (all live as of registration)

- `reviewPath` / `avoidableOwnerAttestation` metrics in the merge audit (COS #1335)
- Daily sensor-health reports (GIB #212, COS #1343, CB #503) + weekly watchdog
- Spec-gate score comments on gated issues (spec-gate skill v1.2.0)
- Review-round counts (monthly audit; GIB round-cap logs from #218)
- Outcome ledger (`docs/process/outcome-ledger.jsonl`, baseline seeded 2026-08-10)

## Predictions

**H1 — Spec gate reduces rework.** Over the first 30 days of gated dispatches,
Tier B/C issues that passed the spec gate will average **≤ 2 review rounds** and
show **fewer post-merge fix PRs** than the pre-gate baseline (the 2026-08-14 audit
window and the ungated 2026-08-15 dispatches, which ran 3 rounds on the hardest
case). Falsified if gated work shows no reduction — in which case the gate is
redesigned or dropped, per its own charter.

**H2 — Sensor loop bounds time-to-detection at one day.** No CI lane will be
broken or blind for more than 24 hours without appearing in a standing report,
and no BLIND finding will persist 7 days without a tracked issue. Baseline: one
lane blind for its entire lifetime; a release workflow broken 9 days, unnoticed.

**H3 — Converted lessons do not recur.** Zero recurrences of failure classes
converted to Tier-1 artifacts: no review round lost to an unsigned commit in GIB
(hooks + handoff refusal, #215); no hardcoded-identifier breakage of the
bot-push path (live resolution); no reassertion of retired facts that have rules.
Any recurrence is a named artifact failure, not a statistic.

**H4 — Review authority decentralizes.** `avoidableOwnerAttestation` trends to
zero and the owner-attestation share of routine (non-owner-gated) merges falls
below **25%** (baseline: majority), as trusted-provider review and delegated
attestation absorb routine work.

**H5 — Identity separation ends gate misfires.** Zero instances of the
same-actor check blocking a *legitimately independent* attestation now that
implementer lanes carry their own credentials (baseline incident class: 11 PRs
stalled 2026-08-01).

**H6 — Sensor findings are trustworthy enough to act on.** At the 2026-08-21
review: precision ≥ 90% (findings are real) AND no known-broken lane missed
(recall check). If met, auto-remediation promotes with its hard limits; if not,
observability gets fixed first and the window extends — and H6 is reported as
not yet met.

## Readout schedule

| Date | Readout | Predictions scored |
| --- | --- | --- |
| 2026-08-21 | Auto-remediation promotion review | H6 |
| 2026-09-14 | Monthly process audit | H1 (interim), H2, H3, H4, H5 |
| ~2026-09-15 | 30-day paper-grade readout (outcome-ledger deltas for DRAFT §10) | all |

## Commitments

Results are reported in the paper (or its revision) regardless of direction.
Instrument gaps found during readout are documented, not papered over. The
strongest available outcome for the paper is not "all predictions confirmed" —
it is an honest scorecard from pre-registered predictions, whichever way they
fall.
