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

echo "# only tracked blobs are scanned: untracked files are ignored"
R="$ROOT/untracked"; new_repo "$R"; printf 'ok\n' > "$R/a.txt"; commit_all "$R"
printf 'Zorblax Quux\n' > "$R/untracked.md"
node "$PH" --root "$R" --config "$ROOT/cfg.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "an untracked file is not scanned" || bad "untracked rc=$rc"

echo "# no tracked file is skipped for its bytes or its name"
R="$ROOT/bytes"; new_repo "$R"
printf 'Zorblax Quux\0\1\2' > "$R/blob.dat"                       # stray NUL
printf 'Z\0o\0r\0b\0l\0a\0x\0 \0Q\0u\0u\0x\0\n\0' > "$R/utf16.txt"  # UTF-16LE text
printf 'x Zorblax Quux x\n' > "$R/image.png"                     # extension used to be skipped
commit_all "$R"
out=$(node "$PH" --root "$R" --config "$ROOT/cfg.json" 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "tree with hidden-by-bytes terms exits 1" || bad "bytes rc=$rc out=$out"
grep -q 'blob.dat:1  \[T1\]' <<<"$out" && ok "a stray NUL does not hide a term" || bad "NUL hid a term: $out"
grep -q 'utf16.txt:1  \[T1\]' <<<"$out" && ok "UTF-16 text is scanned" || bad "UTF-16 hid a term: $out"
grep -q 'image.png:1  \[T1\]' <<<"$out" && ok "a .png-named file is scanned" || bad "extension hid a term: $out"

echo "# symlinks are scanned as the link text Git stores, dangling or not"
R="$ROOT/links"; new_repo "$R"
ln -s "docs/zorblax-quux-notes" "$R/dangling"       # target does not exist
printf 'plain\n' > "$R/real.txt"; ln -s "real.txt" "$R/ok-link"   # resolvable, innocent
commit_all "$R"
out=$(node "$PH" --root "$R" --config "$ROOT/cfg.json" 2>&1); rc=$?
[[ $rc -eq 1 ]] && grep -q 'dangling:1  \[T1\]' <<<"$out" && ok "a dangling symlink whose target names a protected term is caught" || bad "dangling symlink rc=$rc out=$out"
grep -q 'ok-link' <<<"$out" && bad "innocent symlink flagged: $out" || ok "an innocent symlink is not flagged"
R="$ROOT/links2"; new_repo "$R"
printf 'harmless\n' > "$R/harmless.txt"
ln -s "harmless.txt" "$R/to-harmless"
commit_all "$R"
rm -f "$R/harmless.txt"                              # working tree now has a broken link
node "$PH" --root "$R" --config "$ROOT/cfg.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "scan reads the index, so a broken working tree changes nothing" || bad "broken-tree rc=$rc"

echo "# a blob missing from the object store is a finding, never a skip"
R="$ROOT/missing"; new_repo "$R"; printf 'findme-not\n' > "$R/m.txt"; commit_all "$R"
blob=$(git -C "$R" rev-parse HEAD:m.txt)
rm -f "$R/.git/objects/${blob:0:2}/${blob:2}"
out=$(node "$PH" --root "$R" --config "$ROOT/cfg.json" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "an unreadable blob does not pass silently (rc=$rc)" || bad "missing blob passed: $out"

echo "# the entrypoint runs when the script path contains characters a file URL escapes"
mkdir -p "$ROOT/path with space"; cp "$PH" "$ROOT/path with space/public-hygiene.mjs"
out=$(node "$ROOT/path with space/public-hygiene.mjs" --digest "plainword" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "$D2" ]] && ok "script under a spaced path still executes main" || bad "spaced path rc=$rc out=$out"

echo "# unknown flag exits 2 with the repo-wide message (#192 convention)"
out=$(node "$PH" --definitely-not-a-flag 2>&1 </dev/null); rc=$?
[[ $rc -eq 2 && "$out" == *"unknown flag:"* ]] && ok "unknown flag exits 2 with 'unknown flag:'" || bad "unknown flag rc=$rc out=$out"

echo "# terms longer than three words match, and --digest refuses terms the scanner cannot match"
D5=$(node "$PH" --digest "alpha beta gamma delta epsilon")
cat > "$ROOT/cfg5.json" <<CFG5
{"version":1,"algorithm":"sha256","denylist":[{"id":"T5","digest":"$D5"}],"allow":[]}
CFG5
R="$ROOT/long"; new_repo "$R"; printf 'see Alpha-Beta_Gamma delta, epsilon here\n' > "$R/n.md"; commit_all "$R"
out=$(node "$PH" --root "$R" --config "$ROOT/cfg5.json" 2>&1); rc=$?
[[ $rc -eq 1 ]] && grep -q 'n.md:1  \[T5\]' <<<"$out" && ok "five-word term matched across separators" || bad "five-word term not matched rc=$rc out=$out"
out=$(node "$PH" --digest "one two three four five six seven" 2>&1); rc=$?
[[ $rc -eq 2 && "$out" == *"at most"* ]] && ok "--digest rejects a term longer than the scanner can match" || bad "long --digest rc=$rc out=$out"
node "$PH" --digest "one two three four five six" >/dev/null 2>&1 && ok "--digest accepts the longest matchable term" || bad "six-word --digest refused"
out=$(node "$PH" --digest "!!!" 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "--digest rejects a term with no letters or digits" || bad "empty-term --digest rc=$rc"

echo "# the config file itself is scanned (free-text fields cannot name a protected term)"
R="$ROOT/selfscan"; new_repo "$R"; mkdir -p "$R/config"
cat > "$R/config/public-hygiene.v1.json" <<CFGA
{"\$comment":"notes about zorblax quux","version":1,"algorithm":"sha256","denylist":[{"id":"T1","digest":"$D1"}],"allow":[]}
CFGA
commit_all "$R"
out=$(node "$PH" --root "$R" 2>&1); rc=$?
[[ $rc -eq 1 ]] && grep -q 'config/public-hygiene.v1.json:1  \[T1\]' <<<"$out" && ok "term in the default config's comment field is caught" || bad "self-scan comment rc=$rc out=$out"
cat > "$R/config/public-hygiene.v1.json" <<CFGB
{"version":1,"algorithm":"sha256","denylist":[{"id":"T1","digest":"$D1"}],"allow":[{"path":"x.md","reason":"covers zorblax quux fixture"}]}
CFGB
commit_all "$R"
out=$(node "$PH" --root "$R" 2>&1); rc=$?
[[ $rc -eq 1 ]] && grep -q 'config/public-hygiene.v1.json:1  \[T1\]' <<<"$out" && ok "term in an allow-list reason is caught" || bad "self-scan reason rc=$rc out=$out"

echo "# oversized tracked text files fail closed instead of being skipped"
R="$ROOT/big"; new_repo "$R"; head -c 400 /dev/zero | tr '\0' 'a' > "$R/big.txt"; printf '\n' >> "$R/big.txt"; commit_all "$R"
write_cfg "$ROOT/cfg-big.json" '[]'
out=$(PUBLIC_HYGIENE_MAX_BYTES=100 node "$PH" --root "$R" --config "$ROOT/cfg-big.json" 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"big.txt:0  [UNSCANNABLE-too-large]"* ]] && ok "file over the limit is a finding (UNSCANNABLE)" || bad "oversized rc=$rc out=$out"
write_cfg "$ROOT/cfg-big-allow.json" '[{"path":"big.txt","reason":"generated data"}]'
out=$(PUBLIC_HYGIENE_MAX_BYTES=100 node "$PH" --root "$R" --config "$ROOT/cfg-big-allow.json" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "an oversized file can be allow-listed with a reason" || bad "oversized allow rc=$rc out=$out"

echo "# allow entries can name a path by digest, so the config never spells a protected path"
R="$ROOT/digestallow"; new_repo "$R"; mkdir -p "$R/sub"; printf 'Zorblax Quux\n' > "$R/sub/secret-name.md"; commit_all "$R"
PDIG=$(printf '%s' 'sub/secret-name.md' | shasum -a 256 | awk '{print $1}')
write_cfg "$ROOT/cfg-dig.json" "[{\"pathDigest\":\"$PDIG\",\"reason\":\"fixture\"}]"
out=$(node "$PH" --root "$R" --config "$ROOT/cfg-dig.json" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "pathDigest entry allow-lists the matching path" || bad "pathDigest allow rc=$rc out=$out"
write_cfg "$ROOT/cfg-dig-wrong.json" "[{\"pathDigest\":\"$(printf '%s' 'other.md' | shasum -a 256 | awk '{print $1}')\",\"reason\":\"fixture\"}]"
node "$PH" --root "$R" --config "$ROOT/cfg-dig-wrong.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "a digest for a different path does not allow this one" || bad "wrong digest rc=$rc"
write_cfg "$ROOT/cfg-dig-both.json" "[{\"path\":\"sub/secret-name.md\",\"pathDigest\":\"$PDIG\",\"reason\":\"fixture\"}]"
node "$PH" --root "$R" --config "$ROOT/cfg-dig-both.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "an entry with both path and pathDigest is a config error" || bad "both rc=$rc"
write_cfg "$ROOT/cfg-dig-none.json" '[{"reason":"fixture"}]'
node "$PH" --root "$R" --config "$ROOT/cfg-dig-none.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "an entry with neither path nor pathDigest is a config error" || bad "neither rc=$rc"
write_cfg "$ROOT/cfg-dig-bad.json" '[{"pathDigest":"not-a-digest","reason":"fixture"}]'
node "$PH" --root "$R" --config "$ROOT/cfg-dig-bad.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "a malformed pathDigest is a config error" || bad "bad digest rc=$rc"

echo "# an allow entry with both selectors is rejected even when one value is malformed"
R="$ROOT/bothsel"; new_repo "$R"; printf 'x\n' > "$R/a.md"; commit_all "$R"
write_cfg "$ROOT/cfg-both-bad.json" '[{"path":"a.md","pathDigest":"bad","reason":"fixture"}]'
node "$PH" --root "$R" --config "$ROOT/cfg-both-bad.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "path + malformed pathDigest is a config error (exit 2)" || bad "both-selectors rc=$rc (want 2)"
write_cfg "$ROOT/cfg-path-empty.json" '[{"path":"","reason":"fixture"}]'
node "$PH" --root "$R" --config "$ROOT/cfg-path-empty.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "an empty allow path is a config error" || bad "empty path rc=$rc"
write_cfg "$ROOT/cfg-path-num.json" '[{"path":7,"reason":"fixture"}]'
node "$PH" --root "$R" --config "$ROOT/cfg-path-num.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "a non-string allow path is a config error" || bad "numeric path rc=$rc"

echo "# tracked path names are scanned, and a protected path is never printed by name"
R="$ROOT/names"; new_repo "$R"
printf 'harmless words only\n' > "$R/zorblax-quux.md"                 # protected name, harmless body
mkdir -p "$R/dir"; printf 'see Zorblax Quux\n' > "$R/dir/Zorblax_Quux_notes.txt"   # protected name AND body
printf 'clean\n' > "$R/clean.md"
commit_all "$R"
out=$(node "$PH" --root "$R" --config "$ROOT/cfg.json" 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "a protected file name alone is a finding" || bad "name-only rc=$rc out=$out"
if grep -qi -E 'zorblax|quux' <<<"$out"; then bad "output printed a protected path: $out"; else ok "no protected path or term appears in the output"; fi
n=$(grep -c 'redacted-path sha256:' <<<"$out")
[[ $n -ge 3 ]] && ok "protected paths are reported by digest ($n findings: name and content)" || bad "expected >=3 redacted findings, got $n: $out"
grep -q 'clean.md' <<<"$out" && bad "clean path flagged: $out" || ok "an innocent path is not flagged"

echo "# --path-digest matches the digest an allow entry needs, so a protected path can be allow-listed unnamed"
PD=$(node "$PH" --path-digest "zorblax-quux.md")
[[ "$PD" == "$(printf '%s' 'zorblax-quux.md' | shasum -a 256 | awk '{print $1}')" ]] && ok "--path-digest prints sha256 of the exact path" || bad "path-digest mismatch: $PD"
R2="$ROOT/names2"; new_repo "$R2"; printf 'harmless words only\n' > "$R2/zorblax-quux.md"; commit_all "$R2"
write_cfg "$ROOT/cfg-pd.json" "[{\"pathDigest\":\"$PD\",\"reason\":\"fixture\"}]"
node "$PH" --root "$R2" --config "$ROOT/cfg-pd.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "a protected path allow-listed by digest passes" || bad "digest-allowed protected path rc=$rc"

echo "# an allow entry can be scoped to specific deny-list ids; other findings in the file still fail"
R="$ROOT/scoped"; new_repo "$R"
printf 'contact: Zorblax Quux here\nand a second term: plainword\n' > "$R/policy.md"; commit_all "$R"
write_cfg "$ROOT/cfg-scope-t1.json" '[{"path":"policy.md","reason":"approved contact","ids":["T1"]}]'
out=$(node "$PH" --root "$R" --config "$ROOT/cfg-scope-t1.json" 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "scoped to T1: the file still fails on its other term" || bad "scoped T1 rc=$rc out=$out"
grep -q 'policy.md:2  \[T2\]' <<<"$out" && ok "the un-exempted id (T2) is still reported with its line" || bad "T2 not reported: $out"
grep -q 'policy.md:1' <<<"$out" && bad "the exempted id (T1) was still reported: $out" || ok "the exempted id (T1) is suppressed"
write_cfg "$ROOT/cfg-scope-both.json" '[{"path":"policy.md","reason":"both approved","ids":["T1","T2"]}]'
node "$PH" --root "$R" --config "$ROOT/cfg-scope-both.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "scoped to every id the file hits: passes" || bad "scoped both rc=$rc"
write_cfg "$ROOT/cfg-whole.json" '[{"path":"policy.md","reason":"whole file"}]'
node "$PH" --root "$R" --config "$ROOT/cfg-whole.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "an entry without ids still exempts the whole file (unchanged)" || bad "whole-file rc=$rc"

echo "# a term added to a scoped file later is caught (the regression the review found)"
printf 'contact: Zorblax Quux here\nand a second term: plainword\n' > "$R/policy.md"
printf 'contact: Zorblax Quux here\n' > "$R/policy2.md"; commit_all "$R"
write_cfg "$ROOT/cfg-scope-p2.json" '[{"path":"policy2.md","reason":"approved contact","ids":["T1"]}]'
out=$(node "$PH" --root "$R" --config "$ROOT/cfg-scope-p2.json" 2>&1)
if grep -q 'policy2' <<<"$out"; then bad "policy2 flagged before any new term was added: $out"; else ok "scoped file with only the approved term passes"; fi
printf 'contact: Zorblax Quux here\nnew line naming plainword\n' > "$R/policy2.md"; commit_all "$R"
node "$PH" --root "$R" --config "$ROOT/cfg-scope-p2.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "adding a different private term to the scoped file fails the gate" || bad "added term not caught rc=$rc"

echo "# ids also work on pathDigest entries; bad ids are a config error"
PDS=$(node "$PH" --path-digest "policy2.md")
write_cfg "$ROOT/cfg-scope-dig.json" "[{\"pathDigest\":\"$PDS\",\"reason\":\"approved\",\"ids\":[\"T1\"]}]"
out=$(node "$PH" --root "$R" --config "$ROOT/cfg-scope-dig.json" 2>&1)
grep -q 'policy2.md:2  \[T2\]' <<<"$out" && ok "pathDigest entry with ids scopes the same way" || bad "digest+ids: $out"
for bad_ids in '[]' '["NOPE"]' '"T1"' '[1]'; do
  write_cfg "$ROOT/cfg-badids.json" "[{\"path\":\"policy.md\",\"reason\":\"x\",\"ids\":$bad_ids}]"
  node "$PH" --root "$R" --config "$ROOT/cfg-badids.json" >/dev/null 2>&1; rc=$?
  [[ $rc -eq 2 ]] && ok "ids=$bad_ids is a config error (exit 2)" || bad "ids=$bad_ids rc=$rc (want 2)"
done

echo "# UNSCANNABLE findings are never suppressed by an ids exemption"
printf 'harmless\n' > "$R/big2.txt"; head -c 400 /dev/zero | tr '\0' 'a' >> "$R/big2.txt"; commit_all "$R"
write_cfg "$ROOT/cfg-scope-big.json" '[{"path":"big2.txt","reason":"x","ids":["T1"]}]'
out=$(PUBLIC_HYGIENE_MAX_BYTES=100 node "$PH" --root "$R" --config "$ROOT/cfg-scope-big.json" 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"UNSCANNABLE-too-large"* ]] && ok "an oversized file stays a finding under an ids exemption" || bad "unscannable suppressed rc=$rc out=$out"

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
