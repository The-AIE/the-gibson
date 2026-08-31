#!/usr/bin/env bash
# sensor-health.test.sh — gate-discovered sensors for #256 (case 15 + node suite).
set -euo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"
PASS=0
FAIL=0
ok() { echo "  ok — $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $*"; FAIL=$((FAIL + 1)); }
WF=".github/workflows/sensor-health.yml"
[[ -f "$WF" ]] && ok "workflow present" || bad "missing $WF"
if grep -nE '^[[:space:]]*continue-on-error[[:space:]]*:' "$WF" >/dev/null 2>&1; then
  bad "$WF declares continue-on-error (forbidden for fail-closed audit)"
else
  ok "no continue-on-error in $WF"
fi
audit_run_cmd_lines() {
  # Executable run: scalar only — YAML comments must not satisfy this.
  grep -nE '^[[:space:]]*run:[[:space:]]+node[[:space:]]+scripts/sensor-health\.mjs[[:space:]]+--post([[:space:]]*(#.*)?)?$' "$1" || true
}
AUDIT_LINE=$(audit_run_cmd_lines "$WF")
[[ -n "$AUDIT_LINE" ]] && ok "executable audit run: present: $AUDIT_LINE" || bad "executable audit run: missing"
if grep -nE 'sensor-health\.mjs.*\|\|[[:space:]]*true' "$WF" >/dev/null 2>&1; then
  bad "audit step swallows failure with || true"
else
  ok "audit step not wrapped in || true"
fi
if grep -vE '^[[:space:]]*#' "$WF" | grep -nE 'set[[:space:]]+\+e' >/dev/null 2>&1; then
  bad "workflow uses set +e outside comments"
else
  ok "no set +e in workflow executable lines"
fi
grep -qi 'Advisory: this job stays green' "$WF" && bad "advisory always-green wording present" || ok "advisory always-green wording removed"
grep -qi 'Fail-closed' "$WF" && ok "fail-closed wording present" || bad "missing Fail-closed note"
grep -q '#212' "$WF" && ok "standing issue #212 referenced" || bad "workflow should mention #212"
PLANT=$(mktemp "${TMPDIR:-/tmp}/sensor-health-plant.XXXXXX")
trap 'rm -f "$PLANT" "$PLANT2"' EXIT
cat >"$PLANT" <<'YAML'
jobs:
  sensor-health:
    steps:
      - name: Audit
        continue-on-error: true
        run: node scripts/sensor-health.mjs --post || true
YAML
plant_fail=0
grep -nE '^[[:space:]]*continue-on-error[[:space:]]*:' "$PLANT" >/dev/null && plant_fail=1
grep -nE 'sensor-health\.mjs.*\|\|[[:space:]]*true' "$PLANT" >/dev/null && plant_fail=1
[[ "$plant_fail" -eq 1 ]] && ok "planted continue-on-error / || true detectable" || bad "planted anti-patterns missed"
PLANT2=$(mktemp "${TMPDIR:-/tmp}/sensor-health-plant2.XXXXXX")
cat >"$PLANT2" <<'YAML'
jobs:
  sensor-health:
    steps:
      - run: |
          set +e
          node scripts/sensor-health.mjs --post
YAML
grep -nE 'set[[:space:]]+\+e' "$PLANT2" >/dev/null && ok "planted set +e detectable" || bad "planted set +e missed"
PLANT3=$(mktemp "${TMPDIR:-/tmp}/sensor-health-plant3.XXXXXX")
trap 'rm -f "$PLANT" "$PLANT2" "$PLANT3"' EXIT
cat >"$PLANT3" <<'YAML'
jobs:
  sensor-health:
    steps:
      - name: Audit
        # run: node scripts/sensor-health.mjs --post
YAML
if [[ -n "$(audit_run_cmd_lines "$PLANT3")" ]]; then
  bad "comment-only audit command falsely accepted"
else
  ok "comment-only audit command rejected"
fi
if ! command -v node >/dev/null 2>&1; then
  bad "node not installed"
elif node --test "$REPO_ROOT/scripts/sensor-health.test.mjs"; then
  ok "node --test scripts/sensor-health.test.mjs"
else
  bad "node --test scripts/sensor-health.test.mjs"
fi
for mjs in scripts/sensor-health.mjs scripts/sensor-health-lib.mjs; do
  set +e
  err=$(node "$REPO_ROOT/$mjs" --definitely-not-a-flag 2>&1 >/dev/null)
  rc=$?
  set -e
  if [[ "$rc" -eq 2 ]] && grep -qE 'unknown (flag|option):' <<<"$err"; then
    ok "$mjs rejects unknown flag (rc=2)"
  else
    bad "$mjs unknown-flag contract (rc=$rc err=$err)"
  fi
done
[[ -f config/sensor-health-observation.v1.json ]] && ok "registry present" || bad "missing registry"
if [[ "$FAIL" -eq 0 ]]; then
  echo "sensor-health.test.sh: $PASS passed, 0 failed"
  exit 0
fi
echo "sensor-health.test.sh: $PASS passed, $FAIL failed"
exit 1
