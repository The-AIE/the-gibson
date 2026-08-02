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
- **judgment** → Claude (specs, escalation after N failures, adversarial
  verdicts, merge-bar calls) — spend sparingly, reserve cap headroom
- **merge_captain** → Devin IF key + supervisor wiring verified. ELSE fail
  CLOSED, per docs/11: the merge path becomes fresh-context adversarial
  self-review (a different session, never the authoring one) + the repo's own
  merge rules, with Tier C always parking at the human gate — and the routing
  table must say plainly that Devin is unwired and what wiring it needs.
- Per-resource: verified-at timestamp, failure notes, cost tier.

Also report gaps as Ask Contract items when only the owner can fix them
(expired auth, missing API key, unprovisioned bot identity) — one compact list,
not a drip of interruptions.
