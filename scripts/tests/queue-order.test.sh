#!/usr/bin/env bash
# queue-order.test.sh — offline sensors for scripts/queue-order.mjs (#424).
# Network-free. Bash 3.2 compatible. A fake gh is the only gh on PATH.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
TOOL="$REPO_ROOT/scripts/queue-order.mjs"
FIX="$SCRIPT_DIR/fixtures/queue-order"
REPO="The-AIE/the-gibson"
PASS=0
FAIL=0

ok() { printf '  ok   — %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL — %s\n' "$1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gibson-queue-order.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
ERR_FILE="$TMP/err"
BIN="$TMP/bin"
mkdir -p "$BIN"
NODE_REAL=$(command -v node)
cat > "$BIN/node" << EOF
#!/bin/bash
exec "$NODE_REAL" "\$@"
EOF
chmod +x "$BIN/node"

cat > "$BIN/gh" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
if [[ "$1" != "issue" || "$2" != "view" || "$4" != "--repo" || "$6" != "--json" || "$7" != "state" || $# -ne 7 ]]; then
  printf 'bad-argv\n' >> "${GH_LOG:?}"
  exit 97
fi
printf '%s\n' 'TOKEN-LEAK' >&2
mode="${GH_MODE:-forbid}"
num="$3"
case "$mode" in
  forbid) exit 99 ;;
  fail) exit 1 ;;
  malformed) printf 'not-json\n'; exit 0 ;;
  unknown) printf '%s\n' '{"state":"MERGED"}'; exit 0 ;;
  open) printf '%s\n' '{"state":"OPEN"}'; exit 0 ;;
  mixed)
    case "$num" in
      424) printf '%s\n' '{"state":"CLOSED"}' ;;
      307) printf '%s\n' '{"state":"OPEN"}' ;;
      70) printf '%s\n' '{"state":"closed"}' ;;
      *) printf '%s\n' '{"state":"OPEN"}' ;;
    esac
    ;;
  *) exit 98 ;;
esac
EOF
chmod +x "$BIN/gh"

export PATH="$BIN:/usr/bin:/bin"
export GH_LOG="$TMP/gh.log"
export GH_MODE="forbid"
: > "$GH_LOG"

cat > "$TMP/mutate.mjs" << 'EOF'
import { readFileSync, writeFileSync } from "node:fs";

const control = readFileSync(process.argv[2], "utf8").replace(/\n$/, "");
const kind = process.argv[3];
const dest = process.argv[4];
const placement = process.argv[5] || "only";

function emit(line) {
  const text = placement === "second" ? `${control}\n${line}\n` : `${line}\n`;
  writeFileSync(dest, text);
}

function replaceOnce(from, to) {
  const parts = control.split(from);
  if (parts.length !== 2) {
    process.stderr.write(`mutate: ${JSON.stringify(from)} matched ${parts.length - 1} times\n`);
    process.exit(2);
  }
  emit(control.replace(from, to));
}

function transform(pairs) {
  let text = control;
  for (const [from, to] of pairs) {
    const parts = text.split(from);
    if (parts.length !== 2) {
      process.stderr.write(`mutate: ${JSON.stringify(from)} matched ${parts.length - 1} times\n`);
      process.exit(2);
    }
    text = text.replace(from, to);
  }
  emit(text);
}

switch (kind) {
  case "missing-schema":
    replaceOnce('"schema":"gibson.owner-order.v1",', "");
    break;
  case "missing-issued_at":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z",', "");
    break;
  case "missing-repo":
    replaceOnce('"repo":"The-AIE/the-gibson",', "");
    break;
  case "missing-order":
    replaceOnce('"order":[424,307],', "");
    break;
  case "missing-source":
    replaceOnce('"source":"https://example.test/owner-order/424",', "");
    break;
  case "type-schema":
    replaceOnce('"schema":"gibson.owner-order.v1"', '"schema":1');
    break;
  case "type-issued_at":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":1');
    break;
  case "type-repo":
    replaceOnce('"repo":"The-AIE/the-gibson"', '"repo":1');
    break;
  case "type-order":
    replaceOnce('"order":[424,307]', '"order":"424"');
    break;
  case "type-source":
    replaceOnce('"source":"https://example.test/owner-order/424"', '"source":1');
    break;
  case "type-supersedes":
    replaceOnce('"supersedes":"2026-10-01T12:00:00Z"', '"supersedes":1');
    break;
  case "empty-schema":
    replaceOnce('"schema":"gibson.owner-order.v1"', '"schema":""');
    break;
  case "empty-repo":
    replaceOnce('"repo":"The-AIE/the-gibson"', '"repo":""');
    break;
  case "empty-source":
    replaceOnce('"source":"https://example.test/owner-order/424"', '"source":""');
    break;
  case "empty-order":
    replaceOnce('"order":[424,307]', '"order":[]');
    break;
  case "unknown-schema":
    replaceOnce('"schema":"gibson.owner-order.v1"', '"schema":"gibson.owner-order.v2"');
    break;
  case "dup-order":
    replaceOnce('"order":[424,307]', '"order":[424,424]');
    break;
  case "zero-order":
    replaceOnce('"order":[424,307]', '"order":[0]');
    break;
  case "negative-order":
    replaceOnce('"order":[424,307]', '"order":[-1]');
    break;
  case "float-order":
    replaceOnce('"order":[424,307]', '"order":[1.5]');
    break;
  case "string-order":
    replaceOnce('"order":[424,307]', '"order":["424"]');
    break;
  case "bool-order":
    replaceOnce('"order":[424,307]', '"order":[true]');
    break;
  case "null-order":
    replaceOnce('"order":[424,307]', '"order":[null]');
    break;
  case "unsafe-order":
    replaceOnce('"order":[424,307]', '"order":[9007199254740993]');
    break;
  case "unknown-key":
    replaceOnce(
      '"supersedes":"2026-10-01T12:00:00Z"}',
      '"supersedes":"2026-10-01T12:00:00Z","note":"not-a-field"}'
    );
    break;
  case "ts-offsetless":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T15:00:00"');
    break;
  case "ts-date-only":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03"');
    break;
  case "ts-feb31":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-02-31T00:00:00Z"');
    break;
  case "ts-month13":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-13-01T00:00:00Z"');
    break;
  case "ts-lower-z":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T15:00:00z"');
    break;
  case "ts-lower-t":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03t15:00:00Z"');
    break;
  case "ts-no-seconds":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T15:00Z"');
    break;
  case "ts-offset-nocolon":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T15:00:00+0000"');
    break;
  case "ts-space":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03 15:00:00Z"');
    break;
  case "ts-slash":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"10/03/2026"');
    break;
  case "ts-hour24":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T24:00:00Z"');
    break;
  case "ts-minute60":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T15:60:00Z"');
    break;
  case "ts-second60":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T15:00:60Z"');
    break;
  case "ts-nonleap":
    replaceOnce('"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2023-02-29T00:00:00Z"');
    break;
  case "bad-supersedes":
    replaceOnce('"supersedes":"2026-10-01T12:00:00Z"', '"supersedes":"yesterday"');
    break;
  case "bad-supersedes-offsetless":
    replaceOnce('"supersedes":"2026-10-01T12:00:00Z"', '"supersedes":"2026-10-01T12:00:00"');
    break;
  case "raw-array":
    emit("[1,2,3]");
    break;
  case "raw-string":
    emit('"NOT-A-RECORD"');
    break;
  case "raw-number":
    emit("42");
    break;
  case "raw-null":
    emit("null");
    break;
  case "raw-true":
    emit("true");
    break;
  case "blank-spaces":
    emit("   ");
    break;
  case "ts-subms-later":
    transform([
      ['"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T15:00:00.0002Z"'],
      ['"source":"https://example.test/owner-order/424"', '"source":"https://example.test/owner-order/subms-later"'],
    ]);
    break;
  case "ts-subms-earlier":
    transform([
      ['"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T15:00:00.0001Z"'],
      ['"source":"https://example.test/owner-order/424"', '"source":"https://example.test/owner-order/subms-earlier"'],
    ]);
    break;
  case "ts-frac-tenth":
    transform([
      ['"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T15:00:00.1Z"'],
      ['"source":"https://example.test/owner-order/424"', '"source":"https://example.test/owner-order/frac-tenth"'],
    ]);
    break;
  case "ts-frac-hundred-ms":
    transform([
      ['"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T15:00:00.100Z"'],
      ['"source":"https://example.test/owner-order/424"', '"source":"https://example.test/owner-order/frac-hundred-ms"'],
    ]);
    break;
  case "ts-subms-offset-later":
    transform([
      ['"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T10:00:00.0002-05:00"'],
      ['"source":"https://example.test/owner-order/424"', '"source":"https://example.test/owner-order/subms-offset-later"'],
    ]);
    break;
  case "ts-subms-offset-earlier":
    transform([
      ['"issued_at":"2026-10-03T15:00:00Z"', '"issued_at":"2026-10-03T16:00:00.0001+01:00"'],
      ['"source":"https://example.test/owner-order/424"', '"source":"https://example.test/owner-order/subms-offset-earlier"'],
    ]);
    break;
  default:
    process.stderr.write(`mutate: unknown kind ${kind}\n`);
    process.exit(2);
}
EOF

run_tool() {
  LAST_RC=0
  if [[ $# -eq 0 ]]; then
    LAST_OUT=$(node "$TOOL" 2>"$ERR_FILE") || LAST_RC=$?
  else
    LAST_OUT=$(node "$TOOL" "$@" 2>"$ERR_FILE") || LAST_RC=$?
  fi
  LAST_ERR=$(cat "$ERR_FILE")
}

assert_out() {
  local name="$1" want_rc="$2" want_out="$3"
  shift 3
  run_tool "$@"
  if [[ "$LAST_RC" -eq "$want_rc" && "$LAST_OUT" == "$want_out" && -z "$LAST_ERR" ]]; then
    ok "$name"
  else
    bad "$name (rc=$LAST_RC want=$want_rc out=$LAST_OUT err=$LAST_ERR)"
  fi
}

assert_usage() {
  local name="$1"
  shift
  run_tool "$@"
  if [[ "$LAST_RC" -eq 2 && -z "$LAST_OUT" && -n "$LAST_ERR" ]]; then
    ok "$name"
  else
    bad "$name (rc=$LAST_RC out=$LAST_OUT err=$LAST_ERR)"
  fi
}

# Two control mutations, later instant first so file order cannot crown it.
pair_from_control() {
  local later_kind="$1" earlier_kind="$2" dest="$3"
  if ! node "$TMP/mutate.mjs" "$FIX/control.jsonl" "$later_kind" "$TMP/pair-later.jsonl" only; then
    bad "mutator failed for $later_kind"
    return 1
  fi
  if ! node "$TMP/mutate.mjs" "$FIX/control.jsonl" "$earlier_kind" "$TMP/pair-earlier.jsonl" only; then
    bad "mutator failed for $earlier_kind"
    return 1
  fi
  cat "$TMP/pair-later.jsonl" "$TMP/pair-earlier.jsonl" > "$dest"
}

CONTROL_JSON='{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2026-10-03T15:00:00Z","source":"https://example.test/owner-order/424","order":[424,307]}'
NO_ORDER="HOLD: no owner order recorded"
TIE='HOLD: ambiguous owner order; sources: "https://example.test/owner-order/src-a" | "https://example.test/owner-order/src-b"'
SPELL='HOLD: ambiguous owner order; sources: "https://example.test/owner-order/spell-offset" | "https://example.test/owner-order/spell-z"'

printf '\n%s\n' "=== help and usage ==="
assert_out "help exits 0" 0 "$(node "$TOOL" --help)" --help
grep -i -q 'what' <<<"$LAST_OUT" && ok "help says what" || bad "help missing what"
grep -i -q 'why' <<<"$LAST_OUT" && ok "help says why" || bad "help missing why"
grep -i -q 'risks' <<<"$LAST_OUT" && ok "help says risks" || bad "help missing risks"
grep -i -q 'examples' <<<"$LAST_OUT" && ok "help says examples" || bad "help missing examples"
assert_out "short help exits 0" 0 "$(node "$TOOL" -h)" -h
assert_usage "no args" 
assert_usage "missing repo" --file "$FIX/control.jsonl"
assert_usage "missing file" --repo "$REPO"
assert_usage "file missing value" --file
assert_usage "repo missing value" --repo
assert_usage "unknown flag" --file "$FIX/control.jsonl" --repo "$REPO" --bogus
assert_usage "duplicate file" --file "$FIX/control.jsonl" --file "$FIX/control.jsonl" --repo "$REPO"
assert_usage "duplicate repo" --file "$FIX/control.jsonl" --repo "$REPO" --repo "$REPO"
assert_usage "duplicate check" --file "$FIX/control.jsonl" --repo "$REPO" --check-issues --check-issues
assert_usage "positional" --file "$FIX/control.jsonl" --repo "$REPO" extra
assert_usage "help is not a sidecar" --help --file "$FIX/control.jsonl"

printf '\n%s\n' "=== winners ==="
assert_out "one valid record" 0 "$CONTROL_JSON" --file "$FIX/control.jsonl" --repo "$REPO"
run_tool --file "$FIX/control.jsonl" --repo "$REPO"
first=$LAST_OUT
run_tool --file "$FIX/control.jsonl" --repo "$REPO"
if [[ "$LAST_RC" -eq 0 && "$first" == "$LAST_OUT" ]]; then
  node -e 'JSON.parse(process.argv[1])' "$first" && ok "success JSON is deterministic and parseable" || bad "success JSON did not parse"
else
  bad "success JSON was not stable (rc=$LAST_RC)"
fi
assert_out "afternoon wins on the same calendar date" 0 \
  '{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2026-10-03T18:45:00Z","source":"https://example.test/owner-order/afternoon","order":[22]}' \
  --file "$FIX/morning-afternoon.jsonl" --repo "$REPO"
assert_out "later instant wins even when its text sorts first" 0 \
  '{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2026-10-03T10:00:00-05:00","source":"https://example.test/owner-order/offset-later","order":[5]}' \
  --file "$FIX/offset-instants.jsonl" --repo "$REPO"
assert_out "other repository does not change the winner" 0 \
  '{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2026-10-03T12:00:00Z","source":"https://example.test/owner-order/target-noon","order":[7]}' \
  --file "$FIX/other-repo.jsonl" --repo "$REPO"
assert_out "older physical tail does not win" 0 \
  '{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2026-10-03T16:00:00Z","source":"https://example.test/owner-order/early-physical","order":[1]}' \
  --file "$FIX/later-line-older.jsonl" --repo "$REPO"
assert_out "exact duplicates collapse" 0 "$CONTROL_JSON" --file "$FIX/exact-duplicate.jsonl" --repo "$REPO"
assert_out "supersedes does not override the newest instant" 0 \
  '{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2026-10-03T12:00:00Z","source":"https://example.test/owner-order/newer-issued","order":[2]}' \
  --file "$FIX/supersedes-not-winner.jsonl" --repo "$REPO"
node -e '
  const fs = require("fs");
  const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const reordered = JSON.stringify({
    source: o.source, order: o.order, repo: o.repo,
    issued_at: o.issued_at, schema: o.schema, supersedes: o.supersedes
  });
  fs.writeFileSync(process.argv[2], JSON.stringify(o) + "\n" + reordered + "\n");
' "$FIX/control.jsonl" "$TMP/reordered.jsonl"
assert_out "same record with different key order collapses" 0 "$CONTROL_JSON" --file "$TMP/reordered.jsonl" --repo "$REPO"
node -e '
  const fs = require("fs");
  const line = fs.readFileSync(process.argv[1], "utf8").replace(/\n$/, "");
  fs.writeFileSync(process.argv[2], line);
' "$FIX/control.jsonl" "$TMP/nonewline.jsonl"
assert_out "no trailing newline still resolves" 0 "$CONTROL_JSON" --file "$TMP/nonewline.jsonl" --repo "$REPO"
node "$TMP/mutate.mjs" "$FIX/control.jsonl" ts-offsetless "$TMP/leap.jsonl" only >/dev/null
node -e '
  const fs = require("fs");
  const line = fs.readFileSync(process.argv[1], "utf8").replace(
    "2026-10-03T15:00:00",
    "2024-02-29T00:00:00Z"
  );
  fs.writeFileSync(process.argv[1], line);
' "$TMP/leap.jsonl"
assert_out "leap day is a real instant" 0 \
  '{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2024-02-29T00:00:00Z","source":"https://example.test/owner-order/424","order":[424,307]}' \
  --file "$TMP/leap.jsonl" --repo "$REPO"
if pair_from_control ts-subms-later ts-subms-earlier "$TMP/subms-later.jsonl"; then
  assert_out "sub-millisecond later fraction wins" 0 \
    '{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2026-10-03T15:00:00.0002Z","source":"https://example.test/owner-order/subms-later","order":[424,307]}' \
    --file "$TMP/subms-later.jsonl" --repo "$REPO"
fi
if pair_from_control ts-frac-hundred-ms ts-frac-tenth "$TMP/frac-equal.jsonl"; then
  assert_out "trailing-zero fractions at one instant hold" 3 \
    'HOLD: ambiguous owner order; sources: "https://example.test/owner-order/frac-hundred-ms" | "https://example.test/owner-order/frac-tenth"' \
    --file "$TMP/frac-equal.jsonl" --repo "$REPO"
fi
if pair_from_control ts-subms-offset-later ts-subms-offset-earlier "$TMP/subms-offset.jsonl"; then
  assert_out "sub-millisecond order survives equivalent numeric offsets" 0 \
    '{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2026-10-03T10:00:00.0002-05:00","source":"https://example.test/owner-order/subms-offset-later","order":[424,307]}' \
    --file "$TMP/subms-offset.jsonl" --repo "$REPO"
fi

printf '\n%s\n' "=== holds ==="
assert_out "missing file" 3 "$NO_ORDER" --file "$TMP/does-not-exist.jsonl" --repo "$REPO"
assert_out "empty file" 3 "$NO_ORDER" --file "$FIX/empty.jsonl" --repo "$REPO"
assert_out "no record for this repo" 3 "$NO_ORDER" --file "$FIX/only-other-repo.jsonl" --repo "$REPO"
assert_out "wrong repo slug" 3 "$NO_ORDER" --file "$FIX/control.jsonl" --repo "OtherOrg/other-repo"
assert_out "different orders at one instant hold and name both sources" 3 "$TIE" \
  --file "$FIX/tie-orders.jsonl" --repo "$REPO"
assert_out "reversed file order is the same hold" 3 "$TIE" \
  --file "$FIX/tie-orders-reversed.jsonl" --repo "$REPO"
assert_out "same instant with different spellings holds" 3 "$SPELL" \
  --file "$FIX/same-instant-spelling.jsonl" --repo "$REPO"
assert_out "blank physical line" 3 "HOLD: malformed owner order at line 2" \
  --file "$FIX/blank-line.jsonl" --repo "$REPO"
assert_out "malformed JSON names the line and not the body" 3 "HOLD: malformed owner order at line 2" \
  --file "$FIX/malformed-json.jsonl" --repo "$REPO"
if [[ "$LAST_OUT" == *'this is not json'* ]]; then
  bad "malformed JSON echoed the record body"
else
  ok "malformed JSON did not echo the record body"
fi
assert_out "non-object JSON names line 1" 3 "HOLD: malformed owner order at line 1" \
  --file "$FIX/non-object.jsonl" --repo "$REPO"
if [[ "$LAST_OUT" == *'[1,2,3]'* ]]; then
  bad "non-object JSON echoed the record body"
else
  ok "non-object JSON did not echo the record body"
fi
assert_out "unreadable path holds" 3 "HOLD: cannot read owner order file" --file "$TMP" --repo "$REPO"

MUT="$TMP/mut.jsonl"
while IFS='|' read -r kind line forbidden permissive; do
  [[ -z "${kind:-}" ]] && continue
  if ! node "$TMP/mutate.mjs" "$FIX/control.jsonl" "$kind" "$MUT" second; then
    bad "mutator failed for $kind"
    continue
  fi
  want="HOLD: malformed owner order at line $line"
  run_tool --file "$MUT" --repo "$REPO"
  if [[ "$LAST_RC" -eq 3 && "$LAST_OUT" == "$want" && -z "$LAST_ERR" ]]; then
    if [[ -n "$forbidden" && "$LAST_OUT" == *"$forbidden"* ]]; then
      bad "$kind echoed untrusted text"
    else
      ok "$kind holds at line $line"
    fi
  else
    bad "$kind (rc=$LAST_RC out=$LAST_OUT err=$LAST_ERR)"
  fi
  if [[ "$permissive" == "1" ]]; then
    if node -e 'process.exit(Number.isNaN(Date.parse(process.argv[1])) ? 1 : 0)' "$forbidden"; then
      ok "$kind is permissively parseable and still rejected"
    else
      bad "$kind was supposed to be permissively parseable"
    fi
  fi
done << 'EOF'
missing-schema|2||0
missing-issued_at|2||0
missing-repo|2||0
missing-order|2||0
missing-source|2||0
type-schema|2||0
type-issued_at|2||0
type-repo|2||0
type-order|2||0
type-source|2||0
type-supersedes|2||0
empty-schema|2||0
empty-repo|2||0
empty-source|2||0
empty-order|2||0
unknown-schema|2|gibson.owner-order.v2|0
dup-order|2||0
zero-order|2||0
negative-order|2||0
float-order|2||0
string-order|2||0
bool-order|2||0
null-order|2||0
unsafe-order|2|9007199254740993|0
unknown-key|2|not-a-field|0
ts-offsetless|2|2026-10-03T15:00:00|1
ts-date-only|2|2026-10-03|1
ts-feb31|2|2026-02-31T00:00:00Z|1
ts-month13|2|2026-13-01T00:00:00Z|0
ts-lower-z|2|2026-10-03T15:00:00z|1
ts-lower-t|2|2026-10-03t15:00:00Z|1
ts-no-seconds|2|2026-10-03T15:00Z|1
ts-offset-nocolon|2|2026-10-03T15:00:00+0000|1
ts-space|2|2026-10-03 15:00:00Z|1
ts-slash|2|10/03/2026|1
ts-hour24|2|2026-10-03T24:00:00Z|1
ts-minute60|2|2026-10-03T15:60:00Z|0
ts-second60|2|2026-10-03T15:00:60Z|0
ts-nonleap|2|2023-02-29T00:00:00Z|1
bad-supersedes|2|yesterday|0
bad-supersedes-offsetless|2|2026-10-01T12:00:00|1
raw-array|2|[1,2,3]|0
raw-string|2|NOT-A-RECORD|0
raw-number|2||0
raw-null|2||0
raw-true|2||0
blank-spaces|2||0
EOF

if [[ -s "$GH_LOG" ]]; then
  bad "offline section called gh: $(cat "$GH_LOG")"
else
  ok "offline section did not call gh"
fi

printf '\n%s\n' "=== check-issues ==="
: > "$GH_LOG"
GH_MODE=forbid
assert_out "tie does not call gh" 3 "$TIE" --file "$FIX/tie-orders.jsonl" --repo "$REPO" --check-issues
if [[ -s "$GH_LOG" ]]; then
  bad "tie --check-issues called gh"
else
  ok "tie --check-issues did not call gh"
fi

: > "$GH_LOG"
GH_MODE=mixed
assert_out "closed issues keep winning order" 0 \
  '{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2026-10-03T15:00:00Z","source":"https://example.test/owner-order/check","order":[424,307,70],"closed_issues":[424,70]}' \
  --file "$FIX/check-order.jsonl" --repo "$REPO" --check-issues
want_log='issue view 424 --repo The-AIE/the-gibson --json state
issue view 307 --repo The-AIE/the-gibson --json state
issue view 70 --repo The-AIE/the-gibson --json state'
if [[ "$(cat "$GH_LOG")" == "$want_log" ]]; then
  ok "gh argv is the issue, the explicit repo, and state only"
else
  bad "gh argv mismatch: $(cat "$GH_LOG")"
fi

: > "$GH_LOG"
GH_MODE=open
assert_out "no closed issues still keeps order" 0 \
  '{"schema":"gibson.owner-order-resolution/v1","repo":"The-AIE/the-gibson","issued_at":"2026-10-03T15:00:00Z","source":"https://example.test/owner-order/check","order":[424,307,70],"closed_issues":[]}' \
  --file "$FIX/check-order.jsonl" --repo "$REPO" --check-issues

: > "$GH_LOG"
GH_MODE=fail
assert_out "gh failure holds" 3 "HOLD: issue lookup failed for 424" \
  --file "$FIX/check-order.jsonl" --repo "$REPO" --check-issues
if [[ "$LAST_OUT" == *'TOKEN-LEAK'* || "$LAST_ERR" == *'TOKEN-LEAK'* ]]; then
  bad "gh failure leaked stderr"
else
  ok "gh failure did not leak stderr"
fi

: > "$GH_LOG"
GH_MODE=malformed
assert_out "malformed gh output holds" 3 "HOLD: malformed issue state for 424" \
  --file "$FIX/check-order.jsonl" --repo "$REPO" --check-issues

: > "$GH_LOG"
GH_MODE=unknown
assert_out "unknown issue state holds" 3 "HOLD: unknown issue state for 424" \
  --file "$FIX/check-order.jsonl" --repo "$REPO" --check-issues
if [[ "$LAST_OUT" == *'MERGED'* ]]; then
  bad "unknown state echoed the gh body"
else
  ok "unknown state did not echo the gh body"
fi

mv "$BIN/gh" "$BIN/gh.off"
: > "$GH_LOG"
assert_out "missing gh holds" 3 "HOLD: gh is not available" \
  --file "$FIX/check-order.jsonl" --repo "$REPO" --check-issues
mv "$BIN/gh.off" "$BIN/gh"

printf '\n%s\n' "=== summary ==="
printf 'queue-order.test.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
