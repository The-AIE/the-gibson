# Sensor health

`scripts/sensor-health.mjs` reports the state of each watched workflow (OK, IDLE, FAILING, BLIND, UNKNOWN) and fails when any row is not OK.

## Sub-features

- `health-suite` proves the classifier and report offline.
- `health-live` reads the latest scheduled run on `main`.

## How to get to it (user POV)

- The daily `Sensor health` workflow; locally, run the unit suite.

## Driving it with capture.sh

Preconditions: doctor is ok; `gh` is authenticated.

- **Suite.** `capture.sh health suite -- node --test scripts/sensor-health.test.mjs`. Exit `0`; `.out` contains `fail 0`.
- **Live state (read-only).** `capture.sh health live -- gh run list -R The-AIE/the-gibson --workflow "Sensor health" -L 1 --json conclusion,createdAt,headSha`. Exit `0`; `.out` shows the latest run and its conclusion.

## Gotchas

- Every row must be OK for exit 0: a single IDLE row (for example a watched workflow that never runs) turns the run red. See the-gibson#471.
- A live `failure` is not a regression until you have read which row failed in the run log.
