---
title: "17 · Site checkups and tune-ups"
parent: The Doctrine
nav_order: 17
---

# 17 — Deployment Target: Inspection & Optimization

> 🙂 **In plain English:** Besides building features, the crew can check how the live
> site feels — speed, cost, caching — and suggest tune-ups ranked by how much they help
> versus how hard they are.

Doc 13 audits the *repo* (harnessability). This doc audits and improves the
*running deployment* — how the app is built, served, cached, priced, and
experienced on Vercel. It closes a real gap: pre-Gibson, deploy-side sensing was a
handful of drift sensors (Lighthouse budgets, posture probe) with no mechanism to
turn findings into optimization work.

Two modes, one rule:

- **Inspect** — read-only audit producing a scored report. Runs at adoption,
  monthly as a drift sensor, and after any major launch.
- **Optimize** — findings become issues through the normal queue (doc 04), built
  and gated like any work.
- **The rule:** every optimization PR carries its measurement — the metric before,
  the metric after, on the preview deployment or production field data. An
  optimization without a number is a style preference (principle: sensors decide,
  not vibes). No-regression guard: an "optimization" that worsens any budgeted
  metric is a REQUEST_CHANGES.

## The inspection checklist (per audit)

### 1. Rendering & delivery (usually the biggest win)
- **Per-route rendering mode:** which routes are static, ISR, SSR, edge? Flag
  dynamic rendering on content that changes rarely (ISR/static candidates) and
  static rendering on personalized content (correctness bug, not just perf).
- **Caching:** `Cache-Control`/`s-maxage`/`stale-while-revalidate` per route type;
  fetch-cache and data-cache usage; cache HIT ratio from logs. Flag `no-store`
  defaults on hot paths.
- **Payload:** bundle analysis (first-load JS per route vs. budget), unused
  dependencies, images through the image optimizer with correct sizes/formats,
  font loading strategy.

### 2. Field performance (users, not lab)
- Web Vitals from real traffic (Vercel Speed Insights / Analytics): LCP, CLS, INP
  by route and device class — lab Lighthouse already gates PRs (doc 07); *field*
  data is the truth this audit adds. Flag routes where field ≪ lab (real-device
  or real-network problems the lab misses).

### 3. Compute & cost
- Function invocation counts, duration percentiles, memory sizing, cold-start
  frequency; edge-vs-node runtime fit per function.
- **Region topology:** function regions vs. database region — the classic silent
  tax is compute in one region round-tripping to a DB in another. Flag any
  cross-region hot path.
- Bandwidth, image-optimization quota, build minutes; projected monthly cost at
  current growth. Output feeds the digest's cost line alongside doc 15's token
  costs — the Operator sees one "what your product costs to run" number.

### 4. Reliability
- Error rate by route (runtime logs), 4xx/5xx trends, function timeouts,
  unhandled rejections; slowest DB queries on hot paths (N+1 sweep against
  production query logs where available).
- Deployment health: build duration trend, failure rate, preview pileup (doc 12).

### 5. Discovery & correctness of the public surface
- SEO/AEO pass: metadata, structured data, sitemap/robots, llms.txt, canonical
  URLs, OG images (reuse the house seo-aeo audit skill where installed).
- Broken links, redirect chains, 404 inventory from logs.

### 6. Posture (cross-ref doc 08 layer 8)
- Headers, cookie flags, rate limits — already drift-sensed; the audit folds the
  current posture score into this report rather than re-specifying it.

## Output contract

`inspect` produces `reports/deploy-audit-<date>.md` in the target repo:

1. **Scorecard** — one grade per section above, with the number behind each grade.
2. **Top 5 optimizations, ranked by (expected impact ÷ effort)** — each with the
   metric it moves, the expected delta, and the measurement method. Not a wall of
   findings: five, ranked, defensible.
3. **Issues filed** for the top items through doc 04 (sprint contract = the
   before/after measurement), tagged `optimization`.
4. **Operator translation** (tier from doc 16): "Your site loads in 4.1s on
   phones; the top fix gets it under 2.5s and costs about a day of fleet work."

## Cadence & triggers

- **Adoption:** full inspect is Step 1.5 of doc 13 — the deployment audit rides
  alongside the repo audit, and its baseline numbers become the budgets doc 07
  enforces thereafter.
- **Monthly:** drift inspect; deltas only (what got worse since last month, what
  the fleet's own merges did to the numbers).
- **Post-launch:** within 48h of any G7 launch, because launches change traffic
  shape.
- **Reactive:** an Operator saying "it feels slow" triggers a scoped inspect
  before any optimization work is planned — measure, then move.

## Who runs it

The `monitor`/`historian` pair own the cadence; a `builder` executes optimization
issues. Tooling: Vercel API/MCP (deployments, analytics, runtime + build logs),
Lighthouse, bundle analyzer, log queries — all scripted per `scripts/README.md`
(`deploy-audit.sh`, DOC-BACKLOG P0). Vendor-neutral principle holds: the audit is
a playbook + scripts, so any runtime can run it.

---
[← 16 · No terminal required](16-nontechnical-operation.md) · [Home](../index.md) · [18 · Fork it, stay updated →](18-fork-and-upstream.md)
