#!/usr/bin/env bash
# key-age-check.test.sh — offline sensors for scripts/key-age-check.sh (issue #221)
#
# WHY
#   The age sensor is advisory: a STALE key must still exit 0, and a usage
#   error is the only nonzero path. A bug that turns STALE into exit 1 would
#   make an unapproved cadence into a merge gate. A bug that prints file
#   contents would leak a private key into CI logs.
#
# USAGE
#   scripts/tests/key-age-check.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SENSOR="$SCRIPT_DIR/../key-age-check.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v bash >/dev/null || { echo "key-age-check.test.sh: bash is required"; exit 1; }
[[ -x "$SENSOR" ]] || { echo "key-age-check.test.sh: $SENSOR missing or not executable"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-key-age.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

MARKER="BEGIN-FAKE-PRIVATE-KEY-MATERIAL-DO-NOT-PRINT"
write_key() {
  printf '%s\n%s\n' "$MARKER" "not-a-real-key" > "$1"
}

echo "key-age-check.sh --help is Ask-Contract shaped"
help_out=$("$SENSOR" --help 2>"$ROOT/help.err")
help_rc=$?
if [[ "$help_rc" -eq 0 ]]; then ok "--help exits 0"
else bad "--help exited $help_rc"; fi
if echo "$help_out" | grep -q 'WHAT IT DOES' && echo "$help_out" | grep -q 'RISKS'; then
  ok "--help names WHAT IT DOES and RISKS"
else
  bad "--help missing Ask-Contract fields"
fi
if echo "$help_out" | grep -q 'OWNER DECISION' && echo "$help_out" | grep -q '180d'; then
  ok "--help names the owner-gated 180d cadence"
else
  bad "--help missing owner-gated cadence note"
fi
if echo "$help_out" | grep -q 'advisory'; then
  ok "--help says the sensor is advisory"
else
  bad "--help does not say advisory"
fi
if [[ ! -s "$ROOT/help.err" ]]; then ok "--help is quiet on stderr"
else bad "--help wrote stderr"; fi

echo "unknown flag exits 2 with unknown flag:"
if "$SENSOR" --definitely-not-a-flag >/dev/null 2>"$ROOT/unk.err"; then
  bad "unknown flag must not succeed"
else
  unk_rc=$?
  if [[ "$unk_rc" -eq 2 ]]; then ok "unknown flag exits 2"
  else bad "unknown flag exited $unk_rc (want 2)"; fi
fi
if grep -q 'unknown flag:' "$ROOT/unk.err"; then
  ok "stderr contains 'unknown flag:'"
else
  bad "stderr missing 'unknown flag:': $(cat "$ROOT/unk.err")"
fi

echo "usage errors exit 2"
if "$SENSOR" "$ROOT/no-threshold.pem" >/dev/null 2>"$ROOT/nth.err"; then
  bad "missing --threshold must not succeed"
else
  nth_rc=$?
  if [[ "$nth_rc" -eq 2 ]]; then ok "missing --threshold exits 2"
  else bad "missing --threshold exited $nth_rc (want 2)"; fi
fi
if grep -q -- '--threshold' "$ROOT/nth.err"; then
  ok "missing --threshold names the flag"
else
  bad "missing --threshold message unclear: $(cat "$ROOT/nth.err")"
fi
if "$SENSOR" --threshold >/dev/null 2>"$ROOT/thv.err"; then
  bad "--threshold without a value must not succeed"
else
  thv_rc=$?
  if [[ "$thv_rc" -eq 2 ]]; then ok "--threshold without a value exits 2"
  else bad "--threshold without a value exited $thv_rc (want 2)"; fi
fi
if "$SENSOR" --threshold 180d "$ROOT/x.pem" >/dev/null 2>"$ROOT/thd.err"; then
  bad "--threshold 180d must not succeed"
else
  thd_rc=$?
  if [[ "$thd_rc" -eq 2 ]]; then ok "non-integer --threshold exits 2"
  else bad "non-integer --threshold exited $thd_rc (want 2)"; fi
fi
if "$SENSOR" --threshold -1 "$ROOT/x.pem" >/dev/null 2>"$ROOT/thn.err"; then
  bad "negative --threshold must not succeed"
else
  thn_rc=$?
  if [[ "$thn_rc" -eq 2 ]]; then ok "negative --threshold exits 2"
  else bad "negative --threshold exited $thn_rc (want 2)"; fi
fi

echo "fresh key is OK and exit 0"
fresh="$ROOT/fresh.pem"
write_key "$fresh"
# now == mtime window: file created just now, threshold 180 → OK
out=$("$SENSOR" --threshold 180 "$fresh" 2>"$ROOT/fresh.err")
fresh_rc=$?
if [[ "$fresh_rc" -eq 0 ]]; then ok "fresh key exits 0"
else bad "fresh key exited $fresh_rc"; fi
if echo "$out" | grep -q ' PATH' || echo "$out" | grep -q '^PATH'; then
  ok "table has a PATH header"
else
  bad "table missing PATH header: $out"
fi
if echo "$out" | grep -q " $fresh" || echo "$out" | grep -F "$fresh" | grep -q 'OK'; then
  ok "fresh key row is OK"
else
  # row is "path ... OK"
  if echo "$out" | grep -F "$fresh" | grep -q 'OK'; then
    ok "fresh key row is OK"
  else
    bad "fresh key row not OK: $out"
  fi
fi
if echo "$out" | grep -F "$fresh" | grep -q 'OK'; then
  :
fi
if [[ ! -s "$ROOT/fresh.err" ]]; then ok "fresh run is quiet on stderr"
else bad "fresh run wrote stderr: $(cat "$ROOT/fresh.err")"; fi

echo "STALE key still exits 0"
old="$ROOT/old.pem"
write_key "$old"
# Inject now = 200 days after unix 0; set mtime to unix 0 via --now vs a
# just-created file by making now far in the future.
# File mtime ≈ wall clock. --now = mtime + 200 days.
now_base=$(date -u +%s)
now_stale=$(( now_base + 200 * 86400 ))
out=$("$SENSOR" --threshold 180 --now "$now_stale" "$old" 2>"$ROOT/stale.err")
stale_rc=$?
if [[ "$stale_rc" -eq 0 ]]; then ok "STALE key exits 0 (advisory)"
else bad "STALE key exited $stale_rc (advisory must stay 0)"; fi
if echo "$out" | grep -F "$old" | grep -q 'STALE'; then
  ok "old key row is STALE"
else
  bad "old key row not STALE: $out"
fi

echo "MISSING path is advisory"
out=$("$SENSOR" --threshold 180 "$ROOT/does-not-exist.pem" 2>"$ROOT/miss.err")
miss_rc=$?
if [[ "$miss_rc" -eq 0 ]]; then ok "MISSING path exits 0"
else bad "MISSING path exited $miss_rc"; fi
if echo "$out" | grep -q 'MISSING'; then
  ok "missing path row is MISSING"
else
  bad "missing path row not MISSING: $out"
fi

echo "symlink and directory are not followed as keys"
target="$ROOT/target.pem"
write_key "$target"
ln -s "$target" "$ROOT/link.pem"
mkdir -p "$ROOT/dir"
out=$("$SENSOR" --threshold 180 "$ROOT/link.pem" "$ROOT/dir" 2>"$ROOT/spec.err")
spec_rc=$?
if [[ "$spec_rc" -eq 0 ]]; then ok "symlink/dir run exits 0"
else bad "symlink/dir run exited $spec_rc"; fi
if echo "$out" | grep -F "$ROOT/link.pem" | grep -q 'SYMLINK'; then
  ok "symlink row is SYMLINK"
else
  bad "symlink row not SYMLINK: $out"
fi
if echo "$out" | grep -F "$ROOT/dir" | grep -q 'NOT-A-FILE'; then
  ok "directory row is NOT-A-FILE"
else
  bad "directory row not NOT-A-FILE: $out"
fi

echo "never prints key material"
# Reuse the STALE/OK outputs plus a dedicated run
out=$("$SENSOR" --threshold 180 "$fresh" "$old" 2>/dev/null)
if echo "$out" | grep -qF "$MARKER"; then
  bad "stdout contained dummy key material"
else
  ok "stdout does not contain key material"
fi
if echo "$out" | grep -qiE 'BEGIN (RSA |OPENSSH )?PRIVATE KEY'; then
  bad "stdout looked like a PEM block"
else
  ok "stdout has no PEM header"
fi

echo "bash 3.2-forbidden constructs stay out of the sensor"
if grep -E '^[^#]*(\bmapfile\b|\breadarray\b|declare -A|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|\$\{[A-Za-z_][A-Za-z0-9_]*\,\,|&>>)' "$SENSOR"; then
  bad "sensor uses a Bash-4-only construct"
else
  ok "sensor has no Bash-4-only constructs"
fi

echo "GNU-first stat (L-050 / #99)"
if grep -q 'stat -c %Y' "$SENSOR" && grep -q 'stat -f %m' "$SENSOR"; then
  # -c must appear before -f on the production mtime line
  line=$(grep -E 'stat -c %Y' "$SENSOR" | head -1)
  if echo "$line" | grep -q 'stat -f %m'; then
    ok "mtime line is GNU-first (stat -c then stat -f)"
  else
    bad "GNU and BSD stat are not on the same fallback line: $line"
  fi
else
  bad "sensor is missing the GNU-first stat fallback"
fi

echo
echo "key-age-check.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
