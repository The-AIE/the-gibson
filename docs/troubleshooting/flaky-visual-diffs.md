# Flaky visual diffs

## Symptoms

- Playwright `toHaveScreenshot` fails intermittently
- Diff shows 1–2px font/antialias noise
- Passes locally, fails in CI (or reverse)

## Why

Visual regression is a sensor; flake trains people to ignore it. Quarantine within
24h ([docs/06](../06-quality-gates.md) / docs/02 flaky rule).

## Checklist

| Check | Action |
|---|---|
| Animations | `await page.emulateMedia({ reducedMotion: 'reduce' })` / disable CSS animations in test |
| Fonts | Wait for `document.fonts.ready`; embed fonts in CI |
| Timestamps / random | Mock clock; mask dynamic regions with `mask` option |
| DPI / OS | Generate baselines **in CI** (same container) as source of truth |
| Threshold | Small `maxDiffPixelRatio` only with documented rationale |
| Intended redesign | Update baseline in the **same** PR with explicit note |

## Recovery

```typescript
await expect(page).toHaveScreenshot("dashboard.png", {
  animations: "disabled",
  mask: [page.locator("[data-testid=clock]")],
  maxDiffPixelRatio: 0.01, // only if justified
});
```

If still flaky: quarantine test, file harness-improvement issue, keep axe + flow
assertions as the hard gate until visual is stable.
