#!/usr/bin/env bash
# public-hygiene.test.sh — deny-list sensor contract (#529)
# Uses an invented term so no real private name appears in this repository.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PH="$SCRIPT_DIR/../public-hygiene.mjs"
LIVE_CFG="$SCRIPT_DIR/../../config/public-hygiene.v1.json"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "public-hygiene.test.sh: node required"; exit 1; }
command -v git >/dev/null || { echo "public-hygiene.test.sh: git required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-hygiene.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

TERM_PLAIN="Zorblax Quux"
D1=$(node "$PH" --digest "$TERM_PLAIN")
D2=$(node "$PH" --digest "plainword")

write_cfg() { # $1 path, $2 allow-json
  cat > "$1" <<EOF
{"version":1,"algorithm":"sha256","denylist":[{"id":"T1","digest":"$D1"},{"id":"T2","digest":"$D2"}],"allow":$2}
EOF
}

new_repo() { # $1 dir
  mkdir -p "$1" && git -C "$1" init -q
  git -C "$1" config user.email t@example.com && git -C "$1" config user.name t
}

commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m x; }

echo "# digest is stable and normalization collapses separators/case"
a=$(node "$PH" --digest "Zorblax Quux"); b=$(node "$PH" --digest "zorblax-quux"); c=$(node "$PH" --digest "ZorblaxQuux"); d=$(node "$PH" --digest "zorblax_QUUX")
[[ "$a" == "$b" && "$b" == "$c" && "$c" == "$d" && "$a" == "$D1" ]] && ok "space/hyphen/camel/underscore variants hash identically" || bad "variants differ: $a $b $c $d"

echo "# clean tree passes"
R="$ROOT/clean"; new_repo "$R"; echo "nothing private here" > "$R/a.md"; commit_all "$R"
write_cfg "$ROOT/cfg.json" '[]'
out=$(node "$PH" --root "$R" --config "$ROOT/cfg.json" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "clean tree exits 0" || bad "clean tree rc=$rc: $out"

echo "# word-pair match across variants, with line numbers"
R="$ROOT/dirty"; new_repo "$R"
printf 'line one\nsee Zorblax-Quux deployment\n' > "$R/doc.md"
printf 'x = "zorblaxquux"\n' > "$R/code.mjs"
printf 'harmless plainword here\n' > "$R/single.txt"
commit_all "$R"
out=$(node "$PH" --root "$R" --config "$ROOT/cfg.json" 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "dirty tree exits 1" || bad "dirty tree rc=$rc"
grep -q 'doc.md:2  \[T1\]' <<<"$out" && ok "hyphen variant found at doc.md:2" || bad "no doc.md:2 finding: $out"
grep -q 'code.mjs:1  \[T1\]' <<<"$out" && ok "joined variant found at code.mjs:1" || bad "no code.mjs:1 finding: $out"
grep -q 'single.txt:1  \[T2\]' <<<"$out" && ok "single-word entry found" || bad "no single.txt finding: $out"

echo "# matched text is never echoed"
if grep -qi -E 'zorblax|quux|plainword' <<<"$out"; then bad "output echoed a deny-listed term"; else ok "output names path:line:id only"; fi

echo "# allow-list path suppresses, and needs a reason"
write_cfg "$ROOT/cfg-allow.json" '[{"path":"doc.md","reason":"fixture"},{"path":"code.mjs","reason":"fixture"},{"path":"single.txt","reason":"fixture"}]'
out=$(node "$PH" --root "$R" --config "$ROOT/cfg-allow.json" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "allow-listed paths pass" || bad "allow-list rc=$rc: $out"
write_cfg "$ROOT/cfg-noreason.json" '[{"path":"doc.md","reason":""}]'
node "$PH" --root "$R" --config "$ROOT/cfg-noreason.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "allow entry without a reason is a config error (exit 2)" || bad "empty reason rc=$rc (want 2)"

echo "# binary files and untracked files are ignored"
R="$ROOT/bin"; new_repo "$R"; printf 'ok\n' > "$R/a.txt"; printf 'Zorblax Quux\0\1\2' > "$R/blob.dat"; commit_all "$R"
printf 'Zorblax Quux\n' > "$R/untracked.md"
node "$PH" --root "$R" --config "$ROOT/cfg.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "NUL-containing and untracked files are skipped" || bad "binary/untracked rc=$rc"

echo "# config errors exit 2"
echo '{"version":2}' > "$ROOT/bad.json"
node "$PH" --root "$R" --config "$ROOT/bad.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "bad version exits 2" || bad "bad version rc=$rc"
node "$PH" --root "$R" --config "$ROOT/missing.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "missing config exits 2" || bad "missing config rc=$rc"

echo "# live deny-list is well-formed and hashes only"
if node -e '
const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
if(c.version!==1||c.algorithm!=="sha256")process.exit(1);
for(const e of c.denylist){if(!/^H[0-9]+$/.test(e.id)||!/^[0-9a-f]{64}$/.test(e.digest))process.exit(2);}
if(Object.keys(c).some(k=>!["$comment","version","algorithm","denylist","allow"].includes(k)))process.exit(3);
' "$LIVE_CFG"; then ok "config/public-hygiene.v1.json is well-formed"; else bad "live config malformed"; fi

echo "# this repository's own tree is clean"
node "$PH" --root "$SCRIPT_DIR/../.." >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "live tree passes the live deny-list" || bad "live tree has findings (rc=$rc)"

echo
echo "public-hygiene.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
