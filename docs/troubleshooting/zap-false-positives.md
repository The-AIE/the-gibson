# ZAP false positives

## Symptoms

- Baseline fails on informational/low noise
- Flagged "absence of anti-CSRF tokens" on pure JSON GET APIs
- Staging full scan noisy vs. preview baseline

## Why

DAST is high value and high noise. Hard-fail is on **high+** for baseline
([docs/08](../08-security.md)); tuning is expected at adoption.

## Checklist

| Check | Action |
|---|---|
| Severity | Confirm rule is High/Critical before blocking |
| Auth context | Unauthenticated scan of auth-only app → expected 401 noise |
| API vs HTML | Disable HTML-only rules for pure JSON APIs via ZAP config |
| Preview secrets | Preview is semi-public — don't put prod credentials there |
| True positive? | Construct exploit path before dismissing |

## Recovery

1. Reproduce with ZAP desktop or `zap-baseline.py` locally against the same preview.
2. If false positive: add rule to allowlist **with comment + lesson** (why safe).
3. If true positive: file issue with severity + exploit path; do not merge.

## Do not

- Global `fail_action: false` to silence the layer (softening hard-fail is forbidden)
- Active-scan production
