# 08 — The Security Testing System

Eight layers. Each is either **hard-fail** (blocks merge/release) or **report-only**
(files issues). Report-only is a *transition state* with a written promotion
condition, never a resting place — ConferenceOS's high-CVE layer sat report-only
"until pre-existing highs are cleared"; The Gibson tracks each promotion as an issue
with an owner and a date.

| # | Layer | Tooling | When | Fails |
|---|---|---|---|---|
| 1 | Secrets | gitleaks | every PR + push | **hard** |
| 2 | SAST | Semgrep (OWASP + framework rules) and/or CodeQL | every PR | **hard** on high+ |
| 3 | Supply chain | npm audit + OSV-Scanner + dependency-review + lockfile-lint | every PR + nightly | **hard** on critical; high per promotion schedule |
| 4 | AuthZ matrix | generated route×role tests + IDOR sweep | every PR touching routes; nightly full | **hard** |
| 5 | DAST | OWASP ZAP baseline vs. **preview deployment**; full scan nightly vs. staging | per-PR (baseline), nightly (full) | **hard** on high+ (baseline) |
| 6 | Adversarial review | inferential — security-lens reviewer with refutation pass | Tier B/C PRs | **hard** via review verdict |
| 7 | AI-surface review | prompt-injection / untrusted-content audit of any LLM feature | PRs touching AI features | **hard** |
| 8 | Runtime posture | headers (CSP, HSTS, frame), rate limits, cookie flags — scripted probe vs. preview + prod | per-PR probe + drift sensor | **hard** on regression |

## Layer notes

**1 — Secrets.** Also: no secrets in URLs, `.env*` gitignored verified at adoption,
and a leak = immediate human gate (rotation requires a human).

**2 — SAST.** Semgrep is the workhorse (fast, per-PR, custom rules); CodeQL where
the repo's language/size justifies it. **Custom rules are ratchet output**: when a
security lesson lands in `memory/LESSONS.md`, the historian's fix is often a Semgrep
rule — the agent that hit the bug writes the rule that makes it impossible.

**3 — Supply chain.** New-dependency PRs get the elevated treatment automatically
(hot-file rule): provenance check (age, maintenance, install-script flags), and the
dependency lands in its own commit for revertability.

**4 — AuthZ matrix.** The single highest-value custom layer for multi-tenant apps.
Generate the route inventory (`scripts/route-inventory.mjs` per framework), then
assert every route × every role: expected 200/403/404, and **cross-tenant IDOR
probes** — role A requesting role B's object IDs must 403/404, never 200. New route
without a matrix entry = CI failure. This encodes the ConferenceOS
SECURITY-CHECKLIST (server-boundary validation, no mass-assignment, reject unknown
keys) as executable tests instead of prose.

**5 — DAST.** ZAP baseline (passive, fast) against the ephemeral preview URL each PR
— it's a real deployment with prod-like config; scanning it costs nothing and hits
what static analysis can't (headers, redirects, auth flows, error leakage). Nightly
full/active scan runs against **staging only** — never active-scan prod.

**6 — Adversarial review.** The security lens (doc 06) with the fan-out treatment on
Tier C: reviewers prompted to *construct the exploit path*, then skeptics prompted to
*refute* it. Cross-vendor. What survives is filed with severity and repro.

**7 — AI-surface review.** For any feature that feeds model prompts: retrieved and
user-supplied content is untrusted; instructions in data are never followed; output
is treated as tainted for downstream sinks (SQL, HTML, shell); tool scopes are
minimal. (The checklist ConferenceOS wrote, promoted to a gate.)

**8 — Runtime posture.** A ~50-line probe script asserting response headers, rate
limits (429 after N burst requests on public POST endpoints — the known ConferenceOS
gap #94), cookie flags, and TLS config. Runs per-PR against preview, and as a drift
sensor against prod — posture regressions are caught even when no PR caused them
(platform config changes).

## Release gate

`security-gate` is a `needs:` of the release workflow: **no release artifact is
created if the gate fails.** Tags/releases re-run layers 1–3 fully even if the
constituent PRs passed, because the world (CVE feeds) changes between merge and
release.

## Human gates in security

- Confirmed secret leak → stop, human rotates.
- Vulnerability discovered in *production* (not a PR) → file privately, human decides
  disclosure/hotfix path.
- Any active exploitation signal → stop everything, page Mark.
