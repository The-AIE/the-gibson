---
title: "Example · UX Eval"
nav_exclude: true
---

# Worked example — Playwright flow + UX eval report (docs/07)

Continues the Northstar Clinic password-reset story (issue #103 / #104).
**Rule zero:** evaluate the deployment, not the diff.

---

## Flow spec — `tests/e2e/flows/issue-103-reset-happy.spec.ts`

```typescript
import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

const base = process.env.BASE_URL;
if (!base) throw new Error("BASE_URL required (preview URL)");

test.describe("issue-103 password reset happy path", () => {
  test("request → confirm → login with new password", async ({ page }) => {
    // 1. Request form
    await page.goto(`${base}/reset`);
    await page.screenshot({ path: "reports/ux-eval/103/01-request.png", fullPage: true });
    await page.getByLabel(/email/i).fill("patient@example.test");
    await page.getByRole("button", { name: /send reset/i }).click();
    await expect(page.getByText(/if an account exists/i)).toBeVisible();
    await page.screenshot({ path: "reports/ux-eval/103/02-request-sent.png", fullPage: true });

    // 2. Token from test mail stub (preview injects TEST_RESET_TOKEN)
    const token = process.env.TEST_RESET_TOKEN ?? "test-token-preview-only";
    await page.goto(`${base}/reset/confirm?token=${token}`);
    await page.screenshot({ path: "reports/ux-eval/103/03-confirm.png", fullPage: true });
    await page.getByLabel(/^new password$/i).fill("Correct-Horse-Battery-9");
    await page.getByLabel(/confirm password/i).fill("Correct-Horse-Battery-9");
    await page.getByRole("button", { name: /update password/i }).click();
    await expect(page.getByText(/password updated/i)).toBeVisible();
    await page.screenshot({ path: "reports/ux-eval/103/04-success.png", fullPage: true });

    // 3. Login with new password
    await page.goto(`${base}/login`);
    await page.getByLabel(/email/i).fill("patient@example.test");
    await page.getByLabel(/password/i).fill("Correct-Horse-Battery-9");
    await page.getByRole("button", { name: /log in/i }).click();
    await expect(page).toHaveURL(/dashboard|appointments/i);
    await page.screenshot({ path: "reports/ux-eval/103/05-logged-in.png", fullPage: true });
  });

  test("mobile 375px no horizontal scroll on request", async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await page.goto(`${base}/reset`);
    const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
    const clientWidth = await page.evaluate(() => document.documentElement.clientWidth);
    expect(scrollWidth).toBeLessThanOrEqual(clientWidth + 1);
    const btn = page.getByRole("button", { name: /send reset/i });
    const box = await btn.boundingBox();
    expect(box?.height ?? 0).toBeGreaterThanOrEqual(44);
  });

  test("axe critical/serious = 0 on /reset", async ({ page }) => {
    await page.goto(`${base}/reset`);
    const results = await new AxeBuilder({ page }).analyze();
    const serious = results.violations.filter((v) =>
      ["critical", "serious"].includes(v.impact || "")
    );
    expect(serious, JSON.stringify(serious, null, 2)).toEqual([]);
  });
});
```

**Run:**

```bash
export BASE_URL="$(./scripts/preview-url.sh 88)"
export TEST_RESET_TOKEN="…"   # from preview test harness
npx playwright test tests/e2e/flows/issue-103-reset-happy.spec.ts
```

---

## Eval report (posted on PR #88)

```markdown
## UX eval — PR #88

**Preview:** https://clinic-web-git-feat-103-reset-northstar.vercel.app
**Driven:** yes — every contract flow executed (not assumed)
**Evaluator:** grok (not the builder)

| Criterion | Score | Notes |
|---|---|---|
| Design quality | 8/10 | Matches auth pages; clinic blue + calm spacing held |
| Originality | 7/10 | Standard pattern executed cleanly; not generic purple-gradient AI slop |
| Craft | 8/10 | 8px grid, 44px targets, focus rings present; success state clear |
| Functionality | 9/10 | Full path green; one copy nit below |

| Check | Result |
|---|---|
| Contract flows | pass (happy path + mobile + axe) |
| axe critical/serious | 0 |
| Visual regression | pass (baselines updated intentionally for new routes) |
| Lighthouse (median of 3) | P=0.91 A=1.00 SEO=0.98 LCP=1.8s CLS=0.02 |

### Bugs filed
- none blocking

### Nits (non-blocking)
- Success banner could link to "Log in" explicitly for SR users — filed #109

**VERDICT:** PASS

Every contract flow for #103/#104 was driven on the preview URL with screenshots
under reports/ux-eval/103/.
```

---

## Iteration note

If Craft had scored 6: REQUEST_CHANGES with specific spacing/contrast findings;
builder pushes; evaluator re-runs failed flows + smoke of passed ones only.
