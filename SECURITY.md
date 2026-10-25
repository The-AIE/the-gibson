# Security Policy

The Gibson is a governance harness: its scripts, CI workflows and hooks decide what an agent fleet is allowed to merge. A flaw that lets a gate pass when it should not is a security issue here, even when no data is exposed.

## Supported versions

The Gibson is pre-1.0. Fixes go to `main` and to the latest tagged release. Older tags are not patched.

## What is in scope

- A gate, sensor or check that can be bypassed or that passes without doing its job (a fail-open path).
- A script, hook or workflow that executes untrusted input (a branch name, PR title or body, issue text, a file name) or that exposes a token or secret to code it should not.
- A template installed into a target repository (`ci/`, `templates/`) that is unsafe by default.
- Text in an issue, PR or comment that can steer an agent running this harness into an action its operator did not intend (prompt injection through the harness's own inputs).

## What is out of scope

- Vulnerabilities in a third-party tool the harness calls. Please report those upstream.
- Findings in a project that only adopts the Gibson.
- Social engineering of maintainers, and denial of service by volume alone.

## How to report

**Do not open a public issue or pull request for a vulnerability.**

Email **mrhinkle@peripety.com** with the subject `Gibson security`, and include:

- what is affected (file, script or workflow, and the commit or tag);
- steps to reproduce, or a proof of concept;
- the impact as you understand it;
- a suggested fix, if you have one.

## What to expect

- We aim to acknowledge a report within 5 business days.
- We aim to confirm or decline it, and tell you what we plan to do, within 14 days.
- We will agree a disclosure date with you. Our default is to fix or mitigate first and publish within 90 days of the report.
- With your permission, we will credit you in the release notes and the advisory.

If you have not heard back in 5 business days, please send the report again; mail does get lost.
