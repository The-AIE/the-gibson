# Worked example — AuthZ matrix for a 3-role app (docs/08 layer 4)

Fictional app: **Northstar Clinic** — roles `anon`, `patient`, `staff`.

Generated scaffold from `route-inventory.mjs`, then filled with expected statuses
and IDOR probes. New route with `null` expect = CI failure once hard-fail is on.

---

## `tests/authz/route-matrix.json` (excerpt)

```json
{
  "framework": "next-app-router",
  "roles": ["anon", "patient", "staff"],
  "routes": [
    {
      "path": "/login",
      "kind": "page",
      "methods": ["GET"],
      "expect": { "anon": 200, "patient": 200, "staff": 200 }
    },
    {
      "path": "/dashboard",
      "kind": "page",
      "methods": ["GET"],
      "expect": { "anon": 302, "patient": 200, "staff": 200 }
    },
    {
      "path": "/staff/patients",
      "kind": "page",
      "methods": ["GET"],
      "expect": { "anon": 302, "patient": 403, "staff": 200 }
    },
    {
      "path": "/api/auth/reset/request",
      "kind": "handler",
      "methods": ["POST"],
      "expect": { "anon": 200, "patient": 200, "staff": 200 }
    },
    {
      "path": "/api/patients/:id",
      "kind": "handler",
      "methods": ["GET", "PATCH"],
      "expect": { "anon": 401, "patient": 200, "staff": 200 },
      "idor_probes": [
        {
          "as": "patient",
          "resourceOwnedBy": "other-patient",
          "method": "GET",
          "expect": 403
        },
        {
          "as": "patient",
          "resourceOwnedBy": "other-patient",
          "method": "PATCH",
          "expect": 403
        }
      ]
    },
    {
      "path": "/api/staff/notes",
      "kind": "handler",
      "methods": ["GET", "POST"],
      "expect": { "anon": 401, "patient": 403, "staff": 200 },
      "idor_probes": []
    }
  ]
}
```

---

## Test sketch — `tests/authz/matrix.test.ts`

```typescript
import { describe, test, expect } from "vitest";
import matrix from "./route-matrix.json";

const base = process.env.AUTHZ_BASE_URL || "http://127.0.0.1:3000";

// sessionCookies[role] obtained from test fixtures
declare const sessionCookies: Record<string, string>;

for (const route of matrix.routes) {
  for (const role of matrix.roles) {
    const expected = route.expect[role];
    test(`${role} ${route.methods[0]} ${route.path} → ${expected}`, async () => {
      const path = route.path.replace(":id", "user-self-fixture-id");
      const res = await fetch(`${base}${path}`, {
        method: route.methods[0],
        headers: sessionCookies[role]
          ? { cookie: sessionCookies[role] }
          : {},
        redirect: "manual",
      });
      expect(res.status).toBe(expected);
    });
  }
  for (const probe of route.idor_probes || []) {
    test(`IDOR ${probe.as} ${probe.method} ${route.path} owned by ${probe.resourceOwnedBy}`, async () => {
      const path = route.path.replace(":id", "other-patient-fixture-id");
      const res = await fetch(`${base}${path}`, {
        method: probe.method,
        headers: { cookie: sessionCookies[probe.as] },
        redirect: "manual",
      });
      expect(res.status).toBe(probe.expect);
    });
  }
}
```

---

## How to regenerate the scaffold

```bash
node scripts/route-inventory.mjs \
  --root ~/Code/clinic-web \
  --roles anon,patient,staff \
  --out tests/authz/route-matrix.json
# Fill expect + idor_probes; commit; CI fails on new routes with null expect
```
