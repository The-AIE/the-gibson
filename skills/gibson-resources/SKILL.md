---
name: gibson-resources
description: "Discover which AI runners and infrastructure are actually available right now (Grok/Codex/Claude/Hermes CLIs, Devin API, GitHub auth, bot identities, satellite machines, MCPs) and produce the cost-optimized routing table the Gibson loop will use. Second stage of the /gibson pipeline; also standalone ('what runners do I have', 'fleet inventory', 'check the fleet')."
---

# gibson-resources — inventory before dispatch

Probe, don't assume. Every prior session's notes about what works may be stale —
tokens expire, CLIs update, machines go offline. Verify each resource LIVE and
report only what you confirmed this run.

## The probe list

| Resource | How to verify (cheap, non-destructive) |
|---|---|
| **Grok CLI** | `~/.grok/bin/grok --version` (also try `grok`). Flat-rate pool — the volume workhorse. |
| **Codex CLI** | `codex --version`; confirm it runs inside a trusted git dir. Note: reviews need `-s read-only`. |
| **Claude Code** | you're running in it — note model + whether `claude` CLI headless is available for dispatched lanes. |
| **Hermes** | `hermes --version` if present. |
| **Devin** | `DEVIN_API_KEY` set? `scripts/devin-supervisor.sh --help` from the Gibson clone. **NEVER run `ensure` as a probe — if no session exists it CREATES one, which bills ACUs (real money). Spend needs the owner's explicit OK first (docs/14), a cap is not approval.** Report key-present/absent + `DEVIN_MAX_ACU` state only. |
| **GitHub** | `gh auth status`; which account; GraphQL vs REST budget state. Bot identities: check for GitHub App creds (e.g. `~/.claude/secrets/*.pem` + token-mint helpers) — distinct pusher/attester identities matter for review-gate integrity. |
| **Satellite machines** | ssh reachability of known satellites (e.g. `ssh -o BatchMode=yes -o ConnectTimeout=5 <host> 'echo ok'`). Report auth state honestly (a reachable box with dead GitHub auth is relay-only). |
| **MCPs** | note connected MCP servers relevant to the target (DB, Vercel, etc.). |

## Output: the routing table

Emit a table the `gibson-run` skill consumes directly, applying docs/15's
standing order (flat-rate absorbs volume; metered buys judgment):

- **implementer.default** → Grok (if alive), else Codex
- **implementer.second / reviewer.primary** → Codex (Grok reviews only when
  Codex is the author — Law 5 cross-vendor)
- **judgment + capability-gated work** → Claude: specs, escalation after N
  failures, adversarial verdicts, merge-bar calls — plus feature work whose
  capability bar the flat-rate pools genuinely can't clear (docs/15 routes by
  capability x marginal cost). Spend sparingly, reserve cap headroom.
- **merge_captain** → Devin IF key + supervisor wiring verified. ELSE fail
  closed in this strict order: (1) cross-vendor review remains MANDATORY while
  any second vendor is alive — Devin being unwired never relaxes Law 5; (2)
  only if NO other vendor is reachable at all, docs/11's fresh-context
  adversarial pass (different session, same platform) substitutes, flagged in
  the digest as degraded mode; (3) Tier C parks at the human gate in every
  mode. The routing table must say plainly that Devin is unwired and exactly
  what wiring it needs.
- Per-resource: verified-at timestamp, failure notes, cost tier.

Also report gaps as Ask Contract items when only the owner can fix them
(expired auth, missing API key, unprovisioned bot identity) — one compact list,
not a drip of interruptions.
