#!/usr/bin/env bash
# convention-sensors.test.sh — mutation coverage for #192 convention sensors
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=lib/convention-sensors.sh
. "$SCRIPT_DIR/lib/convention-sensors.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-convention-sensors.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

command -v node >/dev/null || { echo "convention-sensors.test.sh: node required"; exit 1; }

echo "# vendored mjs self-containment"

listed=$(cs_list_vendored_mjs "$REPO_ROOT") || { bad "list vendored mjs (plumbing)"; listed=""; }
echo "$listed" | grep -x 'scripts/test-integrity.mjs' >/dev/null \
  && echo "$listed" | grep -x 'scripts/check-active-work.mjs' >/dev/null \
  && echo "$listed" | grep -x 'scripts/route-inventory.mjs' >/dev/null \
  && ok "sparse-checkout + README name the three vendored mjs files" \
  || bad "vendored list: $listed"

hits=$(cs_vendored_selfcontained "$REPO_ROOT"); rc=$?
[[ "$rc" -eq 0 && -z "$hits" ]] \
  && ok "clean tree: vendored mjs files have no relative imports" \
  || bad "clean tree self-containment (rc=$rc): $hits"

# Isolated copies must run without lib/ (the gibson-gate sparse-checkout
# and ci/security.yml single-file vendor of route-inventory.mjs).
mkdir -p "$ROOT/isolated"
cp "$REPO_ROOT/scripts/test-integrity.mjs" "$ROOT/isolated/test-integrity.mjs"
cp "$REPO_ROOT/scripts/check-active-work.mjs" "$ROOT/isolated/check-active-work.mjs"
cp "$REPO_ROOT/scripts/route-inventory.mjs" "$ROOT/isolated/route-inventory.mjs"
out=$(node "$ROOT/isolated/test-integrity.mjs" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'test-integrity' >/dev/null \
  && ok "isolated test-integrity.mjs --help works without lib/" \
  || bad "isolated test-integrity (rc=$rc): $out"
out=$(node "$ROOT/isolated/check-active-work.mjs" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] \
  && ok "isolated check-active-work.mjs --help works without lib/" \
  || bad "isolated check-active-work (rc=$rc): $out"

# Isolated route-inventory must scan a real app/ tree with no lib/ beside it.
mkdir -p "$ROOT/ri-app/app/dashboard"
printf '%s\n' 'export default function Page(){return null}' > "$ROOT/ri-app/app/page.tsx"
printf '%s\n' 'export default function Dash(){return null}' > "$ROOT/ri-app/app/dashboard/page.tsx"
out=$(node "$ROOT/isolated/route-inventory.mjs" --root "$ROOT/ri-app" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"/dashboard"' >/dev/null \
  && ok "isolated route-inventory.mjs scans app/ fixture without lib/" \
  || bad "isolated route-inventory (rc=$rc): $out"

# A README-listed bare name (`planted-vendor.mjs`) must be discovered as
# scripts/planted-vendor.mjs, and a relative import in that file must fail.
BARE="$ROOT/bare-vendor"
mkdir -p "$BARE/ci" "$BARE/scripts"
printf '%s\n' 'name: dummy' > "$BARE/ci/gibson-gate.yml"
{
  printf '%s\n' 'Vendor these:'
  printf '%s\n' '- `planted-vendor.mjs`'
  printf '%s\n' 'Do not copy example.mjs into scripts/ as a prose example.'
  printf '%s\n' 'Also ignore path-qualified `other/dir/skip-me.mjs`.'
} > "$BARE/ci/README.md"
{
  printf '%s\n' '#!/usr/bin/env node'
  printf '%s\n' 'import { readFlag } from "./lib/args.mjs";'
  printf '%s\n' 'console.log("planted");'
} > "$BARE/scripts/planted-vendor.mjs"
bare_listed=$(cs_list_vendored_mjs "$BARE") || { bad "list bare-name vendored mjs"; bare_listed=""; }
if echo "$bare_listed" | grep -x 'scripts/planted-vendor.mjs' >/dev/null \
    && ! echo "$bare_listed" | grep -x 'scripts/example.mjs' >/dev/null \
    && ! echo "$bare_listed" | grep 'skip-me.mjs' >/dev/null; then
  ok "README bare name planted-vendor.mjs maps to scripts/planted-vendor.mjs"
else
  bad "bare-name list missing planted-vendor or pulled prose: $bare_listed"
fi
hits=$(cs_vendored_selfcontained "$BARE"); rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s\n' "$hits" | grep 'from' >/dev/null; then
  echo "  planted README-listed bare-name relative-import failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: relative import in README-listed bare-name file fails"
else
  bad "mutation bare-name relative-import unexpectedly passed (rc=$rc): $hits"
fi

# Mutation: a fixture copy of a vendored-listed file WITH a relative import
# must fail. Build the import via single-quoted pieces so this test file
# itself is not a hit for other sensors.
mut="$ROOT/mut-vendored.mjs"
{
  printf '%s\n' '#!/usr/bin/env node'
  printf '%s\n' 'import { readFlag } from "./lib/args.mjs";'
  printf '%s\n' 'console.log("mutant");'
} > "$mut"
hits=$(cs_mjs_relative_import_hits "$mut"); rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s\n' "$hits" | grep 'from' >/dev/null && printf '%s\n' "$hits" | grep -E ':2: ' >/dev/null; then
  echo "  planted relative-import failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: vendored-file fixture with relative import fails the sensor"
else
  bad "mutation relative-import unexpectedly passed (rc=$rc): $hits"
fi

# Additional relative-specifier forms (each planted file must fail).
# Optional 5th arg is the expected original line of the import/from keyword.
plant_rel() {
  local name="$1" src="$2" needle="$3" label="$4"
  local expect_line="${5:-}"
  printf '%s\n' '#!/usr/bin/env node' "$src" > "$ROOT/$name"
  hits=$(cs_mjs_relative_import_hits "$ROOT/$name"); rc=$?
  if [[ "$rc" -eq 1 ]] && printf '%s\n' "$hits" | grep "$needle" >/dev/null; then
    if [[ -n "$expect_line" ]] && ! printf '%s\n' "$hits" | grep -E ":${expect_line}: " >/dev/null; then
      bad "mutation $label wrong line (want :${expect_line}:): $hits"
      return
    fi
    echo "  planted $label failure line:"
    printf '%s\n' "$hits" | sed 's/^/    /'
    ok "mutation: $label fails the vendored-mjs sensor"
  else
    bad "mutation $label unexpectedly passed (rc=$rc): $hits"
  fi
}
plant_rel mut-parent.mjs 'import { x } from "../lib/args.mjs";' 'from' 'from "../ parent-relative import' 2
plant_rel mut-sideeffect.mjs 'import "./side-effect.mjs";' 'import' 'side-effect import "./x"' 2
plant_rel mut-dynamic.mjs 'const m = import("./dyn.mjs");' 'import' 'dynamic import("./x")' 2
plant_rel mut-reexport.mjs 'export { readFlag } from "./lib/args.mjs";' 'from' 'export ... from "./x" re-export' 2
plant_rel mut-multiline-from.mjs $'import { x }\n  from "./z.mjs"' 'from' 'multiline import { x } from "./z"' 3
plant_rel mut-multiline-dynamic.mjs $'import(\n  "./z.mjs"\n)' 'import' 'multiline import("./z")' 2
plant_rel mut-template.mjs 'import(`./z.mjs`)' 'import' 'template-literal import(`./z`)' 2
plant_rel mut-comment-from.mjs 'import {x} from /* dep */ "./z.mjs"' 'from' 'comment-injected from /* dep */ "./z"' 2
plant_rel mut-comment-dynamic.mjs 'import(/* webpackChunkName */ "./z.mjs")' 'import' 'comment-injected import(/* webpackChunkName */ "./z")' 2

# UTF-8 / U+FFFD must not crash the stripper; diagnostics restore orig text.
utf_import="$ROOT/mut-utf8-import.mjs"
{
  printf '%s\n' '#!/usr/bin/env node'
  printf '%s\n' 'import {x} from "./z.mjs" // keep-me-in-diag café — �'
} > "$utf_import"
hits=$(cs_mjs_relative_import_hits "$utf_import"); rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s\n' "$hits" | grep -E ':2: ' >/dev/null \
    && printf '%s\n' "$hits" | grep 'keep-me-in-diag' >/dev/null; then
  echo "  planted utf8-import failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: U+FFFD/em-dash file still reports orig file:line"
else
  bad "mutation utf8-import (rc=$rc): $hits"
fi

utf_clean="$ROOT/mut-utf8-clean.mjs"
{
  printf '%s\n' '#!/usr/bin/env node'
  printf '%s\n' '// café — undecodable �'
  printf '%s\n' 'const x = 1;'
} > "$utf_clean"
hits=$(cs_mjs_relative_import_hits "$utf_clean"); rc=$?
[[ "$rc" -eq 0 && -z "$hits" ]] \
  && ok "mutation: U+FFFD comment without import is clean (no towc crash)" \
  || bad "mutation utf8-clean (rc=$rc): $hits"

utf_hidden="$ROOT/mut-utf8-hidden.mjs"
{
  printf '%s\n' '#!/usr/bin/env node'
  printf '%s\n' '/* import "./hidden.mjs" — � */'
  printf '%s\n' '// import "./also-hidden.mjs"'
  printf '%s\n' 'const x = 1;'
} > "$utf_hidden"
hits=$(cs_mjs_relative_import_hits "$utf_hidden"); rc=$?
[[ "$rc" -eq 0 && -z "$hits" ]] \
  && ok "mutation: import inside UTF-8 comments is not a hit" \
  || bad "mutation utf8-hidden (rc=$rc): $hits"

echo "# clean-tree pass for the four shell sensors"
# Spot-check a known-clean production file; run-all walks the full tree.
hits=$(cs_bash4_hits "$REPO_ROOT/scripts/lib/common.sh"); rc=$?
[[ "$rc" -eq 0 && -z "$hits" ]] && ok "clean tree: common.sh has no bash-4 builtins" \
  || bad "clean common.sh bash4 (rc=$rc): $hits"
hits=$(cs_script_dir_hits "$REPO_ROOT/scripts/claim.sh"); rc=$?
[[ "$rc" -eq 0 && -z "$hits" ]] && ok "clean tree: claim.sh SCRIPT_DIR is canonical" \
  || bad "clean claim.sh SCRIPT_DIR (rc=$rc): $hits"
hits=$(cs_info_warn_hits "$REPO_ROOT/scripts/claim.sh"); rc=$?
[[ "$rc" -eq 0 && -z "$hits" ]] && ok "clean tree: claim.sh info() goes to stderr" \
  || bad "clean claim.sh info/warn (rc=$rc): $hits"
hits=$(cs_tool_guard_hits "$REPO_ROOT/scripts/delivery-control/audit.sh"); rc=$?
[[ "$rc" -eq 0 && -z "$hits" ]] && ok "clean tree: audit.sh is guarded via sourcing lib.sh" \
  || bad "clean audit.sh tool-guard (rc=$rc): $hits"
hits=$(cs_tool_guard_hits "$REPO_ROOT/scripts/claim.sh"); rc=$?
[[ "$rc" -eq 0 && -z "$hits" ]] \
  && ok "clean tree: claim.sh env -u … node is line-order guarded" \
  || bad "clean claim.sh tool-guard (rc=$rc): $hits"

echo "# planted violations (report failure lines verbatim)"
FX="$ROOT/planted"
mkdir -p "$FX"

printf '%s\n' '#!/bin/bash' 'mapfile -t rows' > "$FX/mapfile.sh"
hits=$(cs_bash4_hits "$FX/mapfile.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted mapfile -t rows failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: mapfile -t rows fails bash-4 sensor"
else
  bad "mutation mapfile passed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' > "$FX/caret.sh"
printf 'echo "%s"\n' '${name^^}' >> "$FX/caret.sh"
hits=$(cs_bash4_hits "$FX/caret.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo '  planted quoted caret-expansion failure line:'
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok 'mutation: quoted ${name^^} fails bash-4 sensor'
else
  bad "mutation caret passed (rc=$rc): $hits"
fi

printf '%s\n' 'export SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"' > "$FX/scriptdir.sh"
hits=$(cs_script_dir_hits "$FX/scriptdir.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted export SCRIPT_DIR=... failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: export SCRIPT_DIR non-canonical fails SCRIPT_DIR sensor"
else
  bad "mutation SCRIPT_DIR passed (rc=$rc): $hits"
fi

printf '%s\n' 'info () { echo leaked; }' > "$FX/info-space.sh"
hits=$(cs_info_warn_hits "$FX/info-space.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted info () { echo leaked; } failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: info () with space and stdout echo fails info/warn sensor"
else
  bad "mutation info-space passed (rc=$rc): $hits"
fi

printf '%s\n' 'info() { : >&2; echo leaked; }' > "$FX/info-mixed.sh"
hits=$(cs_info_warn_hits "$FX/info-mixed.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted info() { : >&2; echo leaked; } failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: stray >&2 does not satisfy an unredirected echo"
else
  bad "mutation info-mixed passed (rc=$rc): $hits"
fi

printf '%s\n' '# need_cmd jq' 'jq -n .' > "$FX/jq-comment.sh"
hits=$(cs_tool_guard_hits "$FX/jq-comment.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded jq (comment-only need_cmd) failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: # need_cmd jq comment does not guard a later jq"
else
  bad "mutation jq-comment passed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'command jq -n .' > "$FX/command-jq.sh"
hits=$(cs_tool_guard_hits "$FX/command-jq.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded command jq -n . failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: command jq -n . unguarded fails tool-guard sensor"
else
  bad "mutation command-jq passed (rc=$rc): $hits"
fi

{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' '. ./fake-lib.sh'
  printf '%s\n' 'gh pr list'
} > "$FX/fake-lib-source.sh"
hits=$(cs_tool_guard_hits "$FX/fake-lib-source.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted source ./fake-lib.sh then gh failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: sourcing ./fake-lib.sh does not grant a gh guard"
else
  bad "mutation fake-lib.sh source granted a guard (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'env FOO=1 jq -n .' > "$FX/env-jq.sh"
hits=$(cs_tool_guard_hits "$FX/env-jq.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded env FOO=1 jq -n . failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: env FOO=1 jq -n . unguarded fails tool-guard sensor"
else
  bad "mutation env-jq passed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'command -p jq -n .' > "$FX/command-p-jq.sh"
hits=$(cs_tool_guard_hits "$FX/command-p-jq.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded command -p jq -n . failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: command -p jq -n . unguarded fails tool-guard sensor"
else
  bad "mutation command-p-jq passed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'env FOO= jq -n .' > "$FX/env-empty-jq.sh"
hits=$(cs_tool_guard_hits "$FX/env-empty-jq.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded env FOO= jq -n . failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: env FOO= jq -n . unguarded fails tool-guard sensor"
else
  bad "mutation env-empty-jq passed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'command -p -- jq -n .' > "$FX/command-p-dashdash-jq.sh"
hits=$(cs_tool_guard_hits "$FX/command-p-dashdash-jq.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded command -p -- jq -n . failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: command -p -- jq -n . unguarded fails tool-guard sensor"
else
  bad "mutation command-p-dashdash-jq passed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'command -v jq >/dev/null || die' > "$FX/command-v-only.sh"
hits=$(cs_tool_guard_hits "$FX/command-v-only.sh"); rc=$?
if [[ "$rc" -eq 0 && -z "$hits" ]]; then
  ok "mutation: command -v jq only (guard idiom) passes tool-guard sensor"
else
  bad "mutation command -v only unexpectedly failed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'command -pv jq >/dev/null || die' > "$FX/command-pv-only.sh"
hits=$(cs_tool_guard_hits "$FX/command-pv-only.sh"); rc=$?
if [[ "$rc" -eq 0 && -z "$hits" ]]; then
  ok "mutation: command -pv jq (combined guard) passes tool-guard sensor"
else
  bad "mutation command -pv unexpectedly failed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'command -- jq -n .' > "$FX/command-dashdash-jq.sh"
hits=$(cs_tool_guard_hits "$FX/command-dashdash-jq.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded command -- jq -n . failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: command -- jq -n . unguarded fails tool-guard sensor"
else
  bad "mutation command -- jq passed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'env -u FOO jq -n .' > "$FX/env-u-jq.sh"
hits=$(cs_tool_guard_hits "$FX/env-u-jq.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded env -u FOO jq -n . failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: env -u FOO jq -n . unguarded fails tool-guard sensor"
else
  bad "mutation env -u jq passed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'env -i FOO=1 jq -n .' > "$FX/env-i-jq.sh"
hits=$(cs_tool_guard_hits "$FX/env-i-jq.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded env -i FOO=1 jq -n . failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: env -i FOO=1 jq -n . unguarded fails tool-guard sensor"
else
  bad "mutation env -i jq passed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'env -u NODE_OPTIONS -u NODE_REPL_EXTERNAL_MODULE node -e 1' \
  > "$FX/env-u-node.sh"
hits=$(cs_tool_guard_hits "$FX/env-u-node.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded env -u NODE_OPTIONS … node failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: env -u NODE_OPTIONS -u NODE_REPL_EXTERNAL_MODULE node unguarded fails"
else
  bad "mutation env -u node passed (rc=$rc): $hits"
fi

printf '%s\n' '#!/bin/bash' 'FOO=1 jq -n .' > "$FX/prefix-assign-jq.sh"
hits=$(cs_tool_guard_hits "$FX/prefix-assign-jq.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted unguarded FOO=1 jq -n . failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: prefix assignment FOO=1 jq unguarded fails tool-guard sensor"
else
  bad "mutation prefix-assign jq passed (rc=$rc): $hits"
fi

{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' '. /tmp/delivery-control/lib.sh'
  printf '%s\n' 'gh pr list'
} > "$FX/tmp-dc-lib-source.sh"
hits=$(cs_tool_guard_hits "$FX/tmp-dc-lib-source.sh"); rc=$?
if [[ "$rc" -eq 1 ]]; then
  echo "  planted source /tmp/delivery-control/lib.sh then gh failure line:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  ok "mutation: sourcing /tmp/delivery-control/lib.sh does not grant a gh guard"
else
  bad "mutation /tmp/delivery-control/lib.sh source granted a guard (rc=$rc): $hits"
fi

echo
echo "convention-sensors.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
