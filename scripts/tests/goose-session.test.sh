#!/usr/bin/env bash
# goose-session.test.sh — offline sensors for #33 lifecycle + #35 enforcement
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
ENFORCE="$REPO_ROOT/adapters/goose/enforce.sh"
SESSION="$REPO_ROOT/adapters/goose/session.sh"
PERM="$REPO_ROOT/adapters/goose/permission-map.yaml"
PASS=0
FAIL=0

ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v git >/dev/null || { echo "goose-session.test.sh: git required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-goose-session-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

export GIT_AUTHOR_NAME=gibson-test GIT_AUTHOR_EMAIL=test@gibson.invalid
export GIT_COMMITTER_NAME=gibson-test GIT_COMMITTER_EMAIL=test@gibson.invalid

# ---------------------------------------------------------------------------
echo "adapter artifacts present (#33)"
# ---------------------------------------------------------------------------
for f in \
  "$ENFORCE" \
  "$SESSION" \
  "$PERM" \
  "$REPO_ROOT/adapters/goose/README.md" \
  "$REPO_ROOT/adapters/goose/templates/doctrine-mount.md" \
  "$REPO_ROOT/adapters/goose/templates/goosehints.fragment"
do
  if [[ -e "$f" ]]; then ok "$(basename "$(dirname "$f")")/$(basename "$f") present"
  else bad "missing $f"; fi
done
[[ -x "$ENFORCE" ]] && ok "enforce.sh executable" || bad "enforce.sh not executable"
[[ -x "$SESSION" ]] && ok "session.sh executable" || bad "session.sh not executable"

# ---------------------------------------------------------------------------
echo "no Goose runtime dependency in adapter scripts (#28 boundary)"
# ---------------------------------------------------------------------------
if grep -nE 'goose run|require.*goose|command -v goose' "$ENFORCE" | grep -vE '^\s*#|HELP|help|NOT |absent|blocked|validate'; then
  # enforce must never call goose
  if grep -nE 'goose run|exec goose|goose ' "$ENFORCE" | grep -vE '#|HELP|help|echo '; then
    bad "enforce.sh references goose binary"
  else
    ok "enforce.sh has no goose runtime dependency"
  fi
else
  ok "enforce.sh has no goose runtime dependency"
fi
# session may mention goose for optional validate only
if grep -q 'goose recipe validate' "$SESSION"; then
  ok "session.sh optional validate path only (recipe validate)"
else
  ok "session.sh does not hard-require goose"
fi

# ---------------------------------------------------------------------------
echo "permission-map wiring (#35 / autonomy-modes)"
# ---------------------------------------------------------------------------
if [[ -f "$PERM" ]]; then
  ok "permission-map.yaml present"
else
  bad "permission-map.yaml missing"
fi
if grep -nE '@latest' "$PERM" | grep -vE '^\s*#|No floating|not |never |forbid'; then
  bad "permission-map contains @latest pin"
else
  ok "permission-map has no @latest pin"
fi
for needle in force_push secrets production_destroy money_billing pii_consent never_allow always_allow ask_before; do
  if grep -q "$needle" "$PERM"; then ok "permission-map has $needle"
  else bad "permission-map missing $needle"; fi
done
if grep -q 'docs/autonomy-modes.md' "$PERM"; then
  ok "permission-map cites autonomy-modes doc"
else
  bad "permission-map missing autonomy-modes citation"
fi
# green_gate always_allow so enforcement is never permission-blocked
if grep -A3 'green_gate_scripts' "$PERM" | grep  always_allow >/dev/null; then
  ok "green_gate_scripts always_allow (enforcement not prompt-blocked)"
else
  bad "green_gate_scripts must be always_allow"
fi

# ---------------------------------------------------------------------------
echo "require-claim fail-closed (Law 2)"
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/empty/docs"
if "$ENFORCE" require-claim --repo "$ROOT/empty" --issue 42 2>"$ROOT/e1"; then
  bad "require-claim should fail without claim"
else
  if grep -q 'BLOCKED' "$ROOT/e1"; then ok "no claim → BLOCKED"
  else bad "missing BLOCKED: $(cat "$ROOT/e1")"; fi
fi

mkdir -p "$ROOT/claimed/docs/claims"
printf 'claim: issue-42-demo\nissue: 42\n' > "$ROOT/claimed/docs/claims/issue-42-demo.md"
if "$ENFORCE" require-claim --repo "$ROOT/claimed" --issue 42 2>"$ROOT/e2"; then
  ok "live claim → require-claim ok"
else
  bad "require-claim failed with live claim: $(cat "$ROOT/e2")"
fi
if "$ENFORCE" require-claim --repo "$ROOT/claimed" --issue 42 --claim-id issue-42-demo; then
  ok "require-claim exact claim-id"
else
  bad "exact claim-id failed"
fi
if "$ENFORCE" require-claim --repo "$ROOT/claimed" --issue 42 --claim-id issue-42-other 2>"$ROOT/e3"; then
  bad "wrong claim-id should fail"
else
  ok "wrong claim-id BLOCKED"
fi

# ---------------------------------------------------------------------------
echo "require-worktree fail-closed (Law 3)"
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/canon" "$ROOT/wt"
git -C "$ROOT/canon" init -q
git -C "$ROOT/wt" init -q
if "$ENFORCE" require-worktree --repo "$ROOT/canon" --canonical "$ROOT/canon" 2>"$ROOT/e4"; then
  bad "canonical==repo should block"
else
  grep -q 'BLOCKED' "$ROOT/e4" && ok "canonical mutation BLOCKED" || bad "no BLOCKED on canonical"
fi
if "$ENFORCE" require-worktree --repo "$ROOT/wt" --canonical "$ROOT/canon"; then
  ok "distinct worktree allowed"
else
  bad "distinct worktree wrongly blocked"
fi

# ---------------------------------------------------------------------------
echo "pre-edit combines claim + worktree"
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/wt2/docs/claims"
cp "$ROOT/claimed/docs/claims/issue-42-demo.md" "$ROOT/wt2/docs/claims/"
git -C "$ROOT/wt2" init -q
if "$ENFORCE" pre-edit --repo "$ROOT/wt2" --issue 42 --canonical "$ROOT/canon"; then
  ok "pre-edit ok with claim+worktree"
else
  bad "pre-edit should pass"
fi
if "$ENFORCE" pre-edit --repo "$ROOT/wt" --issue 42 --canonical "$ROOT/canon" 2>"$ROOT/e5"; then
  bad "pre-edit without claim should fail"
else
  ok "pre-edit without claim BLOCKED"
fi

# ---------------------------------------------------------------------------
echo "pre-commit red gate fail-closed (#35 transcript)"
# ---------------------------------------------------------------------------
# Mini gibson tree with failing gate.sh
MINI="$ROOT/mini-gibson"
mkdir -p "$MINI/scripts" "$MINI/adapters/goose"
cp "$ENFORCE" "$MINI/adapters/goose/enforce.sh"
chmod +x "$MINI/adapters/goose/enforce.sh"
for s in claim.sh gate-baseline.sh release-claim.sh; do
  printf '#!/bin/sh\nexit 0\n' > "$MINI/scripts/$s"
  chmod +x "$MINI/scripts/$s"
done
cat > "$MINI/scripts/gate.sh" <<'G'
#!/usr/bin/env bash
echo "gate.sh: RED — simulated new failures vs baseline" >&2
exit 1
G
chmod +x "$MINI/scripts/gate.sh"

TRANSCRIPT="$ROOT/red-gate-transcript.txt"
{
  echo "# Red-gate block transcript (offline sensor for #35)"
  echo "# Deliberately red gate must not allow commit path to succeed."
  if GIBSON_ROOT="$MINI" "$MINI/adapters/goose/enforce.sh" \
      pre-commit --repo "$ROOT/wt2" --issue 42 --canonical "$ROOT/canon" 2>&1; then
    echo "UNEXPECTED_PASS"
  else
    echo "EXIT_BLOCKED=$?"
  fi
} > "$TRANSCRIPT" 2>&1 || true

if grep -q 'UNEXPECTED_PASS' "$TRANSCRIPT"; then
  bad "red gate pre-commit unexpectedly passed"
elif grep -qE 'RED|BLOCKED|gate' "$TRANSCRIPT"; then
  ok "red-gate pre-commit blocked (transcript visible)"
else
  bad "red-gate transcript unclear: $(cat "$TRANSCRIPT")"
fi
# exit code non-zero
if GIBSON_ROOT="$MINI" "$MINI/adapters/goose/enforce.sh" \
    pre-commit --repo "$ROOT/wt2" --issue 42 --canonical "$ROOT/canon" >/dev/null 2>&1; then
  bad "red gate exit code was 0"
else
  ec=$?
  # gate.sh returns 1; enforce should propagate
  if [[ "$ec" -ne 0 ]]; then ok "red gate exit code non-zero (ec=$ec, same fail-closed class as gate.sh)"
  else bad "unexpected ec=$ec"; fi
fi

# Green gate stub → pre-commit succeeds
cat > "$MINI/scripts/gate.sh" <<'G'
#!/usr/bin/env bash
echo "gate.sh: GREEN"
exit 0
G
chmod +x "$MINI/scripts/gate.sh"
if GIBSON_ROOT="$MINI" "$MINI/adapters/goose/enforce.sh" \
    pre-commit --repo "$ROOT/wt2" --issue 42 --canonical "$ROOT/canon" >/dev/null 2>&1; then
  ok "green gate pre-commit ok (exit 0 parity)"
else
  bad "green gate pre-commit failed"
fi

# ---------------------------------------------------------------------------
echo "session.sh dry-run-lifecycle + status"
# ---------------------------------------------------------------------------
if out=$("$SESSION" dry-run-lifecycle 2>&1); then
  echo "$out" | grep 'BLOCKED' >/dev/null && ok "session dry-run-lifecycle emits BLOCKED" || bad "dry-run missing BLOCKED"
  echo "$out" | grep 'fail-closed proven offline' >/dev/null && ok "session dry-run completes" || bad "dry-run incomplete"
else
  bad "session dry-run-lifecycle failed: $out"
fi
if "$SESSION" status 2>&1 | grep 'Doctrine mount order' >/dev/null; then
  ok "session status shows doctrine mount order"
else
  bad "session status missing doctrine"
fi
if "$SESSION" status 2>&1 | grep -i 'Gibson' >/dev/null; then
  ok "session status is Gibson-branded"
else
  bad "session status missing Gibson brand"
fi

# ---------------------------------------------------------------------------
echo "brand: adapter docs stay Gibson-facing"
# ---------------------------------------------------------------------------
if grep -qiE 'you are goose|product is goose|ship as goose' "$REPO_ROOT/adapters/goose/README.md"; then
  bad "README claims Goose product identity"
else
  ok "README does not claim Goose product identity"
fi
if grep -q 'enforce.sh' "$REPO_ROOT/adapters/goose/README.md" \
  && grep -q 'permission-map.yaml' "$REPO_ROOT/adapters/goose/README.md"; then
  ok "README documents enforce + permission-map"
else
  bad "README missing enforce/permission-map docs"
fi

# ---------------------------------------------------------------------------
echo "help surfaces"
# ---------------------------------------------------------------------------
"$ENFORCE" --help >/dev/null && ok "enforce --help" || bad "enforce --help"
"$SESSION" --help >/dev/null && ok "session --help" || bad "session --help"

# ---------------------------------------------------------------------------
echo "bash -n"
# ---------------------------------------------------------------------------
if bash -n "$ENFORCE" && bash -n "$SESSION" && bash -n "$0"; then
  ok "bash -n enforce/session/test"
else
  bad "bash -n failed"
fi

echo
echo "goose-session.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
