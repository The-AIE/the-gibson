# Atomic spike: evidence source for cost ledger and vendor identity

Issue #505. Subject: [atomicdotdev/atomic](https://github.com/atomicdotdev/atomic) v0.20.0 (Apache-2.0, Rust, pre-1.0).
Run on 2026-10-20, macOS arm64, prebuilt release binary (sha256 verified against the release checksums), isolated `HOME`, throwaway repo. Nothing in this repo or any real agent config was touched.

## What was tested

1. `atomic init`, `identity new`, `record` in a scratch repo.
2. `atomic agent enable --agent claude-code`.
3. A synthetic Claude Code session driven through the hook entry points (`agent hooks claude-code session-start | user-prompt-submit | post-tool | stop | session-end`) with hand-written JSON payloads and a hand-written transcript.
4. `atomic agent status --json`, `atomic agent attest`, `atomic change <hash>`.

## Measured results

| Question | Result |
|---|---|
| Does a turn become a change with session and vendor? | **Yes.** Change recorded; `Vendor: Anthropic`, session id, `agent_name: claude-code`. |
| Is there a provenance graph? | **Yes.** `goal » <prompt>` → `commitment » Edit <file>`, 3 nodes / 2 edges. |
| Session attestation? | **Yes.** One attestation covering the change; `attest -s` reports AI-authored share and source vendor. |
| Machine-readable status? | **Yes.** `agent status --json` (sessions, phase, model, `agent_vendor`, turn count). |
| Token and cost in attestation? | **Not shown.** The change printed `Model: unknown`; no token or cost fields appeared. The synthetic transcript may not match the real transcript shape, so this is **inconclusive, not a negative**. Needs a real session. |
| Agent coverage | `agent status --json` lists grok, hermes, pi, codex, devin, cursor, gemini-cli, opencode and others as detectable. This corrects the README table, which lists only five. Whether the Grok and Hermes hooks produce usable turns is untested. |
| Install side effects | `agent enable` wrote `.claude/settings.json` hooks and a `.vault/` and `.atomicignore`. Skills/prompt install failed (package fetch; offline-style error) while built-in hooks still installed. |

## Gaps against the gap list

| Gibson gap | Verdict | Reason |
|---|---|---|
| #449 / #470 vendor identity | **Promising, unproven** | Vendor is a structural field on the attestation, not a commit trailer. Needs a Codex session to confirm the reviewer case. |
| #74 / #351 cost ledger | **Unproven** | Tokens/cost not observed (see above). Decide after one real session. |
| #409 session budget | **Unproven** | Depends on the same token/cost fields. |
| #410 outcome ledger | **Partial** | Provenance graph gives goal/commitment/verification nodes; no outcome metric. |

## Costs and risks observed

- Hook commands are written into `.claude/settings.json`, the same file vendor adapters (doc 10) use. A real adoption needs a merge strategy.
- `atomic` must be on `PATH` for the hooks; they are guarded with `|| true`, so a missing binary fails silent.
- Atomic keeps its own store (`.atomic/atomic.redb`) and a second change history next to git. Git remains the system of record here; Atomic would be read-only evidence.
- Pre-1.0: v0.19.1 to v0.20 documents a manual process/socket cleanup on upgrade.

## Decision

**Conditional go for a second, real-session spike; no-go for adoption as substrate.**

Next step (follow-up issue): run one real Claude Code session and one real Codex session in a scratch repo with `ATOMIC_SERVICE=local`, then answer only the open question: do token, model and cost fields populate in the attestation (`atomic agent attest -v`, `--json` where offered)? If yes, wire `agent status --json` into the #74 ledger as a read-only sensor input. If no, close the evaluation.

Reproduce: download the release asset, verify `checksums-sha256.txt`, set `HOME` to a scratch directory so global agent configs (`~/.codex`, `~/.gemini`) are untouched, then run the commands above.
