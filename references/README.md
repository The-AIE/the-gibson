# Vendored reference material

Static, point-in-time copies of external reference data the Gibson's playbooks
read from — not a second implementation, and not a runtime dependency (same
"borrow vocabulary, no runtime dependency" posture as D-008's OWASP Agentic
mapping in `docs/26-owasp-agentic-mapping.md`). Nothing in here is installed,
imported, or executed as part of the harness itself; roles read the relevant
file when the playbook tells them to, the same way they read `docs/*.md`.

This is distinct from `skills/` (the Gibson's own orchestration meta-skills —
`gibson`, `gibson-audit`, etc., which wrap the harness's own scripts and
playbooks) and from `templates/` (what gets installed into an adopting
target repo).

| Directory | Source | Pinned commit | License | Read by |
|---|---|---|---|---|
| `codeguard/` | [cosai-oasis/project-codeguard](https://github.com/cosai-oasis/project-codeguard) | `7e19e207bd67abbd3d04ae664441595410df1157` | see `LICENSE.md` | `playbooks/security.md` (Layer 2/6), `docs/08-security.md` |
| `ui-ux-pro-max/` | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | `abb7f2fd5a083fa1ff55c326a963ff0d95c33f99` | MIT, see `LICENSE.txt` | `playbooks/ux-evaluator.md`, `docs/07-uiux-evaluation.md` (design-language authoring + grading) |
| `vercel-optimize/` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) (`skills/vercel-optimize`) | `7c180d9044c9ae2b442b567aad4e42a28dd5ed62` | see upstream repo | `docs/17-deployment-optimization.md` ("Inspect" mode) |

## Why vendored instead of a live pull

Same reasoning as `docs/26`'s D-008 posture: a live dependency on someone
else's repo/service is a second point of failure and an unreviewed moving
target. A pinned copy is exactly what was verified before adoption, forever,
until someone deliberately re-syncs it.

## Re-syncing

Manual. Re-clone the source at a newer commit, diff against what's here,
update the commit SHA in this table, and note the change in
`memory/DECISIONS.md` if the update is substantive (not just a typo fix).

## Note on `vercel-optimize`

Unlike the other two (static data + rules, read-only), `vercel-optimize` is an
*operational* skill — it calls the live Vercel CLI/API (`vercel metrics`,
`vercel usage`) against an authenticated, linked project to pull real
production signals. It is not auto-invoked by any playbook; it's run on
demand (adoption, monthly drift check, post-launch) per doc 17's "Inspect"
mode, same as the doc already described before this skill existed to
implement it.
