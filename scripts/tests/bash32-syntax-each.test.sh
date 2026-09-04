#!/usr/bin/env bash
# bash32-syntax-each.test.sh — every-file Bash 3.2 syntax rail (#300)
#
# Ordinary path: private fixtures + fake parser. No Docker, network, GitHub,
# or nested run-all. Supplementary Darwin/Docker arms emit the exact
# unavailable note and add nothing to pass/fail/skip/todo/quarantine tallies.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
HELPER="$SCRIPT_DIR/lib/bash32-syntax-each.sh"
RUN_ALL="$SCRIPT_DIR/run-all.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-300-bash32.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

FAKE="$ROOT/fake-parser"
FAKE_LOG="$ROOT/fake.log"
FAKE_FAILS="$ROOT/fake.fails"
FAKE_EXEC_MARK="$ROOT/fake.exec"
export FAKE_LOG FAKE_FAILS FAKE_EXEC_MARK

H_RC=0
H_OUT=""
H_ERR=""

run_helper() {
  H_OUT=$(bash "$HELPER" "$@" 2>"$ROOT/h.err")
  H_RC=$?
  H_ERR=$(cat "$ROOT/h.err")
}

run_helper_u() {
  H_OUT=$(/bin/bash -u "$HELPER" "$@" 2>"$ROOT/h.err")
  H_RC=$?
  H_ERR=$(cat "$ROOT/h.err")
}

reset_fake() {
  : > "$FAKE_LOG"
  : > "$FAKE_FAILS"
  rm -f "$FAKE_EXEC_MARK"
}

expect_rc() {
  if [ "$H_RC" -eq "$1" ]; then
    ok "$2"
  else
    bad "$2 (rc=$H_RC want $1)"
  fi
}

expect_no_receipt() {
  if printf '%s\n' "$H_OUT" | grep 'GIBSON_BASH32_SYNTAX' >/dev/null; then
    bad "$1 emitted a syntax receipt"
  else
    ok "$1 emitted no syntax receipt"
  fi
}

expect_named() {
  if printf '%s\n' "$H_ERR" | grep -F "$1" >/dev/null; then
    ok "$2"
  else
    bad "$2 (missing path $1)"
  fi
}

expect_not_named() {
  if printf '%s\n' "$H_ERR" | grep -F "$1" >/dev/null; then
    bad "$2 (unexpected path $1)"
  else
    ok "$2"
  fi
}

call_count() {
  if [ -f "$FAKE_LOG" ]; then
    wc -l < "$FAKE_LOG" | tr -d ' '
  else
    printf '%s' 0
  fi
}

hex64() {
  printf '%s' "$1" | grep -E '^[0-9a-f]{64}$' >/dev/null
}

paths_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

is_nonneg_int() {
  case "$1" in
    0) return 0 ;;
    ''|*[!0-9]*) return 1 ;;
    0*) return 1 ;;
    *) return 0 ;;
  esac
}

is_canonical_pos_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0*) return 1 ;;
    *) return 0 ;;
  esac
}

median3() {
  printf '%s\n' "$1" "$2" "$3" | sort -n | sed -n '2p'
}

# Fail-closed hosted-benchmark control (C8/C9).
# $1 = runner function name taking baseline|candidate
#      success: stdout is a non-negative millisecond integer, exit 0
#      failure: nonzero exit; stdout is ignored and must not become a sample
# $2 = paths_sha256  $3 = discovered n
# One warmup each, then three alternating measured samples.
# Canonical positive count and 64-lowercase-hex digest bind before any
# GIBSON_BASH32_BENCH token is written. The sole success receipt is emitted
# only after every warmup and sample succeeded, every sample and median is a
# non-negative integer, and candidate-minus-baseline median is at most 5000.
# Malformed evidence, command failure, bad samples, or over-budget delta
# return 1 with BENCH_FAIL_REASON and emit no receipt or lookalike.
BENCH_FAIL_REASON=""
BENCH_DELTA=""
BENCH_BASELINE=""
BENCH_CANDIDATE=""

run_fail_closed_bench() {
  BENCH_FAIL_REASON=""
  BENCH_DELTA=""
  BENCH_BASELINE=""
  BENCH_CANDIDATE=""
  _br=$1
  _bh=$2
  _bn=$3

  if ! hex64 "$_bh"; then
    BENCH_FAIL_REASON="malformed paths_sha256 digest"
    return 1
  fi
  if ! is_canonical_pos_int "$_bn"; then
    BENCH_FAIL_REASON="noncanonical discovered count"
    return 1
  fi

  if ! "$_br" baseline >/dev/null; then
    BENCH_FAIL_REASON="warmup baseline command failed"
    return 1
  fi
  if ! "$_br" candidate >/dev/null; then
    BENCH_FAIL_REASON="warmup candidate command failed"
    return 1
  fi

  _bb1=$("$_br" baseline) || { BENCH_FAIL_REASON="sample baseline 1 command failed"; return 1; }
  _bc1=$("$_br" candidate) || { BENCH_FAIL_REASON="sample candidate 1 command failed"; return 1; }
  _bb2=$("$_br" baseline) || { BENCH_FAIL_REASON="sample baseline 2 command failed"; return 1; }
  _bc2=$("$_br" candidate) || { BENCH_FAIL_REASON="sample candidate 2 command failed"; return 1; }
  _bb3=$("$_br" baseline) || { BENCH_FAIL_REASON="sample baseline 3 command failed"; return 1; }
  _bc3=$("$_br" candidate) || { BENCH_FAIL_REASON="sample candidate 3 command failed"; return 1; }

  if ! is_nonneg_int "$_bb1" || ! is_nonneg_int "$_bc1" \
     || ! is_nonneg_int "$_bb2" || ! is_nonneg_int "$_bc2" \
     || ! is_nonneg_int "$_bb3" || ! is_nonneg_int "$_bc3"; then
    BENCH_FAIL_REASON="non-integer or empty sample"
    return 1
  fi

  BENCH_BASELINE=$(median3 "$_bb1" "$_bb2" "$_bb3")
  BENCH_CANDIDATE=$(median3 "$_bc1" "$_bc2" "$_bc3")
  if ! is_nonneg_int "$BENCH_BASELINE" || ! is_nonneg_int "$BENCH_CANDIDATE"; then
    BENCH_FAIL_REASON="median was not a non-negative integer"
    return 1
  fi
  BENCH_DELTA=$((BENCH_CANDIDATE - BENCH_BASELINE))
  if [ "$BENCH_DELTA" -gt 5000 ]; then
    BENCH_FAIL_REASON="over-budget delta_ms=${BENCH_DELTA}"
    return 1
  fi
  echo "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=${BENCH_BASELINE} candidate_median_ms=${BENCH_CANDIDATE} delta_ms=${BENCH_DELTA} paths_sha256=${_bh} status=pass"
  return 0
}

# Fake parser mimics bash -n: only the first path after -n is inspected.
cat > "$FAKE" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
if [ "$1" != "-n" ]; then
  if [ -n "${FAKE_EXEC_MARK:-}" ]; then
    echo executed >> "$FAKE_EXEC_MARK"
  fi
  exit 0
fi
if [ -n "${2:-}" ] && grep -Fxq -- "$2" "$FAKE_FAILS" 2>/dev/null; then
  echo "fake-parser: syntax error" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$FAKE"

VALID="$ROOT/valid.sh"
BAD="$ROOT/bad.sh"
VALID2="$ROOT/valid2.sh"
BAD2="$ROOT/bad2.sh"
printf '%s\n' '#!/bin/sh' 'true' > "$VALID"
printf '%s\n' '#!/bin/sh' 'true' > "$VALID2"
printf '%s\n' '#!/bin/sh' 'if then' > "$BAD"
printf '%s\n' '#!/bin/sh' 'if then' > "$BAD2"

write_semi() {
  _mark=${2:-$ROOT/t9.marker}
  cat > "$1" <<EOF
#!/usr/bin/env bash
echo executed > "$_mark"
x=x
case \$x in
  x) : ;&
  y) : ;;
esac
EOF
}
write_pipeor() {
  _mark=${2:-$ROOT/t9.marker}
  cat > "$1" <<EOF
#!/usr/bin/env bash
echo executed > "$_mark"
: |& :
EOF
}
write_caseand() {
  _mark=${2:-$ROOT/t9.marker}
  cat > "$1" <<EOF
#!/usr/bin/env bash
echo executed > "$_mark"
x=x
case \$x in
  x) : ;;&
  y) : ;;
esac
EOF
}

echo "T1 usage: empty argv / shell only / empty shell"
reset_fake
run_helper_u
expect_rc 2 "T1 no arguments exits 2"
if [ "$(call_count)" -eq 0 ]; then
  ok "T1 no arguments makes zero parser calls"
else
  bad "T1 no arguments made $(call_count) parser calls"
fi
if printf '%s\n' "$H_ERR" | grep 'unbound var' >/dev/null; then
  bad "T1 empty argv aborted under set -u"
else
  ok "T1 empty argv is usage 2 without a set -u abort"
fi
expect_no_receipt "T1 no arguments"

reset_fake
run_helper_u /bin/bash
expect_rc 2 "T1 shell only exits 2"
if [ "$(call_count)" -eq 0 ]; then
  ok "T1 shell only makes zero parser calls"
else
  bad "T1 shell only made $(call_count) parser calls"
fi

reset_fake
run_helper_u "" "$VALID"
expect_rc 2 "T1 empty shell exits 2"
if [ "$(call_count)" -eq 0 ]; then
  ok "T1 empty shell makes zero parser calls"
else
  bad "T1 empty shell made $(call_count) parser calls"
fi
expect_no_receipt "T1 empty shell"

echo "T2 two valid files"
reset_fake
run_helper "$FAKE" "$VALID" "$VALID2"
expect_rc 0 "T2 two valid files exit 0"
if [ "$(call_count)" -eq 2 ]; then
  ok "T2 made exactly two parser calls"
else
  bad "T2 made $(call_count) parser calls (want 2)"
fi
if grep -Fxq -- "-n $VALID" "$FAKE_LOG" && grep -Fxq -- "-n $VALID2" "$FAKE_LOG"; then
  ok "T2 recorded separate -n FILE calls in order"
else
  bad "T2 call log was not two separate -n FILE lines"
fi
head_line=$(sed -n '1p' "$FAKE_LOG")
tail_line=$(sed -n '2p' "$FAKE_LOG")
if [ "$head_line" = "-n $VALID" ] && [ "$tail_line" = "-n $VALID2" ]; then
  ok "T2 call order is first file then second"
else
  bad "T2 call order drifted"
fi
if [ -n "$H_OUT" ]; then
  bad "T2 helper wrote stdout on success"
else
  ok "T2 helper stdout is empty on success"
fi

echo "T3 valid first, universally invalid second"
reset_fake
printf '%s\n' "$BAD" > "$FAKE_FAILS"
run_helper "$FAKE" "$VALID" "$BAD"
expect_rc 1 "T3 valid then invalid exits 1"
expect_named "$BAD" "T3 names the invalid second path"
expect_not_named "$VALID" "T3 does not name the valid first path"
if printf '%s\n' "$H_ERR" | grep -F "fake-parser: syntax error" >/dev/null; then
  ok "T3 preserves parser stderr"
else
  bad "T3 dropped parser stderr"
fi
expect_no_receipt "T3"

echo "T4 universally invalid first, valid second"
reset_fake
printf '%s\n' "$BAD" > "$FAKE_FAILS"
run_helper "$FAKE" "$BAD" "$VALID"
expect_rc 1 "T4 invalid then valid exits 1"
if [ "$(call_count)" -eq 2 ]; then
  ok "T4 still checks both files"
else
  bad "T4 made $(call_count) parser calls (want 2)"
fi
expect_named "$BAD" "T4 names the invalid first path"
head_line=$(sed -n '1p' "$FAKE_LOG")
tail_line=$(sed -n '2p' "$FAKE_LOG")
if [ "$head_line" = "-n $BAD" ] && [ "$tail_line" = "-n $VALID" ]; then
  ok "T4 checks the valid second file after the failure"
else
  bad "T4 did not preserve call order across a failure"
fi

echo "T5 valid, invalid, valid"
reset_fake
printf '%s\n' "$BAD" > "$FAKE_FAILS"
run_helper "$FAKE" "$VALID" "$BAD" "$VALID2"
expect_rc 1 "T5 mixed triple exits 1"
if [ "$(call_count)" -eq 3 ]; then
  ok "T5 made exactly three parser calls"
else
  bad "T5 made $(call_count) parser calls (want 3)"
fi
line1=$(sed -n '1p' "$FAKE_LOG")
line2=$(sed -n '2p' "$FAKE_LOG")
line3=$(sed -n '3p' "$FAKE_LOG")
if [ "$line1" = "-n $VALID" ] && [ "$line2" = "-n $BAD" ] && [ "$line3" = "-n $VALID2" ]; then
  ok "T5 recorded three ordered -n FILE calls"
else
  bad "T5 call order drifted"
fi
expect_named "$BAD" "T5 names the invalid middle path"

echo "T6 missing / non-regular path"
reset_fake
run_helper "$FAKE" "$VALID" "$ROOT/missing.sh"
expect_rc 2 "T6 missing path exits 2"
if [ "$(call_count)" -eq 0 ]; then
  ok "T6 missing path makes zero parser calls"
else
  bad "T6 missing path made $(call_count) parser calls"
fi
expect_no_receipt "T6 missing path"

mkdir -p "$ROOT/not-a-file"
reset_fake
run_helper "$FAKE" "$VALID" "$ROOT/not-a-file"
expect_rc 2 "T6 directory path exits 2"
if [ "$(call_count)" -eq 0 ]; then
  ok "T6 directory path makes zero parser calls"
else
  bad "T6 directory path made $(call_count) parser calls"
fi
expect_no_receipt "T6 directory path"

echo "T7 missing / non-executable parser"
reset_fake
run_helper "$ROOT/no-such-parser" "$VALID"
expect_rc 2 "T7 missing parser exits 2"
if [ "$(call_count)" -eq 0 ]; then
  ok "T7 missing parser makes zero parser calls"
else
  bad "T7 missing parser made $(call_count) parser calls"
fi
expect_no_receipt "T7 missing parser"

printf '%s\n' '#!/bin/sh' 'exit 0' > "$ROOT/noexec-parser"
chmod a-x "$ROOT/noexec-parser"
reset_fake
run_helper "$ROOT/noexec-parser" "$VALID"
expect_rc 2 "T7 non-executable parser exits 2"
if [ "$(call_count)" -eq 0 ]; then
  ok "T7 non-executable parser makes zero parser calls"
else
  bad "T7 non-executable parser made $(call_count) parser calls"
fi
expect_no_receipt "T7 non-executable parser"

echo "T8 observable side effect is absent"
SIDE="$ROOT/side.sh"
MARKER="$ROOT/side.marker"
printf '%s\n' "echo executed > \"$MARKER\"" > "$SIDE"
rm -f "$MARKER"
run_helper /bin/bash "$SIDE"
expect_rc 0 "T8 side-effect fixture exits 0"
if [ -e "$MARKER" ]; then
  bad "T8 executed the fixture (marker present)"
else
  ok "T8 side-effect marker is absent"
fi

echo "T12 fake parser fails two nonadjacent paths"
reset_fake
printf '%s\n' "$BAD" "$BAD2" > "$FAKE_FAILS"
run_helper "$FAKE" "$BAD" "$VALID" "$BAD2" "$VALID2"
expect_rc 1 "T12 two nonadjacent failures exit 1"
if [ "$(call_count)" -eq 4 ]; then
  ok "T12 observed all four parser calls"
else
  bad "T12 made $(call_count) parser calls (want 4)"
fi
expect_named "$BAD" "T12 names the first failing path"
expect_named "$BAD2" "T12 names the second failing path"
if printf '%s\n' "$H_ERR" | grep -c -F "fake-parser: syntax error" | grep -x 2 >/dev/null; then
  ok "T12 preserves both parser stderr messages"
else
  bad "T12 dropped a parser stderr message"
fi

echo "unpatched batched false-green (universally invalid later file)"
/bin/bash -n "$VALID" "$BAD" >/dev/null 2>&1
batch_rc=$?
/bin/bash -n "$BAD" >/dev/null 2>&1
direct_rc=$?
if [ "$batch_rc" -eq 0 ]; then
  ok "unpatched bash -n valid later-invalid is false-green 0"
else
  bad "unpatched batched command rc=$batch_rc (want 0)"
fi
if [ "$direct_rc" -ne 0 ]; then
  ok "direct /bin/bash -n of the later invalid file is red $direct_rc"
else
  bad "direct /bin/bash -n of the later invalid file was green"
fi
run_helper /bin/bash "$VALID" "$BAD"
expect_rc 1 "candidate helper rejects valid then universally invalid"
expect_named "$BAD" "candidate helper names the later universally invalid path"

echo "production seam wiring"
if grep -Fq 'scripts/tests/lib/bash32-syntax-each.sh' "$RUN_ALL"; then
  ok "run-all.sh invokes the helper"
else
  bad "run-all.sh does not name the helper"
fi
if grep -Fq 'GIBSON_BASH32_SYNTAX schema=gibson.bash32-syntax/v1' "$RUN_ALL"; then
  ok "run-all.sh emits the v1 syntax receipt schema"
else
  bad "run-all.sh is missing the v1 syntax receipt"
fi
if grep -Fq 'ok${OFF}   — parses under bash 3.2' "$RUN_ALL" \
  || grep -F 'parses under bash 3.2' "$RUN_ALL" >/dev/null; then
  bad "run-all.sh still prints the old fixed bash 3.2 ok text"
else
  ok "run-all.sh no longer prints the old fixed bash 3.2 ok text"
fi
if grep -Fq 'run_limited docker run --rm -v "$REPO_ROOT:/w" -w /w bash:3.2' "$RUN_ALL"; then
  ok "run-all.sh keeps one-container docker run_limited mount/workdir/image"
else
  bad "run-all.sh lost the one-container docker shape"
fi
if grep -E 'bash[[:space:]]+scripts/tests/lib/bash32-syntax-each\.sh[[:space:]]+bash[[:space:]]+\$SH_FILES' "$RUN_ALL" >/dev/null; then
  ok "run-all.sh passes parser bash and complete SH_FILES to the helper"
else
  bad "run-all.sh does not pass parser bash plus SH_FILES to the helper"
fi
if grep -nE 'docker run' "$RUN_ALL" | grep 'bash -n \$SH_FILES' >/dev/null; then
  bad "run-all.sh still batches bash -n \$SH_FILES inside docker"
else
  ok "run-all.sh no longer batches bash -n \$SH_FILES inside docker"
fi
if grep -Fq 'for f in $SH_FILES; do' "$RUN_ALL" && grep -Fq 'bash -n "$f"' "$RUN_ALL"; then
  ok "modern-host per-file bash -n loop remains"
else
  bad "modern-host per-file bash -n loop is missing"
fi
if grep -Fq 'FAILED="$FAILED bash-3.2"' "$RUN_ALL"; then
  ok "run-all.sh still binds bash-3.2 into FAILED"
else
  bad "run-all.sh lost the bash-3.2 FAILED bind"
fi
if grep -Fq 'no usable docker; bash 3.2 unverified on this host' "$RUN_ALL"; then
  ok "run-all.sh keeps the no-docker local skip"
else
  bad "run-all.sh lost the no-docker local skip"
fi
if grep -Fq 'cs_bash4_hits' "$RUN_ALL"; then
  ok "Bash-4 grep sensor remains"
else
  bad "Bash-4 grep sensor is missing"
fi
if grep -Fq 'find scripts adapters -name '\''*.sh'\'' -type f | sort' "$RUN_ALL"; then
  ok "SH_FILES discovery glob is unchanged"
else
  bad "SH_FILES discovery glob drifted"
fi
if awk '
  /echo "== bash 3.2 \(stock macOS\)"/ { s=NR }
  s && /run_limited docker run/ { d=NR }
  s && /for f in \$SH_FILES/ { loop=NR }
  s && /echo "== bash-4 builtins/ { e=NR; exit }
  END { if (s && d && e && d > s && d < e && !loop) exit 0; exit 1 }
' "$RUN_ALL"; then
  ok "bash 3.2 rail uses one container, not a per-file docker loop"
else
  bad "bash 3.2 rail docker shape drifted into a per-file loop"
fi
if awk '
  /echo "== bash 3.2 \(stock macOS\)"/ { s=1 }
  s && /shellcheck disable=SC2086/ { d=NR }
  s && /bash scripts\/tests\/lib\/bash32-syntax-each.sh bash \$SH_FILES/ { c=NR }
  s && /echo "== bash-4 builtins/ { exit }
  END { if (d && c && c == d+2) exit 0; exit 1 }
' "$RUN_ALL"; then
  ok "narrow SC2086 exception remains on the docker argv expansion"
else
  bad "SC2086 exception is missing or no longer adjacent to the docker argv"
fi
if grep -Fq 'BASH32_DOCKER_USABLE=1' "$RUN_ALL" \
   && grep -Fq 'BASH32_PATHS_SHA256=$bash32_hash' "$RUN_ALL"; then
  ok "run-all.sh records preamble docker usability and syntax digest"
else
  bad "run-all.sh does not persist preamble docker usability and syntax digest"
fi
if grep -Fq 'gibson_forward_bash32_bench "$ec" "$BASH32_PATHS_SHA256" "$BASH32_DOCKER_USABLE"' "$RUN_ALL"; then
  ok "run-all.sh forwards the bench receipt through the production function"
else
  bad "run-all.sh does not call the production bench forwarder with capture vars"
fi
if awk '
  /out=\$\(cat "\$cap\.out"\); ec=\$\(cat "\$cap\.ec"\)/ { cap=NR }
  cap && /gibson_forward_bash32_bench "\$ec" "\$BASH32_PATHS_SHA256" "\$BASH32_DOCKER_USABLE"/ { fwd=NR }
  cap && /name" == "bash32-syntax-each.test.sh" && "\$ec" -eq 0 && -z "\$shell_diag"/ { guard=NR }
  /for suite in scripts\/tests\/\*\.test.sh/ { s=NR }
  END { if (s && cap && guard && fwd && s < cap && cap < guard && guard < fwd) exit 0; exit 1 }
' "$RUN_ALL"; then
  ok "bench forwarder runs after capture only for a nominally clean focused suite"
else
  bad "bench forwarder is not wired to the nominally-clean capture-to-top-level seam"
fi

if grep -E '^[^#]*(mapfile|readarray|declare[[:space:]]+-A|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|\$\{[A-Za-z_][A-Za-z0-9_]*\,\,|&>>)' "$HELPER"; then
  bad "helper uses a Bash-4-only construct"
else
  ok "helper has no Bash-4-only constructs"
fi

echo "M1-M7 mutation score"
BEGIN_MARK='# per-file parse (one -n invocation per path)'
END_MARK='# end per-file parse'
HELPER_HEAD=$ROOT/helper.head
HELPER_TAIL=$ROOT/helper.tail
begin_n=$(grep -n "^${BEGIN_MARK}\$" "$HELPER" | head -1 | cut -d: -f1)
end_n=$(grep -n "^${END_MARK}\$" "$HELPER" | head -1 | cut -d: -f1)
if [ -n "$begin_n" ] && [ -n "$end_n" ] && [ "$begin_n" -lt "$end_n" ]; then
  ok "helper parse region markers are present"
else
  bad "helper parse region markers are missing"
  begin_n=1
  end_n=1
fi
sed -n "1,${begin_n}p" "$HELPER" > "$HELPER_HEAD"
sed -n "${end_n},\$p" "$HELPER" > "$HELPER_TAIL"

splice_mutant() {
  cat "$HELPER_HEAD" "$1" "$HELPER_TAIL" > "$2"
}

mutant_syntax_ok() {
  if bash -n "$1" 2>"$ROOT/mut.n.err"; then
    ok "$2 is syntactically valid"
  else
    bad "$2 failed bash -n"
  fi
}

MUT_KILLED=0
MUT_SURVIVED=0
note_kill() {
  MUT_KILLED=$((MUT_KILLED + 1))
  ok "$1"
}
note_survive() {
  MUT_SURVIVED=$((MUT_SURVIVED + 1))
  bad "$1"
}

# M1: batch paths onto one <shell> -n "$@"
M1_BODY=$ROOT/m1.body
M1=$ROOT/m1.sh
cat > "$M1_BODY" <<'EOF'
status=0
"$parser" -n "$@" || status=1
exit "$status"
EOF
splice_mutant "$M1_BODY" "$M1"
mutant_syntax_ok "$M1" "M1"
if grep -Fq '"$parser" -n "$@"' "$M1"; then
  ok "M1 applied (batched -n \"\$@\")"
else
  bad "M1 did not apply"
fi
reset_fake
printf '%s\n' "$BAD" > "$FAKE_FAILS"
H_OUT=$(bash "$M1" "$FAKE" "$VALID" "$BAD" 2>"$ROOT/h.err")
H_RC=$?
H_ERR=$(cat "$ROOT/h.err")
if [ "$H_RC" -eq 0 ]; then
  note_kill "M1 killed T3 (batched -n false-green, rc=0)"
else
  note_survive "M1 survived T3 (rc=$H_RC, want 0 false-green)"
fi

# M2: parse only $1
M2_BODY=$ROOT/m2.body
M2=$ROOT/m2.sh
cat > "$M2_BODY" <<'EOF'
status=0
f=$1
err=$("$parser" -n "$f" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "bash32-syntax-each: $f" >&2
  if [ -n "$err" ]; then
    printf '%s\n' "$err" >&2
  fi
  status=1
fi
exit "$status"
EOF
splice_mutant "$M2_BODY" "$M2"
mutant_syntax_ok "$M2" "M2"
if grep -Fq 'f=$1' "$M2"; then
  ok "M2 applied (parse only \$1)"
else
  bad "M2 did not apply"
fi
reset_fake
printf '%s\n' "$BAD" > "$FAKE_FAILS"
H_OUT=$(bash "$M2" "$FAKE" "$VALID" "$BAD" 2>"$ROOT/h.err")
H_RC=$?
H_ERR=$(cat "$ROOT/h.err")
if [ "$H_RC" -eq 0 ]; then
  note_kill "M2 killed T3 (ignored later path, rc=0)"
else
  note_survive "M2 survived T3 (rc=$H_RC, want 0)"
fi

# M3: stop after the first successful file
M3_BODY=$ROOT/m3.body
M3=$ROOT/m3.sh
cat > "$M3_BODY" <<'EOF'
status=0
for f in "$@"; do
  err=$("$parser" -n "$f" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "bash32-syntax-each: $f" >&2
    if [ -n "$err" ]; then
      printf '%s\n' "$err" >&2
    fi
    status=1
  else
    break
  fi
done
exit "$status"
EOF
splice_mutant "$M3_BODY" "$M3"
mutant_syntax_ok "$M3" "M3"
if grep -Fq 'break' "$M3"; then
  ok "M3 applied (break after first success)"
else
  bad "M3 did not apply"
fi
reset_fake
printf '%s\n' "$BAD" > "$FAKE_FAILS"
H_OUT=$(bash "$M3" "$FAKE" "$VALID" "$BAD" "$VALID2" 2>"$ROOT/h.err")
H_RC=$?
H_ERR=$(cat "$ROOT/h.err")
if [ "$H_RC" -eq 0 ] && [ "$(call_count)" -eq 1 ]; then
  note_kill "M3 killed T3/T5 (stopped after first success)"
else
  note_survive "M3 survived T3/T5 (rc=$H_RC calls=$(call_count))"
fi

# M4: swallow parser nonzero with || true
M4_BODY=$ROOT/m4.body
M4=$ROOT/m4.sh
cat > "$M4_BODY" <<'EOF'
status=0
for f in "$@"; do
  err=$("$parser" -n "$f" 2>&1) || true
  rc=0
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "bash32-syntax-each: $f" >&2
    if [ -n "$err" ]; then
      printf '%s\n' "$err" >&2
    fi
    status=1
  fi
done
exit "$status"
EOF
splice_mutant "$M4_BODY" "$M4"
mutant_syntax_ok "$M4" "M4"
if grep -Fq '|| true' "$M4"; then
  ok "M4 applied (|| true swallow)"
else
  bad "M4 did not apply"
fi
reset_fake
printf '%s\n' "$BAD" > "$FAKE_FAILS"
H_OUT=$(bash "$M4" "$FAKE" "$VALID" "$BAD" 2>"$ROOT/h.err")
H_RC=$?
H_ERR=$(cat "$ROOT/h.err")
if [ "$H_RC" -eq 0 ]; then
  note_kill "M4 killed T3 (swallowed parser nonzero, rc=0)"
else
  note_survive "M4 survived T3 (rc=$H_RC, want 0)"
fi

# M5: stop after the first failure
M5_BODY=$ROOT/m5.body
M5=$ROOT/m5.sh
cat > "$M5_BODY" <<'EOF'
status=0
for f in "$@"; do
  err=$("$parser" -n "$f" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "bash32-syntax-each: $f" >&2
    if [ -n "$err" ]; then
      printf '%s\n' "$err" >&2
    fi
    status=1
    break
  fi
done
exit "$status"
EOF
splice_mutant "$M5_BODY" "$M5"
mutant_syntax_ok "$M5" "M5"
if grep -Fq 'break' "$M5"; then
  ok "M5 applied (break after first failure)"
else
  bad "M5 did not apply"
fi
reset_fake
printf '%s\n' "$BAD" > "$FAKE_FAILS"
H_OUT=$(bash "$M5" "$FAKE" "$BAD" "$VALID" 2>"$ROOT/h.err")
H_RC=$?
H_ERR=$(cat "$ROOT/h.err")
if [ "$(call_count)" -eq 1 ]; then
  note_kill "M5 killed T4 (stopped after first failure, calls=1)"
else
  note_survive "M5 survived T4 (calls=$(call_count), want 1)"
fi

# M6: execute the file instead of using -n
M6_BODY=$ROOT/m6.body
M6=$ROOT/m6.sh
cat > "$M6_BODY" <<'EOF'
status=0
for f in "$@"; do
  err=$("$parser" "$f" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "bash32-syntax-each: $f" >&2
    if [ -n "$err" ]; then
      printf '%s\n' "$err" >&2
    fi
    status=1
  fi
done
exit "$status"
EOF
splice_mutant "$M6_BODY" "$M6"
mutant_syntax_ok "$M6" "M6"
if grep -Fq '"$parser" "$f"' "$M6" && ! grep -Fq '"$parser" -n "$f"' "$M6"; then
  ok "M6 applied (execute without -n)"
else
  bad "M6 did not apply"
fi
rm -f "$MARKER"
H_OUT=$(bash "$M6" /bin/bash "$SIDE" 2>"$ROOT/h.err")
H_RC=$?
H_ERR=$(cat "$ROOT/h.err")
if [ -e "$MARKER" ]; then
  note_kill "M6 killed T8 (side-effect marker present)"
else
  note_survive "M6 survived T8 (marker absent)"
fi
rm -f "$MARKER"

# M7: omit a failed path from stderr
M7_BODY=$ROOT/m7.body
M7=$ROOT/m7.sh
cat > "$M7_BODY" <<'EOF'
status=0
for f in "$@"; do
  err=$("$parser" -n "$f" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -n "$err" ]; then
      printf '%s\n' "$err" >&2
    fi
    status=1
  fi
done
exit "$status"
EOF
splice_mutant "$M7_BODY" "$M7"
mutant_syntax_ok "$M7" "M7"
if grep -Fq 'fake-parser: syntax error' "$M7" 2>/dev/null; then
  bad "M7 helper body unexpectedly mentions the fake parser"
fi
if grep -Fq 'printf '\''%s\n'\'' "bash32-syntax-each: $f"' "$M7"; then
  bad "M7 did not omit the failed-path printf"
else
  ok "M7 applied (failed path omitted from stderr)"
fi
reset_fake
printf '%s\n' "$BAD" > "$FAKE_FAILS"
H_OUT=$(bash "$M7" "$FAKE" "$VALID" "$BAD" 2>"$ROOT/h.err")
H_RC=$?
H_ERR=$(cat "$ROOT/h.err")
if printf '%s\n' "$H_ERR" | grep -F "$BAD" >/dev/null; then
  note_survive "M7 survived T3 (failed path still named)"
else
  note_kill "M7 killed T3 (failed path omitted from stderr)"
fi

echo "mutation score: killed=$MUT_KILLED survived=$MUT_SURVIVED"
if [ "$MUT_KILLED" -eq 7 ] && [ "$MUT_SURVIVED" -eq 0 ]; then
  ok "M1-M7 all killed, zero survived"
else
  bad "mutation score killed=$MUT_KILLED survived=$MUT_SURVIVED (want 7/0)"
fi
rm -f "$M1" "$M2" "$M3" "$M4" "$M5" "$M6" "$M7" \
  "$M1_BODY" "$M2_BODY" "$M3_BODY" "$M4_BODY" "$M5_BODY" "$M6_BODY" "$M7_BODY"

echo "adversarial fail-closed benchmark control"
BENCH_FAKE="$ROOT/bench-cmd"
BENCH_FAKE_LOG="$ROOT/bench-cmd.log"
BENCH_FAKE_FAIL_AT="$ROOT/bench-cmd.fail-at"
export BENCH_FAKE_LOG BENCH_FAKE_FAIL_AT
cat > "$BENCH_FAKE" <<'EOF'
#!/bin/sh
n=0
if [ -f "$BENCH_FAKE_LOG" ]; then
  n=$(wc -l < "$BENCH_FAKE_LOG" | tr -d ' ')
fi
n=$((n + 1))
echo "$1" >> "$BENCH_FAKE_LOG"
echo 10
fail_at=0
if [ -f "$BENCH_FAKE_FAIL_AT" ]; then
  fail_at=$(cat "$BENCH_FAKE_FAIL_AT")
fi
if [ "$fail_at" -gt 0 ] && [ "$n" -ge "$fail_at" ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$BENCH_FAKE"

bench_fake_runner() {
  "$BENCH_FAKE" "$1"
}

reset_bench_fake() {
  : > "$BENCH_FAKE_LOG"
  printf '%s\n' "${1:-0}" > "$BENCH_FAKE_FAIL_AT"
}

bench_fake_calls() {
  if [ -f "$BENCH_FAKE_LOG" ]; then
    wc -l < "$BENCH_FAKE_LOG" | tr -d ' '
  else
    printf '%s' 0
  fi
}

ADV_HASH=$(printf '%s\n' 'adv-bench' | paths_sha256 | tr 'A-F' 'a-f')
ADV_N=1

reset_bench_fake 0
run_fail_closed_bench bench_fake_runner "$ADV_HASH" "$ADV_N" >"$ROOT/adv.ok.out"
adv_rc=$?
if [ "$adv_rc" -eq 0 ] \
   && grep -Eq "^GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=10 delta_ms=0 paths_sha256=${ADV_HASH} status=pass\$" "$ROOT/adv.ok.out"; then
  ok "adversarial success seam emits one valid pass receipt"
else
  bad "adversarial success seam rc=$adv_rc"
fi
if [ "$(wc -l < "$ROOT/adv.ok.out" | tr -d ' ')" -eq 1 ]; then
  ok "adversarial success seam emits exactly one line"
else
  bad "adversarial success seam line count drifted"
fi
if [ "$(bench_fake_calls)" -eq 8 ]; then
  ok "adversarial success seam ran one warmup plus three alternating pairs"
else
  bad "adversarial success seam calls=$(bench_fake_calls) (want 8)"
fi

reset_bench_fake 1
run_fail_closed_bench bench_fake_runner "$ADV_HASH" "$ADV_N" >"$ROOT/adv.warmup.out"
adv_rc=$?
if [ "$adv_rc" -ne 0 ]; then
  ok "adversarial warmup failure does not pass the bench control"
else
  bad "adversarial warmup failure passed the bench control"
fi
if grep -q 'GIBSON_BASH32_BENCH' "$ROOT/adv.warmup.out"; then
  bad "adversarial warmup failure emitted a benchmark receipt"
else
  ok "adversarial warmup failure emitted no benchmark receipt"
fi
if [ "$(bench_fake_calls)" -eq 1 ]; then
  ok "adversarial warmup failure stops before measured samples"
else
  bad "adversarial warmup failure calls=$(bench_fake_calls) (want 1)"
fi
if [ -z "$BENCH_DELTA" ] && [ -z "$BENCH_BASELINE" ] && [ -z "$BENCH_CANDIDATE" ]; then
  ok "adversarial warmup failure leaves no stale timing values"
else
  bad "adversarial warmup failure leaked timing values"
fi

reset_bench_fake 3
run_fail_closed_bench bench_fake_runner "$ADV_HASH" "$ADV_N" >"$ROOT/adv.sample.out"
adv_rc=$?
if [ "$adv_rc" -ne 0 ]; then
  ok "adversarial first-sample failure does not pass the bench control"
else
  bad "adversarial first-sample failure passed the bench control"
fi
if grep -q 'GIBSON_BASH32_BENCH' "$ROOT/adv.sample.out"; then
  bad "adversarial first-sample failure emitted a benchmark receipt"
else
  ok "adversarial first-sample failure emitted no benchmark receipt"
fi
if [ "$(bench_fake_calls)" -eq 3 ]; then
  ok "adversarial first-sample failure does not continue after the failed command"
else
  bad "adversarial first-sample failure calls=$(bench_fake_calls) (want 3)"
fi
if [ -z "$BENCH_DELTA" ] && [ -z "$BENCH_BASELINE" ] && [ -z "$BENCH_CANDIDATE" ]; then
  ok "adversarial first-sample failure does not use partial timings"
else
  bad "adversarial first-sample failure leaked partial timings"
fi

reset_bench_fake 8
run_fail_closed_bench bench_fake_runner "$ADV_HASH" "$ADV_N" >"$ROOT/adv.last.out"
adv_rc=$?
if [ "$adv_rc" -ne 0 ]; then
  ok "adversarial last-sample failure does not pass the bench control"
else
  bad "adversarial last-sample failure passed the bench control"
fi
if grep -q 'GIBSON_BASH32_BENCH' "$ROOT/adv.last.out"; then
  bad "adversarial last-sample failure emitted a benchmark receipt"
else
  ok "adversarial last-sample failure emitted no benchmark receipt"
fi
if [ -z "$BENCH_DELTA" ] && [ -z "$BENCH_BASELINE" ] && [ -z "$BENCH_CANDIDATE" ]; then
  ok "adversarial last-sample failure does not keep a well-formed timing set"
else
  bad "adversarial last-sample failure leaked a complete-looking timing set"
fi

assert_bench_no_receipt() {
  _label=$1
  _rc=$2
  _out=$3
  _err=$4
  _hits=0
  if grep -q 'GIBSON_BASH32_BENCH' "$_out" "$_err" 2>/dev/null; then
    _hits=1
  fi
  if [ "$_rc" -ne 0 ] && [ "$_hits" -eq 0 ] && [ -n "$BENCH_FAIL_REASON" ]; then
    ok "adversarial $_label returns nonzero and emits no GIBSON_BASH32_BENCH"
  else
    bad "adversarial $_label rc=$_rc hits=$_hits reason=${BENCH_FAIL_REASON:-empty}"
  fi
}

run_bench_reject() {
  reset_bench_fake 0
  run_fail_closed_bench bench_fake_runner "$2" "$3" >"$ROOT/adv.reject.out" 2>"$ROOT/adv.reject.err"
  assert_bench_no_receipt "$1" "$?" "$ROOT/adv.reject.out" "$ROOT/adv.reject.err"
}

echo "adversarial malformed digest/count/sample/budget emit no receipt"
run_bench_reject "empty digest" "" "$ADV_N"
run_bench_reject "malformed digest" "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg" "$ADV_N"
ADV_HASH_UP=$(printf '%s' "$ADV_HASH" | tr 'a-f' 'A-F')
if [ "$ADV_HASH_UP" = "$ADV_HASH" ]; then
  ADV_HASH_UP=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
fi
run_bench_reject "uppercase digest" "$ADV_HASH_UP" "$ADV_N"
run_bench_reject "wrong-length digest" "${ADV_HASH%?}" "$ADV_N"
run_bench_reject "empty count" "$ADV_HASH" ""
run_bench_reject "zero count" "$ADV_HASH" "0"
run_bench_reject "nonnumeric count" "$ADV_HASH" "n"
run_bench_reject "signed count" "$ADV_HASH" "+1"
run_bench_reject "whitespace-padded count" "$ADV_HASH" " 1"
run_bench_reject "leading-zero count" "$ADV_HASH" "01"

bench_empty_sample_runner() {
  return 0
}
run_fail_closed_bench bench_empty_sample_runner "$ADV_HASH" "$ADV_N" >"$ROOT/adv.empty-sample.out" 2>"$ROOT/adv.empty-sample.err"
assert_bench_no_receipt "empty sample output" "$?" "$ROOT/adv.empty-sample.out" "$ROOT/adv.empty-sample.err"

bench_nonint_sample_runner() {
  echo 10.5
  return 0
}
run_fail_closed_bench bench_nonint_sample_runner "$ADV_HASH" "$ADV_N" >"$ROOT/adv.nonint.out" 2>"$ROOT/adv.nonint.err"
assert_bench_no_receipt "non-integer sample output" "$?" "$ROOT/adv.nonint.out" "$ROOT/adv.nonint.err"

bench_over_budget_runner() {
  case "$1" in
    baseline) echo 1 ;;
    *) echo 6001 ;;
  esac
  return 0
}
run_fail_closed_bench bench_over_budget_runner "$ADV_HASH" "$ADV_N" >"$ROOT/adv.budget.out" 2>"$ROOT/adv.budget.err"
assert_bench_no_receipt "over-budget candidate delta" "$?" "$ROOT/adv.budget.out" "$ROOT/adv.budget.err"

echo "production capture/forwarding seam"
FWD_BEGIN='# gibson_forward_bash32_bench begin'
FWD_END='# gibson_forward_bash32_bench end'
fwd_begin_n=$(grep -n "^${FWD_BEGIN}\$" "$RUN_ALL" | head -1 | cut -d: -f1)
fwd_end_n=$(grep -n "^${FWD_END}\$" "$RUN_ALL" | head -1 | cut -d: -f1)
FWD_SRC=$ROOT/fwd.prod.sh
if [ -n "$fwd_begin_n" ] && [ -n "$fwd_end_n" ] && [ "$fwd_begin_n" -lt "$fwd_end_n" ]; then
  ok "production forwarder markers are present once"
  sed -n "${fwd_begin_n},${fwd_end_n}p" "$RUN_ALL" > "$FWD_SRC"
else
  bad "production forwarder markers are missing"
  : > "$FWD_SRC"
fi
if grep -Eq '^gibson_forward_bash32_bench\(\) \{' "$FWD_SRC" \
   && [ "$(grep -c '^gibson_forward_bash32_bench()' "$RUN_ALL")" -eq 1 ]; then
  ok "extracted block is the sole production gibson_forward_bash32_bench"
else
  bad "extracted block is not the sole production forwarder"
fi
if grep -Eq '^gibson_forward_bash32_bench\(\)' "$SCRIPT_DIR/bash32-syntax-each.test.sh"; then
  bad "focused suite defines a duplicate forwarder"
else
  ok "focused suite does not define a duplicate forwarder"
fi
FWD_SRC_HASH=$(paths_sha256 < "$FWD_SRC")
FWD_REREAD=$ROOT/fwd.reread.sh
sed -n "${fwd_begin_n},${fwd_end_n}p" "$RUN_ALL" > "$FWD_REREAD"
FWD_REREAD_HASH=$(paths_sha256 < "$FWD_REREAD")
if [ -n "$FWD_SRC_HASH" ] && [ "$FWD_SRC_HASH" = "$FWD_REREAD_HASH" ]; then
  ok "sourced extract is the exact production marked region"
else
  bad "sourced extract is not the exact production marked region"
fi
if bash -n "$FWD_SRC" 2>/dev/null; then
  ok "extracted production forwarder is syntactically valid"
else
  bad "extracted production forwarder failed bash -n"
fi
# shellcheck disable=SC1090
. "$FWD_SRC"
if [ "$(type -t gibson_forward_bash32_bench 2>/dev/null)" = function ]; then
  ok "extracted production forwarder is callable"
else
  bad "extracted production forwarder did not define the function"
fi

SEAM_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WRONG_HASH=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SEAM_VALID="GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=12 delta_ms=2 paths_sha256=${SEAM_HASH} status=pass"
SEAM_CHATTER="  ok   — adversarial warmup failure emitted no GIBSON_BASH32_BENCH
bash32-syntax-each.test.sh: 10 passed, 0 failed"

run_fwd() {
  FWD_OUT=$(printf '%s\n' "$4" | gibson_forward_bash32_bench "$1" "$2" "$3" 2>"$ROOT/fwd.err")
  FWD_RC=$?
  FWD_ERR=$(cat "$ROOT/fwd.err")
}

assert_fwd_pass() {
  _label=$1
  _want=$2
  if [ "$FWD_RC" -eq 0 ] && [ "$FWD_OUT" = "$_want" ] && [ -z "$FWD_ERR" ]; then
    ok "seam $_label"
  else
    bad "seam $_label (rc=$FWD_RC out=$(printf '%s' "$FWD_OUT" | tr '\n' '|') err=$(printf '%s' "$FWD_ERR" | tr '\n' '|'))"
  fi
}

assert_fwd_fail() {
  _label=$1
  _hits=0
  if printf '%s\n' "$FWD_OUT" | grep 'GIBSON_BASH32_BENCH' >/dev/null; then
    _hits=1
  fi
  if [ "$FWD_RC" -ne 0 ] && [ -z "$FWD_OUT" ] && [ "$_hits" -eq 0 ]; then
    ok "seam $_label emits no green receipt"
  else
    bad "seam $_label rc=$FWD_RC hits=$_hits out=$(printf '%s' "$FWD_OUT" | tr '\n' '|')"
  fi
}

run_fwd 0 "$SEAM_HASH" 1 "${SEAM_CHATTER}
${SEAM_VALID}
${SEAM_CHATTER}"
assert_fwd_pass "valid-one forwards exactly one validated line" "$SEAM_VALID"
if [ "$(printf '%s\n' "$FWD_OUT" | wc -l | tr -d ' ')" -eq 1 ]; then
  ok "seam valid-one has one-line cardinality"
else
  bad "seam valid-one line count drifted"
fi
if printf '%s\n' "$FWD_OUT" | grep 'ok   —' >/dev/null; then
  bad "seam valid-one leaked assertion chatter"
else
  ok "seam valid-one does not expose assertion chatter"
fi

run_fwd 0 "$SEAM_HASH" 1 "$SEAM_CHATTER"
assert_fwd_fail "missing"

run_fwd 0 "$SEAM_HASH" 1 "${SEAM_VALID}
${SEAM_VALID}"
assert_fwd_fail "duplicate"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=12 delta_ms=2 paths_sha256=${SEAM_HASH} status=pass trailing"
assert_fwd_fail "malformed"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=12 delta_ms=2 paths_sha256=${WRONG_HASH} status=pass"
assert_fwd_fail "wrong digest"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=1 candidate_median_ms=6001 delta_ms=5001 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "over-budget"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH looks like a receipt but is not ${SEAM_HASH} status=pass"
assert_fwd_fail "lookalike-only"

run_fwd 1 "$SEAM_HASH" 1 "${SEAM_CHATTER}
${SEAM_VALID}"
assert_fwd_fail "failed-suite"

run_fwd 0 "$SEAM_HASH" 0 "$SEAM_CHATTER"
assert_fwd_pass "docker-unavailable missing is not required" ""

run_fwd 0 "$SEAM_HASH" 0 "$SEAM_VALID"
assert_fwd_pass "docker-unavailable does not forward a captured line" ""

SEAM_BOUND="GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=5010 delta_ms=5000 paths_sha256=${SEAM_HASH} status=pass"
run_fwd 0 "$SEAM_HASH" 1 "$SEAM_BOUND"
assert_fwd_pass "delta_ms 5000 is in budget" "$SEAM_BOUND"

SEAM_UNDER="GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=5009 delta_ms=4999 paths_sha256=${SEAM_HASH} status=pass"
run_fwd 0 "$SEAM_HASH" 1 "$SEAM_UNDER"
assert_fwd_pass "delta_ms 4999 is under budget" "$SEAM_UNDER"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=5011 delta_ms=5001 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "delta_ms 5001 is over budget"

SEAM_ZERO="GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=10 delta_ms=0 paths_sha256=${SEAM_HASH} status=pass"
run_fwd 0 "$SEAM_HASH" 1 "$SEAM_ZERO"
assert_fwd_pass "zero delta is in budget" "$SEAM_ZERO"

SEAM_NEG_BASE=12
SEAM_NEG_CAND=9
SEAM_NEG_DELTA=$((SEAM_NEG_CAND - SEAM_NEG_BASE))
if [ "$SEAM_NEG_DELTA" = "-3" ]; then
  ok "seam negative-delta fixture is exactly candidate minus baseline"
else
  bad "seam negative-delta fixture drifted (got $SEAM_NEG_DELTA want -3)"
fi
SEAM_NEG="GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=${SEAM_NEG_BASE} candidate_median_ms=${SEAM_NEG_CAND} delta_ms=${SEAM_NEG_DELTA} paths_sha256=${SEAM_HASH} status=pass"
run_fwd 0 "$SEAM_HASH" 1 "$SEAM_NEG"
assert_fwd_pass "negative delta under budget" "$SEAM_NEG"
if [ "$FWD_RC" -eq 0 ] && printf '%s\n' "$FWD_OUT" | grep -F "delta_ms=${SEAM_NEG_DELTA}" >/dev/null; then
  ok "seam negative-delta receipt preserves the exact recomputed relationship"
else
  bad "seam negative-delta receipt lost the exact recomputed relationship"
fi

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=10 delta_ms=5000 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "inconsistent 10/10/5000"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=12 delta_ms=5 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "inconsistent positive delta"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=12 candidate_median_ms=9 delta_ms=-1 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "inconsistent negative delta"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=12 delta_ms=3 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "over-reported delta"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=12 delta_ms=1 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "under-reported delta"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=12 candidate_median_ms=9 delta_ms=-4 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "over-reported negative delta"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=12 candidate_median_ms=9 delta_ms=-2 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "under-reported negative delta"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=1000000000000000000 candidate_median_ms=1000000000000000000 delta_ms=0 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "huge 19-digit baseline"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=1000000000000000000 delta_ms=999999999999999990 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "huge 19-digit candidate"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=10 delta_ms=1000000000000000000 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "huge 19-digit delta"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=10 delta_ms=999999999999999999999999999999 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "huge overflow-bait delta"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=010 candidate_median_ms=12 delta_ms=2 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "leading-zero baseline"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=012 delta_ms=2 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "leading-zero candidate"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=12 delta_ms=02 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "leading-zero delta"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=12 delta_ms=+2 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "plus-prefixed delta"

run_fwd 0 "$SEAM_HASH" 1 "GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 samples=3 baseline_median_ms=10 candidate_median_ms=12 delta_ms=-0 paths_sha256=${SEAM_HASH} status=pass"
assert_fwd_fail "negative-zero delta"

echo "production suite-loop diagnostic precedence"
DIAG_BEGIN='# gibson_suite_loop_diag begin'
DIAG_END='# gibson_suite_loop_diag end'
diag_begin_n=$(grep -n "^[[:space:]]*${DIAG_BEGIN}\$" "$RUN_ALL" | head -1 | cut -d: -f1)
diag_end_n=$(grep -n "^[[:space:]]*${DIAG_END}\$" "$RUN_ALL" | head -1 | cut -d: -f1)
DIAG_SRC=$ROOT/suite.loop.diag.sh
if [ -n "$diag_begin_n" ] && [ -n "$diag_end_n" ] && [ "$diag_begin_n" -lt "$diag_end_n" ]; then
  ok "production suite-loop diag markers are present once"
  {
    printf '%s\n' 'run_prod_suite_loop_diag() {'
    sed -n "${diag_begin_n},${diag_end_n}p" "$RUN_ALL"
    printf '%s\n' '}'
  } > "$DIAG_SRC"
else
  bad "production suite-loop diag markers are missing"
  printf '%s\n' 'run_prod_suite_loop_diag() { :; }' > "$DIAG_SRC"
fi
if [ "$(grep -c "^[[:space:]]*${DIAG_BEGIN}\$" "$RUN_ALL")" -eq 1 ] \
   && [ "$(grep -c "^[[:space:]]*${DIAG_END}\$" "$RUN_ALL")" -eq 1 ]; then
  ok "production suite-loop diag markers are unique"
else
  bad "production suite-loop diag markers are not unique"
fi
if grep -Fq 'gibson_forward_bash32_bench ' "$DIAG_SRC"; then
  sed 's/gibson_forward_bash32_bench /counted_gibson_forward_bash32_bench /' "$DIAG_SRC" > "$ROOT/suite.loop.diag.counted.sh"
  mv "$ROOT/suite.loop.diag.counted.sh" "$DIAG_SRC"
  ok "extracted suite-loop diag call is wrapped for call counting"
else
  bad "extracted suite-loop diag lost the production forwarder call"
fi
if bash -n "$DIAG_SRC" 2>/dev/null; then
  ok "extracted suite-loop diag wrapper is syntactically valid"
else
  bad "extracted suite-loop diag wrapper failed bash -n"
fi
counted_gibson_forward_bash32_bench() {
  printf '%s\n' called >> "$ROOT/fwd.calls"
  gibson_forward_bash32_bench "$@"
}
is_quarantined() { return 1; }
quarantine_issue() { printf '%s\n' ""; }
# shellcheck disable=SC1090
. "$DIAG_SRC"
if [ "$(type -t run_prod_suite_loop_diag 2>/dev/null)" = function ]; then
  ok "extracted suite-loop diag is callable"
else
  bad "extracted suite-loop diag did not define the wrapper"
fi

# Production suite-loop globals: consumed by the extracted run-all block.
# shellcheck disable=SC2034
run_loop_diag() {
  name="bash32-syntax-each.test.sh"
  ec=$1
  shell_diag=$2
  tally=$3
  out=$4
  suite_elapsed=7
  RED=""
  GRN=""
  YEL=""
  OFF=""
  FAILED=""
  ESCAPED=""
  QUARANTINED=""
  BASH32_PATHS_SHA256=$SEAM_HASH
  BASH32_DOCKER_USABLE=1
  : > "$ROOT/fwd.calls"
  run_prod_suite_loop_diag >"$ROOT/loop.out"
  LOOP_OUT=$(cat "$ROOT/loop.out")
}

fwd_call_count() {
  if [ -f "$ROOT/fwd.calls" ]; then
    wc -l < "$ROOT/fwd.calls" | tr -d ' '
  else
    printf '%s' 0
  fi
}

assert_loop_no_receipt() {
  _label=$1
  _needle=$2
  _want_calls=$3
  _unwanted=$4
  _hits=0
  _unwanted_hits=0
  if printf '%s\n' "$LOOP_OUT" | grep 'GIBSON_BASH32_BENCH' >/dev/null; then
    _hits=1
  fi
  if [ -n "$_unwanted" ] && printf '%s\n' "$LOOP_OUT" | grep "$_unwanted" >/dev/null; then
    _unwanted_hits=1
  fi
  _calls=$(fwd_call_count)
  if printf '%s\n' "$LOOP_OUT" | grep -F "$_needle" >/dev/null \
     && [ "$_calls" -eq "$_want_calls" ] \
     && [ "$_hits" -eq 0 ] \
     && [ "$_unwanted_hits" -eq 0 ] \
     && printf '%s' "$FAILED" | grep -F "$name" >/dev/null; then
    ok "loop-diag $_label"
  else
    bad "loop-diag $_label (calls=$_calls want=$_want_calls receipt=$_hits unwanted=$_unwanted_hits failed='$FAILED' out=$(printf '%s' "$LOOP_OUT" | tr '\n' '|'))"
  fi
}

run_loop_diag 124 "" "timed out after 30s" "${SEAM_CHATTER}
${SEAM_VALID}"
assert_loop_no_receipt "timeout 124 keeps timed-out tally" \
  "FAIL — bash32-syntax-each.test.sh: timed out after 30s (exit 124, 7s)" \
  0 "benchmark receipt missing or invalid"

run_loop_diag 0 "scripts/tests/bash32-syntax-each.test.sh: line 2: FOO: unbound variable" \
  "10 passed, 0 failed" "${SEAM_CHATTER}
${SEAM_VALID}
scripts/tests/bash32-syntax-each.test.sh: line 2: FOO: unbound variable"
assert_loop_no_receipt "shell diagnostic with exit 0 keeps shell-diag class" \
  "FAIL — bash32-syntax-each.test.sh: shell construction diagnostic with tally '10 passed, 0 failed' (exit 0, 7s)" \
  0 "benchmark receipt missing or invalid"

run_loop_diag 1 "" "3 passed, 1 failed" "${SEAM_CHATTER}
${SEAM_VALID}
  FAIL — planted assertion"
assert_loop_no_receipt "ordinary exit 1 keeps tally failure" \
  "FAIL — bash32-syntax-each.test.sh: 3 passed, 1 failed (exit 1, 7s)" \
  0 "benchmark receipt missing or invalid"

run_loop_diag 0 "" "10 passed, 0 failed" "$SEAM_CHATTER"
assert_loop_no_receipt "clean exit 0 with missing receipt fails closed" \
  "FAIL — bash32-syntax-each.test.sh: bash 3.2 benchmark receipt missing or invalid (exit 0, 7s)" \
  1 "shell construction diagnostic"

run_loop_diag 0 "" "10 passed, 0 failed" "${SEAM_CHATTER}
${SEAM_VALID}"
_calls=$(fwd_call_count)
_hits=0
if printf '%s\n' "$LOOP_OUT" | grep -F "$SEAM_VALID" >/dev/null; then
  _hits=1
fi
if printf '%s\n' "$LOOP_OUT" | grep -F "ok   — bash32-syntax-each.test.sh: 10 passed, 0 failed (7s)" >/dev/null \
   && [ "$_calls" -eq 1 ] \
   && [ "$_hits" -eq 1 ] \
   && [ -z "$FAILED" ]; then
  ok "loop-diag clean exit 0 forwards the validated receipt"
else
  bad "loop-diag clean pass (calls=$_calls receipt=$_hits failed='$FAILED' out=$(printf '%s' "$LOOP_OUT" | tr '\n' '|'))"
fi

echo "T9 stock Darwin Bash 3.2"
DARWIN_VER=$(/bin/bash --version 2>/dev/null | head -1)
case "$DARWIN_VER" in
  *'version 3.2'*)
    SEMI="$ROOT/semi.sh"
    PIPE="$ROOT/pipeor.sh"
    CASEAND="$ROOT/caseand.sh"
    T9_MARK="$ROOT/t9.marker"
    write_semi "$SEMI" "$T9_MARK"
    write_pipeor "$PIPE" "$T9_MARK"
    write_caseand "$CASEAND" "$T9_MARK"
    for later in "$SEMI" "$PIPE" "$CASEAND"; do
      case "$later" in
        "$SEMI") construct=';&' ;;
        "$PIPE") construct='|&' ;;
        *) construct=';;&' ;;
      esac
      rm -f "$T9_MARK"
      /bin/bash -n "$VALID" "$later" >/dev/null 2>&1
      batch_rc=$?
      /bin/bash -n "$later" >/dev/null 2>&1
      direct_rc=$?
      if [ "$batch_rc" -eq 0 ]; then
        ok "T9 $construct batched after valid is false-green 0"
      else
        bad "T9 $construct batched rc=$batch_rc (want 0)"
      fi
      if [ "$direct_rc" -ne 0 ]; then
        ok "T9 $construct direct /bin/bash -n is red $direct_rc"
      else
        bad "T9 $construct direct /bin/bash -n was green"
      fi
      H_OUT=$(/bin/bash -u "$HELPER" /bin/bash "$VALID" "$later" 2>"$ROOT/h.err")
      H_RC=$?
      H_ERR=$(cat "$ROOT/h.err")
      if [ "$H_RC" -eq 1 ]; then
        ok "T9 $construct helper exits 1"
      else
        bad "T9 $construct helper rc=$H_RC (want 1)"
      fi
      expect_named "$later" "T9 $construct names the later path"
      if [ -e "$T9_MARK" ]; then
        bad "T9 $construct executed a fixture"
      else
        ok "T9 $construct did not execute fixtures"
      fi
    done
    echo "darwin bash: $DARWIN_VER"
    ;;
  *)
    echo "NOTE bash32-syntax-each: platform arm unavailable: darwin-bash-3.2" >&2
    ;;
esac

echo "T10 hosted Docker Bash 3.2"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DFX=$ROOT/docker-fx
  mkdir -p "$DFX"
  cp "$HELPER" "$DFX/bash32-syntax-each.sh"
  printf '%s\n' '#!/bin/sh' 'true' > "$DFX/valid.sh"
  write_semi "$DFX/semi.sh" "$DFX/marker"
  write_pipeor "$DFX/pipeor.sh" "$DFX/marker"
  write_caseand "$DFX/caseand.sh" "$DFX/marker"
  docker_helper_out=$ROOT/docker.out
  docker_helper_err=$ROOT/docker.err
  for later in semi.sh pipeor.sh caseand.sh; do
    rm -f "$DFX/marker"
    docker run --rm -v "$DFX:/w" -w /w bash:3.2 \
      bash /w/bash32-syntax-each.sh bash /w/valid.sh "/w/$later" \
      >"$docker_helper_out" 2>"$docker_helper_err"
    d_rc=$?
    construct=$later
    if [ "$d_rc" -eq 1 ]; then
      ok "T10 $later helper exits 1"
    else
      bad "T10 $later helper rc=$d_rc (want 1)"
    fi
    if grep -Fq "/w/$later" "$docker_helper_err"; then
      ok "T10 $later names the later path"
    else
      bad "T10 $later did not name the later path"
    fi
    if [ -e "$DFX/marker" ]; then
      bad "T10 $later executed a fixture"
    else
      ok "T10 $later did not execute fixtures"
    fi
    if grep -q 'GIBSON_BASH32_SYNTAX' "$docker_helper_out"; then
      bad "T10 $later helper emitted a syntax receipt"
    else
      ok "T10 $later helper emitted no syntax receipt"
    fi
  done
else
  echo "NOTE bash32-syntax-each: platform arm unavailable: docker-bash-3.2" >&2
fi

echo "one-container alternating three-sample benchmark"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  PROD_FILES=$( (cd "$REPO_ROOT" && find scripts adapters -name '*.sh' -type f | sort) )
  BENCH_N=$(printf '%s\n' "$PROD_FILES" | wc -l | tr -d ' ')
  BENCH_HASH=$(printf '%s\n' "$PROD_FILES" | LC_ALL=C sort | paths_sha256 | tr 'A-F' 'a-f')
  mono_ms() {
    python3 -c 'import time; print(int(time.monotonic() * 1000))'
  }
  bench_once() {
    # $1 = baseline|candidate
    t0=$(mono_ms)
    if [ "$1" = baseline ]; then
      # shellcheck disable=SC2086
      docker run --rm -v "$REPO_ROOT:/w" -w /w bash:3.2 \
        bash -n $PROD_FILES >/dev/null 2>&1
    else
      # shellcheck disable=SC2086
      docker run --rm -v "$REPO_ROOT:/w" -w /w bash:3.2 \
        bash scripts/tests/lib/bash32-syntax-each.sh bash $PROD_FILES >/dev/null 2>&1
    fi
    rc=$?
    t1=$(mono_ms)
    if [ "$rc" -ne 0 ]; then
      return "$rc"
    fi
    echo $((t1 - t0))
    return 0
  }
  BENCH_OUT=$ROOT/bench.prod.out
  run_fail_closed_bench bench_once "$BENCH_HASH" "$BENCH_N" >"$BENCH_OUT"
  bench_rc=$?
  if grep -q '^GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 ' "$BENCH_OUT"; then
    cat "$BENCH_OUT"
  fi
  if [ "$bench_rc" -eq 0 ]; then
    ok "benchmark candidate-minus-baseline median ${BENCH_DELTA}ms <= 5000ms (n=$BENCH_N)"
  elif grep -q '^GIBSON_BASH32_BENCH schema=gibson.bash32-bench/v1 ' "$BENCH_OUT"; then
    bad "benchmark failed $BENCH_FAIL_REASON n=$BENCH_N"
  else
    bad "benchmark command failed: $BENCH_FAIL_REASON"
    if grep -q 'GIBSON_BASH32_BENCH' "$BENCH_OUT"; then
      bad "failed benchmark emitted a GIBSON_BASH32_BENCH lookalike"
    fi
  fi
else
  echo "NOTE bash32-syntax-each: platform arm unavailable: docker-bench" >&2
fi

echo
echo "bash32-syntax-each wall: ${SECONDS}s"
echo "bash32-syntax-each.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
