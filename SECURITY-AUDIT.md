# Security Audit Report — The Gibson

**Audience:** Operators, adopters, security reviewers, and anyone who needs to know how The Gibson protects the software it builds and ships.
**Status:** Living document. Update after every major harness change or after a production incident. Last structured review: 2026-07-29.
**Related doctrine:** [docs/08-security.md](docs/08-security.md), [playbooks/security.md](playbooks/security.md), [ci/security.yml](ci/security.yml), [docs/14-human-gates.md](docs/14-human-gates.md).

## 1. Scope

This audit covers:
- The Gibson harness itself (doctrine, scripts, CI templates, memory, adapters).
- The software produced by agent fleets under the harness (target repos).
- Surfaces created by the productization path (MCP / CodeWright / Foreman, GitHub access, preview deployments).

Out of scope for this document (covered by separate runbooks):
- Physical / cloud account security of the operator’s own machines.
- Third-party SaaS (Vercel, GitHub, model providers) beyond the controls we place on them.

## 2. Threat Model (STRIDE-style summary)

| Threat category | Examples in this system | Primary mitigations |
|---|---|---|
| **Spoofing** | Malicious PR claiming to be an agent; forged decision cards | GitHub identity + required reviews; decision cards only via trusted channels (Hermes / MCP with auth); never auto-approve |
| **Tampering** | Agent or attacker modifies code outside claimed scope; secret injection | Worktree + scope claims; green gate; secrets scanning (hard-fail); PR-only changes from Foreman tools |
| **Repudiation** | “Which agent did this?” | Memory + historian; PR authorship; telemetry; lessons with links |
| **Information disclosure** | Secrets in code/URLs; error leakage; cross-tenant data | gitleaks hard-fail; posture probe (headers); AuthZ matrix + IDOR; AI-surface rules treat model output as tainted |
| **Denial of service** | Runaway agents / cost; rate-limit abuse | Model-economics grades; claim limits; spending gates (G5); posture rate-limit checks |
| **Elevation of privilege** | Agent gains production write or secret access | Human gates for destructive/spend/go-live; least-privilege tokens; no irreversible MCP actions |
| **AI-specific** | Prompt injection, tool misuse, hallucinated “secure” code | Layer 7 AI-surface review; adversarial review (layer 6); “never grade your own homework”; untrusted content rules |

## 3. Controls Mapped to the Eight Layers

| Layer | Control | Enforcement | Hard-fail? |
|---|---|---|---|
| 1 Secrets | gitleaks + .env gitignore verification | every PR + push | Yes |
| 2 SAST | Semgrep (OWASP + custom) / CodeQL | every PR | High+ |
| 3 Supply chain | npm audit, OSV, dependency-review, lockfile-lint | PR + nightly | Critical (high on schedule) |
| 4 AuthZ + IDOR | Generated route matrix + cross-tenant probes | route-touching PRs + nightly | Yes |
| 5 DAST | ZAP baseline vs **preview**; full vs staging only | PR / nightly | High+ on baseline |
| 6 Adversarial | Security-lens reviewer + refutation | Tier B/C | Via review verdict |
| 7 AI-surface | Prompt-injection / untrusted-content checklist | PRs with LLM features | Yes |
| 8 Runtime posture | Headers, cookies, rate limits, TLS probe | PR vs preview + prod drift | Regression |

Additional non-layer controls:
- Human gates (doc 14): secret rotation, production vuln, active exploitation, prompt-injection steering.
- Ask Contract: every human ask explains what / does / why / risks.
- Scope claims + worktrees: agents cannot freely edit outside their claim.
- Release gate: security-gate is a hard `needs:` of any release workflow.

## 4. Current Implementation Status

| Area | Status | Notes |
|---|---|---|
| Doctrine (docs/08, playbook) | Complete | Clear hard vs report-only |
| CI template (ci/security.yml) | Present | Layers 4, 5, 8 + nightly; layers 1–3 expected from standard target CI |
| Scripts (posture-probe, route-inventory, preview-url) | Present | Must be vendored at adoption |
| AuthZ matrix example | Present | examples/08-authz-matrix-sample.md |
| Custom Semgrep rules from lessons | Process defined | Ratchet produces them; inventory of live rules is per-target |
| MCP / Foreman surface | In progress (Phase 6) | Tools must remain prepare-PR / decision-card only |
| Production drift sensor | Designed | Posture vs prod |
| Formal threat-model document | This file | Living |

## 5. Residual Risks & Gaps

1. **Adoption gap** — target repos that have not yet vendored the scripts / matrix / CI still run only partial layers. Mitigation: adoption playbook + gate-baseline.
2. **Report-only → hard-fail promotions** — high CVEs or soft findings need explicit issues with owners and dates (doctrine requires this; process must be followed).
3. **Model-provider compromise** — if a frontier model provider is compromised, generated code could be malicious. Mitigations: multi-vendor review, never single-agent grade own work, security layers still run on output.
4. **Preview environment fidelity** — DAST/posture only as good as the preview config. Require prod-like env vars on previews.
5. **Human gate fatigue** — too many cards can train operators to click yes. Mitigated by strict list in doc 14 and “do-nothing is safe”.
6. **MCP auth surface** — license-key / token handling must stay server-side; tools must never accept or echo secrets.

## 6. Actionable Recommendations

### Immediate (this week)
- [ ] Ensure every adopted repo has the security.yml + gitleaks + Semgrep (or equivalent) as hard-fail.
- [ ] Vendor `posture-probe.sh` and `route-inventory.mjs` into targets that lack them.
- [ ] Create promotion issues for any remaining report-only high findings with owners + target dates.
- [ ] Confirm MCP tools (when landed) never perform irreversible acts.

### Short-term
- [ ] Run a full adversarial + ZAP baseline pass on the next Tier C release of an adopted product.
- [ ] Add or update Semgrep rules from any new LESSONS.md security entries.
- [ ] Document the exact token scopes used by agents and by the MCP server.

### Ongoing
- [ ] Historian weekly sweep includes security findings.
- [ ] After any secret-related incident, re-run layer 1 + posture and file a lesson.
- [ ] Quarterly downward stress-test of controls that stronger models may have made pure friction (doc 09).

## 7. How to Run a Security Review (checklist)

1. Load [playbooks/security.md](playbooks/security.md).
2. Confirm CI layers 1–3 on the PR.
3. For Tier C / release / AI or route changes: run full procedure (AuthZ, ZAP baseline on preview only, adversarial construct+refute, AI-surface, posture).
4. Post the layer results table on the PR.
5. File findings with severity + exploit path; never soften a hard-fail layer.
6. If secret leak or active exploitation → stop and escalate per human gates.

## 8. Sign-off Template (for a specific release)

```
Release / PR: 
Date: 
Reviewer (security role / human):
Layers 1–8: all hard-fail green / exceptions documented in issues #
Residual risks accepted: 
Human gates required: yes/no (list)
Approved for ship: 
```

---

This audit is itself subject to the ratchet. Any failure that happens twice becomes a new sensor or guide.
