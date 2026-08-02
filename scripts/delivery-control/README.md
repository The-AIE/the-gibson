# scripts/delivery-control/

Portable **delivery control** tooling for target repos ([docs/23](../../docs/23-delivery-control.md)).

| Script | Mode | Mutates? |
|---|---|---|
| `audit.sh` | audit | No |
| `apply-branch-protection.sh` | harden | Only with `--apply` |
| `apply-production-env.sh` | harden | Only with `--apply` |
| `promote.sh` | promote (model B) | Only with `--apply` |
| `hotfix-prep.sh` | hotfix | Creates local branch |
| `forward-port.sh` | hotfix | Only with `--apply` |

## Hard block

**Never rotate secrets** (human gate G4). These scripts never touch `NEON_API_KEY`
or other credentials.

## Config

Optional target file `.gibson-delivery.json` — see docs/23. Or pass `--repo owner/name`.

## Prerequisites

`gh` (admin for harden), `jq`, `git`.
