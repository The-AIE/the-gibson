#!/usr/bin/env bash
# lesson-proof.test.sh — replay proof for closed lessons (#570)
# Lesson ids in this file are built with lid so the source has no literal id.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
SENSOR="$SCRIPT_DIR/../lesson-proof.mjs"
FX_SRC="$SCRIPT_DIR/fixtures/lesson-proof"
WF="$REPO_ROOT/.github/workflows/lesson-proof.yml"
DOC="$REPO_ROOT/docs/lesson-proof.md"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "lesson-proof.test.sh: node required" >&2; exit 1; }
command -v git >/dev/null || { echo "lesson-proof.test.sh: git required" >&2; exit 1; }

lid() { printf 'L-%03d' "$1"; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-lesson-proof.XXXXXX") || {
  echo "lesson-proof.test.sh: mktemp -d failed" >&2
  exit 1
}
SENSOR_BAK=$(mktemp "${TMPDIR:-/tmp}/gibson-lesson-proof-sensor.XXXXXX") || {
  echo "lesson-proof.test.sh: mktemp sensor backup failed" >&2
  exit 1
}
cp "$SENSOR" "$SENSOR_BAK" || {
  echo "lesson-proof.test.sh: cannot back up the sensor" >&2
  exit 1
}

cleanup() {
  if [[ -n "${SENSOR_BAK:-}" && -f "${SENSOR_BAK}" && -f "${SENSOR}" ]]; then
    cp "$SENSOR_BAK" "$SENSOR"
    rm -f "$SENSOR_BAK"
  fi
  if [[ -n "${ROOT:-}" && -d "${ROOT}" ]]; then
    rm -rf -- "${ROOT:?}"
  fi
}
trap cleanup EXIT

gitc() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX \
    -u GIT_AUTHOR_DATE -u GIT_COMMITTER_DATE \
    "$@"
}

INSPECT="$ROOT/inspect.js"
MUTATE="$ROOT/mutate.js"
cat > "$INSPECT" <<'EOF'
const fs = require("fs");

function load(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

function walk(obj, path) {
  let cur = obj;
  if (!path) return cur;
  for (const part of path.split(".")) {
    if (cur == null) return undefined;
    cur = cur[part];
  }
  return cur;
}

function show(value) {
  if (value === undefined) process.stdout.write("undefined\n");
  else if (value === null) process.stdout.write("null\n");
  else process.stdout.write(String(value) + "\n");
}

function headings(text) {
  const lines = text.split(/\r?\n/);
  let fence = null;
  let html = false;
  let n = 0;
  const head = /^## (L-\d{3})\b/;
  for (const line of lines) {
    if (fence) {
      const closed = /^( {0,3})(`{3,}|~{3,})\s*$/.exec(line);
      if (closed && closed[2][0] === fence.char && closed[2].length >= fence.len) fence = null;
      continue;
    }
    if (html) {
      if (line.includes("-->")) html = false;
      continue;
    }
    if (line.includes("<!--") && !line.includes("-->")) {
      html = true;
      continue;
    }
    const open = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line);
    if (open && !(open[2][0] === "`" && open[3].includes("`"))) {
      fence = { char: open[2][0], len: open[2].length };
      continue;
    }
    if (head.test(line) && line.trim().startsWith("## ")) n += 1;
  }
  return n;
}

const cmd = process.argv[2];
if (cmd === "tsv") {
  const report = load(process.argv[3]);
  const lines = report.lessons.map((lesson) =>
    [lesson.id, lesson.verdict, lesson.reason, lesson.closure, String(lesson.downgradeCandidate)].join("\t")
  );
  fs.writeFileSync(process.argv[4], lines.join("\n") + (lines.length ? "\n" : ""));
} else if (cmd === "get") {
  const report = load(process.argv[3]);
  const id = process.argv[4];
  const index = Number(process.argv[5] || 0);
  const row = report.lessons.filter((lesson) => lesson.id === id)[index];
  show(walk(row, process.argv[6]));
} else if (cmd === "header") {
  show(walk(load(process.argv[3]), process.argv[4]));
} else if (cmd === "live") {
  const report = load(process.argv[3]);
  const ledger = fs.readFileSync(process.argv[4], "utf8");
  const problems = [];
  const found = headings(ledger);
  if (found !== report.lessons.length) {
    problems.push("headings " + found + " != lessons " + report.lessons.length);
  }
  let pending = 0;
  for (const lesson of report.lessons) {
    const closure = lesson.closure === "fix" || lesson.closure === "nonfix";
    if (closure && lesson.verdict !== "proven") pending += 1;
    if (closure && (lesson.proof == null || lesson.proof === "")) {
      if (lesson.verdict !== "unproven" || lesson.reason !== "proof-absent" || lesson.downgradeCandidate !== true) {
        problems.push(lesson.id + " absent proof -> " + lesson.verdict + "/" + lesson.reason);
      }
    }
    if (lesson.proof === "unknown" && !(lesson.verdict === "unknown" && lesson.reason === "proof-unknown")) {
      problems.push(lesson.id + " proof unknown -> " + lesson.verdict + "/" + lesson.reason);
    }
    if (lesson.verdict === "proven" && (lesson.closure !== "fix" || !lesson.proof || !lesson.proof.sha)) {
      problems.push(lesson.id + " proven without a fix replay");
    }
    if (lesson.verdict === "not-closure" && lesson.closure !== "open") {
      problems.push(lesson.id + " not-closure closure=" + lesson.closure);
    }
    if (lesson.closure === "open" && lesson.verdict !== "not-closure") {
      problems.push(lesson.id + " open verdict=" + lesson.verdict);
    }
  }
  const counts = report.counts;
  const sum = counts.proven + counts.unproven + counts.unknown + counts.notClosure;
  if (sum !== report.lessons.length) problems.push("counts do not add up");
  process.stdout.write(
    "proven=" + counts.proven +
    " unproven=" + counts.unproven +
    " unknown=" + counts.unknown +
    " notClosure=" + counts.notClosure +
    " pending=" + pending + "\n"
  );
  if (problems.length) {
    process.stderr.write(problems.join("\n") + "\n");
    process.exit(1);
  }
  process.stdout.write(pending > 0 ? "strict-expect=1\n" : "strict-expect=0\n");
} else {
  process.stderr.write("unknown inspect command\n");
  process.exit(2);
}
EOF

cat > "$MUTATE" <<'EOF'
const fs = require("fs");
const file = process.argv[2];
const token = process.argv[3];
const replacement = process.argv[4];
const lines = fs.readFileSync(file, "utf8").split("\n");
let hits = 0;
for (let i = 0; i < lines.length; i += 1) {
  if (lines[i].includes(token)) {
    lines[i] = replacement;
    hits += 1;
  }
}
if (hits !== 1) {
  process.stderr.write("mutation hits " + hits + " for " + token + "\n");
  process.exit(3);
}
fs.writeFileSync(file, lines.join("\n"));
EOF

if node --check "$SENSOR"; then
  ok "sensor parses"
else
  bad "sensor does not parse"
fi

echo "# fixture repository"
REPO="$ROOT/repo"
HOOKS="$ROOT/hooks"
mkdir -p "$HOOKS" "$REPO"
cp -R "$FX_SRC/." "$REPO/"
cat > "$REPO/gates/syntax-error.sh" <<'EOF'
#!/usr/bin/env bash
LESSON_PROOF_ENFORCE=1
if [[
EOF
gitc git -C "$REPO" init -q
gitc git -C "$REPO" symbolic-ref HEAD refs/heads/main
gitc git -C "$REPO" config user.email fixture@example.invalid
gitc git -C "$REPO" config user.name lesson-proof-fixture
gitc git -C "$REPO" config commit.gpgsign false
gitc git -C "$REPO" config core.hooksPath "$HOOKS"
gitc git -C "$REPO" add -A
if ! gitc git -C "$REPO" commit -q -m "fixture"; then
  bad "fixture commit"
  gitc git -C "$REPO" status --short
  exit 1
fi
SHA=$(gitc git -C "$REPO" rev-parse HEAD) || { bad "rev-parse"; exit 1; }
if [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  ok "fixture commit sha"
else
  bad "fixture commit sha ($SHA)"
fi
ZERO="0000000000000000000000000000000000000000"
UPPER=$(printf '%40s' '' | tr ' ' 'A')

LEDGER="$ROOT/ledger.md"
EXPECTED="$ROOT/expected.tsv"
SPEC="$ROOT/spec.txt"
cat > "$SPEC" <<'EOF'
901|fixed|bound:gates/enforcing.sh:tree-good|proven|replay-passed|fix|false
902|fixed|bound:gates/enforcing.mjs:tree-good|proven|replay-passed|fix|false
903|fixed|none|unproven|proof-absent|fix|true
904|fixed|word:unknown|unknown|proof-unknown|fix|false
905|fixed|bound:gates/noop.sh:tree-good|unproven|bad-fixture-passed|fix|true
906|fixed|bound:gates/enforcing.sh:tree-both-ok|unproven|bad-fixture-passed|fix|true
907|fixed|zeros:gates/enforcing.sh:tree-good|unknown|sha-absent|fix|false
908|wontfix|none|unproven|proof-absent|nonfix|true
909|wontfix|bound:gates/enforcing.sh:tree-good|unknown|accepted-risk-not-in-contract|nonfix|false
910|obsolete|none|unproven|proof-absent|nonfix|true
911|duplicate|none|unproven|proof-absent|nonfix|true
912|working as designed|none|unproven|proof-absent|nonfix|true
913|no fix needed beyond the note|none|unproven|proof-absent|nonfix|true
914|fix-pending|none|not-closure|status-not-closure|open|false
915|intake example (no sensor yet)|none|not-closure|status-not-closure|open|false
916|reconstructed 2026-10-25 from a note|none|not-closure|status-not-closure|open|false
917|fixed|bound:gates/disarm-unused.sh:tree-good|unproven|disarm-still-fails|fix|true
918|fixed|bound:gates/rejects-all.sh:tree-good|unproven|valid-fixture-failed|fix|true
919|fixed|bound:gates/no-marker.sh:tree-good|unknown|disarm-marker-absent|fix|false
920|fixed|word:not-a-proof|unproven|proof-malformed|fix|true
921|fixed|dupstatus|unknown|duplicate-field|fix|false
922|applied in product|none|not-closure|status-not-closure|open|false
923|fixed|word:Unknown|unproven|proof-malformed|fix|true
924|fixed|bound:gates/enforcing.sh:tree-no-bad|unknown|fixture-case-missing|fix|false
925||nostatus-bound:gates/enforcing.sh:tree-good|unknown|status-missing|unknown|false
926|fixed|wrapped:gates/enforcing.sh:tree-good|proven|replay-passed|fix|false
927|fixed|bound:gates/syntax-error.sh:tree-good|unknown|entrypoint-does-not-parse|fix|false
928|fixed|bound:gates/enforcing.sh:tree-good|unknown|duplicate-field|fix|false
928|fixed|bound:gates/enforcing.sh:tree-good|unknown|duplicate-field|fix|false
929|not a bug|none|unproven|proof-absent|nonfix|true
930|superseded|none|unproven|proof-absent|nonfix|true
931|fixed|bound:gates/sleep.sh:tree-good|unknown|gate-timeout|fix|false
932|fixed (parenthetical note)|none|unproven|proof-absent|fix|true
933|fixed|bound:gates/missing.sh:tree-good|unknown|entrypoint-missing|fix|false
934|fixed|abs|unproven|proof-malformed|fix|true
935|fixed|dotdot|unproven|proof-malformed|fix|true
936|fixed|upper|unproven|proof-malformed|fix|true
937|fixed|empty|unproven|proof-malformed|fix|true
938|fixed "x"|none|unproven|proof-absent|fix|true
939|closed|none|unproven|proof-absent|nonfix|true
EOF

{
  printf '%s\n' '# Fixture ledger'
  printf '%s\n' '```'
  printf '## %s · 2026-10-25 · fenced-decoy\n' "$(lid 1)"
  printf '%s\n' '**Status:** fixed'
  printf '%s\n' '```'
  printf '%s\n' '<!--'
  printf '## %s · 2026-10-25 · comment-decoy\n' "$(lid 2)"
  printf '%s\n' '**Status:** fixed'
  printf '%s\n' '-->'
  printf '%s\n' ''
} > "$LEDGER"
: > "$EXPECTED"

append_heading() {
  printf '## %s · 2026-10-25 · fixture-%s\n' "$(lid "$1")" "$1" >> "$LEDGER"
}
append_status() {
  printf '**Status:** %s\n' "$1" >> "$LEDGER"
}
append_tail() {
  printf '**Tags:** #fixture\n\n' >> "$LEDGER"
}
split_entry_dir() {
  ENTRY=${1%%:*}
  DIR=${1#*:}
}

while IFS='|' read -r num status kind verdict reason closure down; do
  [[ -z "$num" || "$num" == \#* ]] && continue
  append_heading "$num"
  case "$kind" in
    none)
      append_status "$status"
      ;;
    word:*)
      append_status "$status"
      printf '**Proof:** %s\n' "${kind#word:}" >> "$LEDGER"
      ;;
    bound:*)
      split_entry_dir "${kind#bound:}"
      append_status "$status"
      printf '**Proof:** %s %s %s\n' "$SHA" "$ENTRY" "$DIR" >> "$LEDGER"
      ;;
    zeros:*)
      split_entry_dir "${kind#zeros:}"
      append_status "$status"
      printf '**Proof:** %s %s %s\n' "$ZERO" "$ENTRY" "$DIR" >> "$LEDGER"
      ;;
    wrapped:*)
      split_entry_dir "${kind#wrapped:}"
      append_status "$status"
      printf '**Proof:** %s\n' "$SHA" >> "$LEDGER"
      printf '%s %s\n' "$ENTRY" "$DIR" >> "$LEDGER"
      ;;
    dupstatus)
      append_status "$status"
      append_status "$status"
      ;;
    nostatus-bound:*)
      split_entry_dir "${kind#nostatus-bound:}"
      printf '**Proof:** %s %s %s\n' "$SHA" "$ENTRY" "$DIR" >> "$LEDGER"
      ;;
    empty)
      append_status "$status"
      printf '**Proof:**\n' >> "$LEDGER"
      ;;
    abs)
      append_status "$status"
      printf '**Proof:** %s /abs/gate.sh tree-good\n' "$SHA" >> "$LEDGER"
      ;;
    dotdot)
      append_status "$status"
      printf '**Proof:** %s gates/enforcing.sh tree-good/../tree-good\n' "$SHA" >> "$LEDGER"
      ;;
    upper)
      append_status "$status"
      printf '**Proof:** %s gates/enforcing.sh tree-good\n' "$UPPER" >> "$LEDGER"
      ;;
    *)
      bad "unknown fixture kind $kind"
      ;;
  esac
  append_tail
  printf '%s\t%s\t%s\t%s\t%s\n' "$(lid "$num")" "$verdict" "$reason" "$closure" "$down" >> "$EXPECTED"
done < "$SPEC"

BIG_JSON="$ROOT/big.json"
BIG_OUT="$ROOT/big.out"
BIG_ERR="$ROOT/big.err"
echo "# replay fixture ledger"
node "$SENSOR" --repo "$REPO" --ledger "$LEDGER" --json "$BIG_JSON" >"$BIG_OUT" 2>"$BIG_ERR"
rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "fixture report exits 0"
else
  bad "fixture report exits $rc"
  cat "$BIG_ERR"
  cat "$BIG_OUT"
fi
if [[ ! -s "$BIG_ERR" ]]; then
  ok "fixture report stderr empty"
else
  bad "fixture report stderr: $(cat "$BIG_ERR")"
fi

ACTUAL="$ROOT/actual.tsv"
node "$INSPECT" tsv "$BIG_JSON" "$ACTUAL"
if diff -u "$EXPECTED" "$ACTUAL" >"$ROOT/verdict.diff"; then
  ok "fixture verdicts match the spec"
else
  bad "fixture verdicts differ"
  cat "$ROOT/verdict.diff"
fi

if grep -F "$(printf '%s\t' "$(lid 1)")" "$ACTUAL" >/dev/null; then
  bad "fenced decoy was counted as a lesson"
else
  ok "fenced decoy is not a lesson"
fi
if grep -F "$(printf '%s\t' "$(lid 2)")" "$ACTUAL" >/dev/null; then
  bad "comment decoy was counted as a lesson"
else
  ok "comment decoy is not a lesson"
fi

# Closed without a landed fix. These three rows are the shapes behind issues 2, 4, and 9.
for shape in \
  "$(lid 903) verdict=unproven closure=fix reason=proof-absent" \
  "$(lid 905) verdict=unproven closure=fix reason=bad-fixture-passed" \
  "$(lid 906) verdict=unproven closure=fix reason=bad-fixture-passed"
do
  if grep -F "$shape" "$BIG_OUT" >/dev/null; then
    ok "unproven shape: $shape"
  else
    bad "missing unproven shape: $shape"
  fi
done

if grep -F 'lesson-proof: unknown is not proven' "$BIG_OUT" >/dev/null; then
  ok "text says unknown is not proven"
else
  bad "text missing unknown is not proven"
fi
if grep -F 'lesson-proof: report-only' "$BIG_OUT" >/dev/null; then
  ok "text says report-only"
else
  bad "text missing report-only"
fi
if grep -F 'gibson.lesson-proof.report.v1' "$BIG_OUT" >/dev/null; then
  bad "json leaked onto stdout"
else
  ok "json stayed in the file"
fi
if grep -F 'LESSON_PROOF_GATE_SAW_FIXTURE' "$BIG_OUT" >/dev/null || grep -F 'LESSON_PROOF_GATE_SAW_FIXTURE' "$BIG_JSON" >/dev/null; then
  bad "gate stdout was copied into the report"
else
  ok "gate stdout is not in the report"
fi

get_field() {
  node "$INSPECT" get "$1" "$2" 0 "$3"
}
header_field() {
  node "$INSPECT" header "$1" "$2"
}

if [[ "$(header_field "$BIG_JSON" schema)" == "gibson.lesson-proof.report.v1" ]]; then
  ok "schema"
else
  bad "schema ($(header_field "$BIG_JSON" schema))"
fi
if [[ "$(header_field "$BIG_JSON" mode)" == "report-only" ]]; then
  ok "mode stays report-only"
else
  bad "mode ($(header_field "$BIG_JSON" mode))"
fi
if [[ "$(header_field "$BIG_JSON" strict)" == "false" ]]; then
  ok "default strict is false"
else
  bad "default strict ($(header_field "$BIG_JSON" strict))"
fi
if [[ "$(header_field "$BIG_JSON" runStatus)" == "complete" ]]; then
  ok "fixture run complete"
else
  bad "fixture runStatus ($(header_field "$BIG_JSON" runStatus))"
fi
if [[ "$(get_field "$BIG_JSON" "$(lid 901)" replay.bad.exitCode)" == "1" \
   && "$(get_field "$BIG_JSON" "$(lid 901)" replay.valid.exitCode)" == "0" \
   && "$(get_field "$BIG_JSON" "$(lid 901)" replay.disarmedBad.exitCode)" == "0" \
   && "$(get_field "$BIG_JSON" "$(lid 901)" replay.disarmedBad.protectionNotFiring)" == "true" \
   && "$(get_field "$BIG_JSON" "$(lid 901)" replay.sha)" == "$SHA" ]]; then
  ok "proven replay exits and sha"
else
  bad "proven replay fields"
fi
if [[ "$(get_field "$BIG_JSON" "$(lid 902)" replay.bad.exitCode)" == "1" \
   && "$(get_field "$BIG_JSON" "$(lid 902)" replay.disarmedBad.exitCode)" == "0" ]]; then
  ok "node entrypoint replay"
else
  bad "node entrypoint replay"
fi
if [[ "$(get_field "$BIG_JSON" "$(lid 905)" replay.bad.exitCode)" == "0" ]]; then
  ok "noop bad directory exits 0"
else
  bad "noop bad exit ($(get_field "$BIG_JSON" "$(lid 905)" replay.bad.exitCode))"
fi
if [[ "$(get_field "$BIG_JSON" "$(lid 917)" replay.disarmedBad.exitCode)" == "1" ]]; then
  ok "disarmed bad still fails"
else
  bad "disarmed bad exit ($(get_field "$BIG_JSON" "$(lid 917)" replay.disarmedBad.exitCode))"
fi
if [[ "$(get_field "$BIG_JSON" "$(lid 918)" replay.valid.exitCode)" == "1" ]]; then
  ok "valid directory failed"
else
  bad "valid exit ($(get_field "$BIG_JSON" "$(lid 918)" replay.valid.exitCode))"
fi
if [[ "$(get_field "$BIG_JSON" "$(lid 931)" replay.bad.ran)" == "false" \
   && "$(get_field "$BIG_JSON" "$(lid 931)" replay.bad.reason)" == "gate-timeout" ]]; then
  ok "timeout is unknown"
else
  bad "timeout replay bad.ran=$(get_field "$BIG_JSON" "$(lid 931)" replay.bad.ran) reason=$(get_field "$BIG_JSON" "$(lid 931)" replay.bad.reason)"
fi
if [[ "$(get_field "$BIG_JSON" "$(lid 903)" proof)" == "null" \
   && "$(get_field "$BIG_JSON" "$(lid 904)" proof)" == "unknown" \
   && "$(get_field "$BIG_JSON" "$(lid 901)" proof.sha)" == "$SHA" ]]; then
  ok "proof field shape"
else
  bad "proof field shape"
fi
if [[ "$(get_field "$BIG_JSON" "$(lid 928)" verdict)" == "unknown" \
   && "$(get_field "$BIG_JSON" "$(lid 928)" verdict)" == "unknown" ]]; then
  dup_n=$(grep -c "$(printf '^%s\t' "$(lid 928)")" "$ACTUAL" || true)
  if [[ "$dup_n" -eq 2 ]]; then
    ok "duplicate id marks both rows"
  else
    bad "duplicate id row count $dup_n"
  fi
else
  bad "duplicate id verdict"
fi
limits=$(header_field "$BIG_JSON" limits)
if printf '%s\n' "$limits" | grep -F 'does not read fixture bytes' >/dev/null \
  && printf '%s\n' "$limits" | grep -F 'including unknown' >/dev/null; then
  ok "limits are in the report"
else
  bad "limits missing from the report"
fi

before=$(cksum "$LEDGER")
node "$SENSOR" --repo "$REPO" --ledger "$LEDGER" --json "$ROOT/second.json" >/dev/null
after=$(cksum "$LEDGER")
if [[ "$before" == "$after" ]]; then
  ok "ledger bytes unchanged"
else
  bad "ledger bytes changed"
fi
porcelain=$(gitc git -C "$REPO" status --porcelain)
if [[ -z "$porcelain" ]]; then
  ok "fixture repo stays clean"
else
  bad "fixture repo dirty: $porcelain"
fi

write_tiny() {
  local dest="$1" status="$2" proof="$3" num="$4"
  {
    printf '## %s · 2026-10-25 · tiny\n' "$(lid "$num")"
    if [[ -n "$status" ]]; then
      printf '**Status:** %s\n' "$status"
    fi
    if [[ -n "$proof" ]]; then
      printf '**Proof:** %s\n' "$proof"
    fi
    printf '**Tags:** #fixture\n'
  } > "$dest"
}

run_sensor() {
  local ledger="$1"
  shift
  RUN_OUT="$ROOT/run.out"
  RUN_ERR="$ROOT/run.err"
  RUN_JSON="$ROOT/run.json"
  node "$SENSOR" --repo "$REPO" --ledger "$ledger" --json "$RUN_JSON" "$@" >"$RUN_OUT" 2>"$RUN_ERR"
  rc=$?
}

echo "# exit contract"
HELP_OUT="$ROOT/help.out"
node "$SENSOR" --help >"$HELP_OUT" 2>"$ROOT/help.err"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -F 'Unknown is not proven' "$HELP_OUT" >/dev/null; then
  ok "help exits 0"
else
  bad "help rc=$rc"
fi
node "$SENSOR" --definitely-not-a-flag >"$ROOT/flag.out" 2>"$ROOT/flag.err"
rc=$?
if [[ "$rc" -eq 2 ]] && grep -F 'unknown flag:' "$ROOT/flag.err" >/dev/null; then
  ok "unknown flag exits 2"
else
  bad "unknown flag rc=$rc ($(cat "$ROOT/flag.err"))"
fi
node "$SENSOR" --ledger >"$ROOT/miss.out" 2>"$ROOT/miss.err"
rc=$?
if [[ "$rc" -eq 2 ]] && grep -F 'requires a value' "$ROOT/miss.err" >/dev/null; then
  ok "missing value exits 2"
else
  bad "missing value rc=$rc ($(cat "$ROOT/miss.err"))"
fi

node "$SENSOR" --ledger "$ROOT/no-such.md" --repo "$REPO" >"$ROOT/gone.out" 2>"$ROOT/gone.err"
rc=$?
if [[ "$rc" -eq 1 ]] && grep -F 'run incomplete reason=ledger-missing' "$ROOT/gone.out" >/dev/null \
  && ! grep -F 'verdict=proven' "$ROOT/gone.out" >/dev/null; then
  ok "missing ledger is incomplete"
else
  bad "missing ledger rc=$rc ($(cat "$ROOT/gone.out"))"
fi
ln -s "$LEDGER" "$ROOT/link.md"
node "$SENSOR" --ledger "$ROOT/link.md" --repo "$REPO" >"$ROOT/link.out" 2>"$ROOT/link.err"
rc=$?
if [[ "$rc" -eq 1 ]] && grep -F 'reason=ledger-symlink' "$ROOT/link.out" >/dev/null; then
  ok "symlink ledger is incomplete"
else
  bad "symlink ledger rc=$rc ($(cat "$ROOT/link.out"))"
fi
mkdir -p "$ROOT/ledger-dir"
node "$SENSOR" --ledger "$ROOT/ledger-dir" --repo "$REPO" >"$ROOT/dir.out" 2>"$ROOT/dir.err"
rc=$?
if [[ "$rc" -eq 1 ]] && grep -F 'reason=ledger-not-a-file' "$ROOT/dir.out" >/dev/null; then
  ok "directory ledger is incomplete"
else
  bad "directory ledger rc=$rc"
fi

TINY="$ROOT/tiny.md"
write_tiny "$TINY" "fixed" "" 801
node "$SENSOR" --ledger "$TINY" --repo "$REPO" --json "$ROOT/no-dir/out.json" >"$ROOT/jsondir.out" 2>"$ROOT/jsondir.err"
rc=$?
if [[ "$rc" -eq 1 ]] && grep -F 'json directory missing' "$ROOT/jsondir.err" >/dev/null; then
  ok "missing json directory exits 1"
else
  bad "missing json directory rc=$rc ($(cat "$ROOT/jsondir.err"))"
fi
node "$SENSOR" --ledger "$TINY" --repo "$REPO" >"$ROOT/inline.out" 2>"$ROOT/inline.err"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -F 'gibson.lesson-proof.report.v1' "$ROOT/inline.out" >/dev/null \
  && grep -F 'lesson-proof: report-only' "$ROOT/inline.out" >/dev/null; then
  ok "omitted json path appends json"
else
  bad "inline json rc=$rc"
fi

SUMMARY="$ROOT/summary.md"
: > "$SUMMARY"
GITHUB_ACTIONS=1 GITHUB_STEP_SUMMARY="$SUMMARY" \
  node "$SENSOR" --ledger "$TINY" --repo "$REPO" >"$ROOT/note.out" 2>"$ROOT/note.err"
if grep -F '::notice::' "$ROOT/note.out" >/dev/null \
  && grep -F 'does not block merges' "$SUMMARY" >/dev/null \
  && grep -F 'not enabled' "$SUMMARY" >/dev/null; then
  ok "actions note is advisory"
else
  bad "actions note missing"
fi

write_tiny "$ROOT/unknown-only.md" "fixed" "unknown" 802
run_sensor "$ROOT/unknown-only.md" --strict
if [[ "$rc" -eq 1 ]]; then
  ok "strict unknown exits 1"
else
  bad "strict unknown rc=$rc"
fi
run_sensor "$ROOT/unknown-only.md"
if [[ "$rc" -eq 0 ]]; then
  ok "default unknown exits 0"
else
  bad "default unknown rc=$rc"
fi

{
  printf '## %s · 2026-10-25 · proven\n' "$(lid 803)"
  printf '**Status:** fixed\n'
  printf '**Proof:** %s gates/enforcing.sh tree-good\n' "$SHA"
  printf '**Tags:** #fixture\n\n'
  printf '## %s · 2026-10-25 · open\n' "$(lid 804)"
  printf '**Status:** fix-pending\n'
  printf '**Tags:** #fixture\n'
} > "$ROOT/all-proven.md"
run_sensor "$ROOT/all-proven.md" --strict
if [[ "$rc" -eq 0 && "$(header_field "$RUN_JSON" mode)" == "report-only" \
   && "$(get_field "$RUN_JSON" "$(lid 803)" verdict)" == "proven" ]]; then
  ok "strict passes when every closure is proven"
else
  bad "strict all-proven rc=$rc"
fi

mkdir -p "$ROOT/notgit"
write_tiny "$ROOT/notgit-ledger.md" "fixed" "$SHA gates/enforcing.sh tree-good" 805
node "$SENSOR" --repo "$ROOT/notgit" --ledger "$ROOT/notgit-ledger.md" --json "$ROOT/notgit.json" >"$ROOT/notgit.out" 2>"$ROOT/notgit.err"
rc=$?
if [[ "$rc" -eq 0 && "$(get_field "$ROOT/notgit.json" "$(lid 805)" verdict)" == "unknown" \
   && "$(get_field "$ROOT/notgit.json" "$(lid 805)" reason)" == "repo-not-git" ]]; then
  ok "non-git repo is unknown"
else
  bad "non-git repo rc=$rc reason=$(get_field "$ROOT/notgit.json" "$(lid 805)" reason)"
fi

echo "# mutations"
restore_sensor() {
  cp "$SENSOR_BAK" "$SENSOR"
}

mutate_verdict() {
  local token="$1" replacement="$2" ledger="$3" num="$4" green="$5" label="$6"
  node "$MUTATE" "$SENSOR" "$token" "$replacement"
  if node --check "$SENSOR"; then
    ok "$label mutated file parses"
  else
    bad "$label mutated file does not parse"
    restore_sensor
    return
  fi
  run_sensor "$ledger"
  local got
  got=$(get_field "$RUN_JSON" "$(lid "$num")" verdict)
  if [[ "$got" == "$green" ]]; then
    bad "$label mutation stayed $green"
  else
    ok "RED $label verdict=$got"
  fi
  restore_sensor
  if node --check "$SENSOR"; then
    ok "$label restored file parses"
  else
    bad "$label restored file does not parse"
  fi
  run_sensor "$ledger"
  got=$(get_field "$RUN_JSON" "$(lid "$num")" verdict)
  if [[ "$got" == "$green" ]]; then
    ok "GREEN $label verdict=$got"
  else
    bad "$label restore verdict=$got"
  fi
}

mutate_exit() {
  local token="$1" replacement="$2" ledger="$3" green_rc="$4" label="$5"
  shift 5
  node "$MUTATE" "$SENSOR" "$token" "$replacement"
  if node --check "$SENSOR"; then
    ok "$label mutated file parses"
  else
    bad "$label mutated file does not parse"
    restore_sensor
    return
  fi
  run_sensor "$ledger" "$@"
  if [[ "$rc" -eq "$green_rc" ]]; then
    bad "$label mutation stayed rc=$rc"
  else
    ok "RED $label rc=$rc"
  fi
  restore_sensor
  if node --check "$SENSOR"; then
    ok "$label restored file parses"
  else
    bad "$label restored file does not parse"
  fi
  run_sensor "$ledger" "$@"
  if [[ "$rc" -eq "$green_rc" ]]; then
    ok "GREEN $label rc=$rc"
  else
    bad "$label restore rc=$rc"
  fi
}

write_tiny "$ROOT/m-absent.md" "fixed" "" 811
write_tiny "$ROOT/m-unknown.md" "fixed" "unknown" 812
write_tiny "$ROOT/m-malformed.md" "fixed" "not-a-proof" 813
write_tiny "$ROOT/m-bad.md" "fixed" "$SHA gates/noop.sh tree-good" 814
write_tiny "$ROOT/m-disarm.md" "fixed" "$SHA gates/disarm-unused.sh tree-good" 815
write_tiny "$ROOT/m-valid.md" "fixed" "$SHA gates/rejects-all.sh tree-good" 816
write_tiny "$ROOT/m-risk.md" "wontfix" "$SHA gates/enforcing.sh tree-good" 817

mutate_verdict MUTATION_PROOF_ABSENT '  return "proven"; // MUTATION_PROOF_ABSENT' \
  "$ROOT/m-absent.md" 811 unproven "proof absent"
mutate_verdict MUTATION_PROOF_UNKNOWN '  return "proven"; // MUTATION_PROOF_UNKNOWN' \
  "$ROOT/m-unknown.md" 812 unknown "proof unknown"
mutate_verdict MUTATION_PROOF_MALFORMED '  return "proven"; // MUTATION_PROOF_MALFORMED' \
  "$ROOT/m-malformed.md" 813 unproven "proof malformed"
mutate_verdict MUTATION_BAD_PASSED '  return "proven"; // MUTATION_BAD_PASSED' \
  "$ROOT/m-bad.md" 814 unproven "bad fixture passed"
mutate_verdict MUTATION_DISARM_STILL_FAILS '  return "proven"; // MUTATION_DISARM_STILL_FAILS' \
  "$ROOT/m-disarm.md" 815 unproven "disarm still fails"
mutate_verdict MUTATION_VALID_FAILED '  return "proven"; // MUTATION_VALID_FAILED' \
  "$ROOT/m-valid.md" 816 unproven "valid fixture failed"
mutate_verdict MUTATION_ACCEPTED_RISK '  return "proven"; // MUTATION_ACCEPTED_RISK' \
  "$ROOT/m-risk.md" 817 unknown "accepted risk"
mutate_exit MUTATION_STRICT '  return false; // MUTATION_STRICT' \
  "$ROOT/m-absent.md" 1 "strict" --strict
mutate_exit MUTATION_REPORT_ONLY '  return false; // MUTATION_REPORT_ONLY' \
  "$ROOT/m-absent.md" 0 "report only"

if cmp -s "$SENSOR" "$SENSOR_BAK"; then
  ok "sensor restored after mutations"
else
  bad "sensor differs from backup after mutations"
  restore_sensor
fi

echo "# live ledger"
LIVE_JSON="$ROOT/live.json"
LIVE_OUT="$ROOT/live.out"
node "$SENSOR" --json "$LIVE_JSON" >"$LIVE_OUT" 2>"$ROOT/live.err"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -F 'lesson-proof: unknown is not proven' "$LIVE_OUT" >/dev/null; then
  ok "live report-only exits 0"
else
  bad "live report rc=$rc"
fi
LIVE_SUM="$ROOT/live.sum"
if node "$INSPECT" live "$LIVE_JSON" "$REPO_ROOT/memory/LESSONS.md" >"$LIVE_SUM" 2>"$ROOT/live-shape.err"; then
  ok "live ledger shape"
  cat "$LIVE_SUM"
else
  bad "live ledger shape ($(cat "$ROOT/live-shape.err"))"
  cat "$LIVE_SUM"
fi
strict_expect=$(grep -F 'strict-expect=' "$LIVE_SUM" || true)
node "$SENSOR" --strict --json "$ROOT/live-strict.json" >"$ROOT/live-strict.out" 2>"$ROOT/live-strict.err"
rc=$?
if [[ "$strict_expect" == "strict-expect=1" && "$rc" -eq 1 ]]; then
  ok "live strict exits 1 while a closure is not proven"
elif [[ "$strict_expect" == "strict-expect=0" && "$rc" -eq 0 ]]; then
  ok "live strict exits 0 when every closure is proven"
else
  bad "live strict rc=$rc expect=$strict_expect"
fi
if [[ "$(header_field "$ROOT/live-strict.json" mode)" == "report-only" ]]; then
  ok "strict live report stays report-only"
else
  bad "strict live mode changed"
fi

echo "# workflow and doc"
if grep -F 'node scripts/lesson-proof.mjs' "$WF" >/dev/null; then
  ok "workflow invokes the checker"
else
  bad "workflow does not invoke the checker"
fi
if grep -F -- '--strict' "$WF" >/dev/null; then
  bad "workflow passes --strict"
else
  ok "workflow does not pass --strict"
fi
if grep -F 'contents: read' "$WF" >/dev/null && grep -F 'cancel-in-progress: true' "$WF" >/dev/null \
  && grep -F 'fetch-depth: 0' "$WF" >/dev/null; then
  ok "workflow is read-only and cancels stale runs"
else
  bad "workflow permissions or concurrency"
fi
if grep -F 'issues: write' "$WF" >/dev/null || grep -F 'pull_request_target' "$WF" >/dev/null \
  || grep -F 'continue-on-error' "$WF" >/dev/null; then
  bad "workflow has a blocking or write permission"
else
  ok "workflow does not write or continue on error"
fi
if grep -F '**Authority:** Non-normative' "$DOC" >/dev/null \
  && grep -F '2 percent' "$DOC" >/dev/null \
  && grep -F '30 consecutive' "$DOC" >/dev/null \
  && grep -F 'repository owner of The-AIE/the-gibson' "$DOC" >/dev/null \
  && grep -F 'not implemented' "$DOC" >/dev/null \
  && grep -F 'does not block a merge' "$DOC" >/dev/null; then
  ok "doc states the promotion bar and the advisory limit"
else
  bad "doc is missing a promotion or authority line"
fi

echo "lesson-proof.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
