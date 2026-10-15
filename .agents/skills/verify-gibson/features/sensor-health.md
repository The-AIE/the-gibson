# Sensor health

`scripts/sensor-health.mjs` reports the state of each watched workflow (OK, IDLE, FAILING, UNKNOWN; `BLIND` exists in the code but production policies never emit it) and fails when any row is not OK. An active workflow with no row in `config/sensor-health-observation.v1.json` is `UNKNOWN unconfigured-workflow` and fails the run.

## Sub-features

- `health-suite` proves the classifier and report offline.
- `health-live` reads the latest scheduled run on `main`.

## How to get to it (user POV)

- The daily `Sensor health` workflow; locally, run the unit suite.

## Driving it with capture.sh

Preconditions: doctor is ok; `gh` is authenticated.

- **Suite.** `capture.sh sensor-health suite -- node --test scripts/sensor-health.test.mjs`. Exit `0`; `.out` contains `fail 0`.
- **Live state (read-only).** `capture.sh sensor-health live -- gh run list -R The-AIE/the-gibson --workflow "Sensor health" --branch main --event schedule -L 1 --json conclusion,createdAt,headSha`. Exit `0`; `.out` shows the latest scheduled run on `main` and its conclusion. Without `--branch` and `--event` it returns the newest run of any trigger.

## Gotchas

- Every row must be OK for exit 0: a single IDLE row (for example a watched workflow that never runs) turns the run red. See the-gibson#471.
- A live `failure` is not a FAILING row. The job also runs `self-gate-health` and a backlog-health publish, and either can fail the run. Read the non-OK rows in standing issue #212 (`gh issue view 212 -R The-AIE/the-gibson --json body -q .body`) before calling it a regression.
