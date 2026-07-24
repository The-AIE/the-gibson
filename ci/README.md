# ci/ — reusable workflow templates

Installed into target repos at adoption (docs/13), calibrated per repo. Templates:

- `gibson-gate.yml` — green gate + security layers 1–3. **Present.**
- `security.yml` — layers 4 (authz matrix), 5 (ZAP baseline vs. preview URL),
  8 (posture probe); nightly full DAST vs. staging. *Spec: docs/08. Build: DOC-BACKLOG P0.5.*
- `ux-eval.yml` — Playwright contract flows + axe + visual regression + Lighthouse
  against the PR's Vercel preview (resolve URL from the deployment event).
  *Spec: docs/07. Build: DOC-BACKLOG P0.5.*
- `schema-guard.yml` — schema diff without migration file fails. *Spec: docs/12.*
- `retro.yml` — weekly scheduled sweep: PR/CI/verdict/cost exhaust → lesson
  candidates + digest. *Spec: docs/09. Build: DOC-BACKLOG P0.5.*

Principle: CI is the enforcement layer precisely because it is vendor-blind — it
doesn't care which runtime wrote the code (docs/10).
