# Gibson owner journey prototype

This dependency-free prototype demonstrates the intended Gibson experience for
a nontechnical owner:

`Connect project -> Read-only check -> Ask -> Blueprint -> Work -> Preview -> Decision -> Result`

It is product-design evidence for issue #348. It does not connect to GitHub,
inspect a repository, run an agent, write code, grant permission, approve a
release, or deploy anything.

## Try it

Open `index.html` in a modern browser. No server, install, build, environment
variable, secret, or network connection is required.

The prototype stores only the selected example-project identifier in
`localStorage`. Request text, preview feedback, progress, and decisions remain
in memory and disappear when the page closes or reloads. **Reset prototype**
removes only the prototype's namespaced key.

## Verify it

From the repository root:

```bash
bash scripts/tests/owner-journey.test.sh
```

The focused suite exercises every legal and illegal state transition,
persistence boundaries, UTF-8 input limits, injection-resistant rendering
rules, forbidden network and navigation surfaces, required copy, and mutation
witnesses for the most important trust failures.

## Product boundary

The screens use example repositories and simulated checks to make the journey
tangible. They do not define Gibson's future public integration schemas or
replace the capability, policy, stack-selection, or delivery-receipt contracts
tracked elsewhere in the roadmap.
