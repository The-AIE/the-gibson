# Owner journey prototype (issue #348)

A dependency-free, local, clickable prototype of the intended Gibson product
journey for a nontechnical owner:

```
Connect project -> Read-only check -> Ask -> Blueprint -> Work -> Preview -> Decision -> Result
```

## What this is

Executable product-design evidence for #176. Every screen, every check, and
every "result" in this prototype is a fixed simulation. Nothing here reads a
real repository, runs an agent, changes permissions, spends money, merges
anything, or deploys anything. The boundary is stated on every screen.

This is not the #175 stack recommender, the #166 capability manifest, the
#164 policy authority, or the #160 delivery receipt, and it does not define
a competing version of any of those contracts.

## How to run it

Open `index.html` directly in a browser (double-click it, or drag it into a
browser window). No server, no package install, no build step, no network
request, no secret, and no environment variable is required or used.

## What it saves

At most one thing, in `localStorage`, under the key
`gibson.owner-journey-prototype.local.v1`:

```json
{ "schema": "gibson.owner-journey-prototype.local.v1", "projectId": "demo-storefront" }
```

That's it — a fixed schema string and the id of the example project you
picked. No workflow progress, no typed request text, no feedback, and no
decision is ever saved. If the saved value is missing, malformed, the wrong
shape, oversized, or names an id this prototype doesn't recognize, the demo
safely ignores it, starts over at Connect, and says so on screen. The
**Reset demo** button (top of every screen) removes exactly that one key and
nothing else.

## How the code is organized

- `index.html` — every screen, written out as plain, static markup. Nothing
  is built with `innerHTML`; the script only toggles which section is
  visible and fills in a handful of specific text nodes.
- `styles.css` — visual styling only. No `@import`, no remote or
  protocol-relative `url(...)`.
- `app.js` — split into two halves:
  1. A pure state model (constants, validators, the `transition()` reducer,
     `hydrate()`/`hydrateUnavailable()`). It touches no `window`,
     `document`, or storage, and is exported through `module.exports` when
     loaded by Node's `require()` — a no-op in a browser, where `module` is
     undefined. `scripts/tests/owner-journey.test.sh` requires this exact
     file, so the gate tests the same logic the browser runs, not a
     reimplementation of it.
  2. DOM wiring, guarded by `typeof document !== "undefined"`, that reads
     button clicks and text input, calls the pure reducer, and re-renders.

## The rules this prototype holds itself to

- Only the transitions in the parent issue's table are legal. Every other
  action, from every screen, leaves the state unchanged.
- User-typed text (the request and feedback) is rendered with
  `textContent`, never `innerHTML`, and never becomes an action, a URL, a
  permission, a state name, or an authoritative-sounding status.
- No network or external-navigation code path exists anywhere in this
  directory: no outbound request API, no worker, no dynamic import, no new
  window/tab, and no page-navigation assignment. No form, iframe, embedded
  object, media element, external link, or remote/protocol-relative
  resource reference exists in the markup or the stylesheet.
- The Result screen says exactly one thing about completion: "Demo
  complete. No code was changed or deployed." No screen anywhere in this
  prototype makes an unqualified real-world completion, confirmation, or
  production-status claim.

## Testing

`scripts/tests/owner-journey.test.sh` exercises the pure state model
directly through Node's `require()`, and scans the static files for the
forbidden patterns above, the required headings, and the exact wording this
README describes. It is picked up automatically by
`scripts/tests/run-all.sh`.
