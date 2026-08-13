#!/usr/bin/env bash
# args.test.sh — flag-value contract for args.mjs and the inlined copies (#192)
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TI="$SCRIPT_DIR/../test-integrity.mjs"
ARGS_MJS="$SCRIPT_DIR/../lib/args.mjs"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "args.test.sh: node required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-args.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

write_metrics() {
  cat > "$1" <<EOF
{"total": $2, "skipped": $3, "todo": $4}
EOF
}

write_metrics "$ROOT/base.json" 10 0 0
write_metrics "$ROOT/head.json" 10 0 0

echo "# --waiver-text '--starts with dashes' is a value, not a flag"
stdout=$(node "$TI" compare --base "$ROOT/base.json" --head "$ROOT/head.json" \
  --waiver-text '--starts with dashes' 2>"$ROOT/err1"); rc=$?
stderr=$(cat "$ROOT/err1")
if [[ "$rc" -eq 0 ]]; then
  ok "inlined readFlag accepts --waiver-text '--starts with dashes' (value kept)"
else
  bad "waiver-text dash-leading value (rc=$rc stdout=$stdout stderr=$stderr)"
fi

echo "# --reason '--because' is a value, not a flag"
stdout=$(node "$TI" journal-append --journal "$ROOT/j.jsonl" \
  --old "$ROOT/base.json" --new "$ROOT/head.json" \
  --reason '--because' 2>"$ROOT/err2"); rc=$?
stderr=$(cat "$ROOT/err2")
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$stdout" | grep -q '"reason":"--because"'; then
  ok "inlined readFlag accepts --reason '--because' (value kept)"
else
  bad "reason dash-leading value (rc=$rc stdout=$stdout stderr=$stderr)"
fi

echo "# --waiver-text with no following token is a usage error (exit 2)"
stdout=$(node "$TI" compare --base "$ROOT/base.json" --head "$ROOT/head.json" \
  --waiver-text 2>"$ROOT/err3"); rc=$?
stderr=$(cat "$ROOT/err3")
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$stderr" | grep -q 'requires a value'; then
  ok "--waiver-text with nothing after exits 2 on stderr"
else
  bad "missing waiver-text value (rc=$rc stdout=$stdout stderr=$stderr)"
fi

echo "# --definitely-not-a-flag is unknown (exit 2, stderr)"
stdout=$(node "$TI" --definitely-not-a-flag 2>"$ROOT/err4"); rc=$?
stderr=$(cat "$ROOT/err4")
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$stderr" | grep -q 'unknown flag: --definitely-not-a-flag'; then
  ok "--definitely-not-a-flag exits 2 with unknown flag on stderr"
else
  bad "unknown flag (rc=$rc stdout=$stdout stderr=$stderr)"
fi

CAW="$SCRIPT_DIR/../check-active-work.mjs"
echo "# check-active-work.mjs --definitely-not-a-flag is unknown (exit 2, stderr)"
stdout=$(node "$CAW" --definitely-not-a-flag 2>"$ROOT/err-caw1"); rc=$?
stderr=$(cat "$ROOT/err-caw1")
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$stderr" | grep -q 'unknown flag: --definitely-not-a-flag'; then
  ok "check-active-work.mjs --definitely-not-a-flag exits 2 with unknown flag on stderr"
else
  bad "check-active-work unknown flag (rc=$rc stdout=$stdout stderr=$stderr)"
fi

echo "# check-active-work.mjs --help works"
stdout=$(node "$CAW" --help 2>"$ROOT/err-caw2"); rc=$?
stderr=$(cat "$ROOT/err-caw2")
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$stdout" | grep -q 'check-active-work'; then
  ok "check-active-work.mjs --help exits 0"
else
  bad "check-active-work --help (rc=$rc stdout=$stdout stderr=$stderr)"
fi

echo "# args.mjs parseFlags / readFlag consume the next token verbatim"
mkdir -p "$ROOT/lib"
cp "$ARGS_MJS" "$ROOT/lib/args.mjs"
cat > "$ROOT/accept.mjs" <<'JS'
import { readFlag, parseFlags } from "./lib/args.mjs";
const waiver = readFlag(["--waiver-text", "--starts with dashes"], "--waiver-text");
if (waiver !== "--starts with dashes") process.exit(1);
const parsed = parseFlags(["--reason", "--because"], {
  flags: { "--reason": { key: "reason", type: "string" } },
});
if (parsed.reason !== "--because") process.exit(1);
console.log("ok");
JS
stdout=$(node "$ROOT/accept.mjs" 2>"$ROOT/err6"); rc=$?
if [[ "$rc" -eq 0 && "$stdout" == "ok" ]]; then
  ok "args.mjs readFlag/parseFlags accept dash-leading values"
else
  bad "args.mjs accept (rc=$rc stdout=$stdout stderr=$(cat "$ROOT/err6"))"
fi

cat > "$ROOT/missing.mjs" <<'JS'
import { readFlag } from "./lib/args.mjs";
readFlag(["--waiver-text"], "--waiver-text");
console.log("should-have-exited");
JS
stdout=$(node "$ROOT/missing.mjs" 2>"$ROOT/err7"); rc=$?
stderr=$(cat "$ROOT/err7")
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$stderr" | grep -q 'requires a value'; then
  ok "args.mjs readFlag missing value exits 2 on stderr"
else
  bad "args.mjs missing value (rc=$rc stdout=$stdout stderr=$stderr)"
fi

cat > "$ROOT/unknown.mjs" <<'JS'
import { rejectUnknownFlags } from "./lib/args.mjs";
rejectUnknownFlags(["--definitely-not-a-flag"], ["--help"]);
console.log("should-have-exited");
JS
stdout=$(node "$ROOT/unknown.mjs" 2>"$ROOT/err8"); rc=$?
stderr=$(cat "$ROOT/err8")
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$stderr" | grep -q 'unknown flag: --definitely-not-a-flag'; then
  ok "args.mjs rejectUnknownFlags unknown flag exits 2 on stderr"
else
  bad "args.mjs unknown flag (rc=$rc stdout=$stdout stderr=$stderr)"
fi

echo
echo "args.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
