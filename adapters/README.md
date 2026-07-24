# adapters/ — vendor runtimes

One directory per runtime: `claude-code/`, `codex/`, `grok/`, `hermes/`.
Contract and matrix: docs/10. Each adapter provides doctrine loading, role
dispatch, telemetry (deterministic where the runtime allows), and cost capture —
and carries **zero rules of its own**.

Setup READMEs per adapter: DOC-BACKLOG P1.9. Until then, Mission Control's
`agents/<vendor>/` docs are the working reference.
