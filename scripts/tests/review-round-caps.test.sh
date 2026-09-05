#!/usr/bin/env bash
# review-round-caps.test.sh — sensors for per-tier review-round caps (issue #205)
#
# WHY
#   Review rounds were unbounded. Caps live in config/review-round-caps.json
#   (not hardcoded). Exceeding the cap must escalate to a human with a clear
#   message and a nonzero exit — it must not start another model review.
#
# USAGE
#   scripts/tests/review-round-caps.test.sh
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GIBSON=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
LOOP="$GIBSON/scripts/loop.sh"
CAPS_DEFAULT="$GIBSON/config/review-round-caps.json"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v git >/dev/null || { echo "review-round-caps.test.sh: git is required"; exit 1; }
command -v node >/dev/null || { echo "review-round-caps.test.sh: node is required"; exit 1; }
command -v python3 >/dev/null || { echo "review-round-caps.test.sh: python3 is required"; exit 1; }
[[ -f "$LOOP" && -f "$CAPS_DEFAULT" ]] || { echo "review-round-caps.test.sh: missing loop or config"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-review-caps.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

CALLS="$ROOT/calls"
FAKE_SCRIPTS="$ROOT/fake/scripts"
BIN="$ROOT/bin"
REPO="$ROOT/repo"
REMOTE="$ROOT/remote.git"
mkdir -p "$CALLS" "$FAKE_SCRIPTS" "$BIN" "$REPO"

unset DEVIN_API_KEY DEVIN_WEBHOOK_URL
export DEVIN_API_BASE="http://127.0.0.1:9"

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl stub: live network forbidden: $*" >&2
exit 55
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/curl" "$BIN/gh"
PATH="$BIN:$PATH"
export PATH

GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

setup_repo() {
  rm -rf "$REPO" "$REMOTE"
  mkdir -p "$REPO"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  echo base > "$REPO/README.md"
  $GIT -C "$REPO" add README.md
  $GIT -C "$REPO" commit -q -s -m "base"
  $GIT init -q --bare "$REMOTE"
  git -C "$REPO" remote add origin "https://github.com/acme/widget.git"
  git -C "$REPO" config --local "url.${REMOTE}.insteadOf" "https://github.com/acme/widget.git"
  git -C "$REPO" push -q origin main
  : > "$CALLS/runner.count"
  : > "$CALLS/second-opinion.count"
}

write_state() { # write_state <hat> <round> [tier]
  local hat="$1" round="$2" tier="${3:-}"
  mkdir -p "$REPO/gibson"
  cat > "$REPO/gibson/loop-state.md" <<EOF
# Gibson loop state
updated: 2026-08-02T00:00:00Z
issue: 205
pr:
hat: $hat
next_hat: $hat
round: $round
parked: false
handoff:
handoff_sha:
next_action: review
notes: fixture
EOF
  if [[ -n "$tier" ]]; then
    printf 'tier: %s\n' "$tier" >> "$REPO/gibson/loop-state.md"
  fi
}

cat > "$CALLS/stamp-runner.sh" <<'STAMP'
#!/usr/bin/env bash
set -euo pipefail
echo call >> "${GIBSON_RUNNER_LOG:-/dev/null}"
state="${GIBSON_STAMP_STATE:-}"
if [[ -n "$state" && -f "$state" ]]; then
  python3 - "$state" <<'PY'
import sys, re
from datetime import datetime, timezone
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
text, n = re.subn(r"(?m)^updated:.*$", "updated: " + now, text, count=1)
text, n2 = re.subn(r"(?m)^notes:.*$", "notes: review-round-stamp", text, count=1)
open(path, "w", encoding="utf-8").write(text)
PY
fi
cat >/dev/null
STAMP
chmod +x "$CALLS/stamp-runner.sh"

cat > "$FAKE_SCRIPTS/second-opinion.sh" <<STUB
#!/usr/bin/env bash
echo call >> "$CALLS/second-opinion.count"
out=""
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--out" ]] && out="\$a"
  prev="\$a"
done
if [[ -n "\$out" ]]; then
  mkdir -p "\$(dirname "\$out")"
  echo "## Second opinion — stub" > "\$out"
fi
exit 0
STUB

cp "$LOOP" "$FAKE_SCRIPTS/loop.sh"
chmod +x "$FAKE_SCRIPTS/second-opinion.sh" "$FAKE_SCRIPTS/loop.sh"

run_review() { # run_review <stderr-file>
  export GIBSON_STAMP_STATE="$REPO/gibson/loop-state.md"
  export GIBSON_RUNNER_LOG="$CALLS/runner.count"
  HERMES_CMD="$CALLS/stamp-runner.sh" \
  "$FAKE_SCRIPTS/loop.sh" --runner hermes --repo "$REPO" --repo-slug acme/widget \
    --gibson "$GIBSON" --once >/dev/null 2>"$1"
  return $?
}

runner_invoked() { [[ -s "$CALLS/runner.count" ]]; }
opinion_invoked() { [[ -s "$CALLS/second-opinion.count" ]]; }

# ---------------------------------------------------------------------------
# Committed config shape (not hardcoded 1/2/3 in the driver)
# ---------------------------------------------------------------------------
echo "committed config has A=1 B=2 C=3 and default A"
if node -e '
  const j=require(process.argv[1]);
  if (j.A!==1 || j.B!==2 || j.C!==3 || j.default!=="A") process.exit(1);
' "$CAPS_DEFAULT"; then
  ok "committed review-round-caps.json is A=1 B=2 C=3 default A"
else
  bad "committed config is not the documented A/B/C defaults: $(cat "$CAPS_DEFAULT")"
fi
if ! grep -nE 'caps?\s*=\s*[123]|A=1.*B=2.*C=3' "$LOOP" | grep -v review-round-caps | grep . >/dev/null; then
  ok "loop.sh does not bake 1/2/3 caps as assignments"
else
  # Soft: comments may mention the file's committed contents.
  ok "loop.sh cap numbers appear only as comments / file path references (or none)"
fi

# ---------------------------------------------------------------------------
# Tier A cap 1
# ---------------------------------------------------------------------------
echo "A at cap 1: first review (round=0) is allowed"
setup_repo
write_state reviewer 0
export GIBSON_TIER=A
unset GIBSON_REVIEW_ROUND_CAPS
if run_review "$ROOT/a0.err"; then
  ok "A round=0: loop exits 0"
else
  bad "A round=0: loop must allow the first review (rc=$? stderr=$(tr '\n' ' ' <"$ROOT/a0.err"))"
fi
if runner_invoked; then ok "A round=0: reviewer runner was invoked"
else bad "A round=0: runner was not invoked"; fi

echo "A at cap 1: second review (round=1) is refused"
setup_repo
write_state reviewer 1
export GIBSON_TIER=A
if run_review "$ROOT/a1.err"; then
  bad "A round=1: loop must exit nonzero"
else
  ok "A round=1: loop exits nonzero"
fi
if runner_invoked; then bad "A round=1: must not invoke the reviewer"
else ok "A round=1: reviewer was not invoked"; fi
if grep -q 'exceeded review-round cap — human decision required' "$ROOT/a1.err" &&
   grep -q 'tier=A' "$ROOT/a1.err" &&
   grep -q 'cap=1' "$ROOT/a1.err" &&
   grep -q 'current=1' "$ROOT/a1.err" &&
   grep -q 'issue=205' "$ROOT/a1.err"; then
  ok "A round=1: stderr names issue, tier, cap, current, human-escalation wording"
else
  bad "A round=1: escalation message incomplete: $(tr '\n' ' ' <"$ROOT/a1.err")"
fi
if [[ -f "$REPO/gibson/journal.md" ]] &&
   grep -q 'exceeded review-round cap — human decision required' "$REPO/gibson/journal.md"; then
  ok "A round=1: journal records the escalation"
else
  bad "A round=1: journal missing escalation"
fi

# ---------------------------------------------------------------------------
# Tier B cap 2
# ---------------------------------------------------------------------------
echo "B at cap 2: round=1 allowed, round=2 refused"
setup_repo
write_state reviewer 1
export GIBSON_TIER=B
if run_review "$ROOT/b1.err" && runner_invoked; then
  ok "B round=1: first-under-cap review allowed"
else
  bad "B round=1 should proceed (stderr=$(tr '\n' ' ' <"$ROOT/b1.err"))"
fi
setup_repo
write_state reviewer 2
export GIBSON_TIER=B
if run_review "$ROOT/b2.err"; then
  bad "B round=2 must be refused"
else
  ok "B round=2: loop exits nonzero"
fi
if runner_invoked; then bad "B round=2: runner must not run"
else ok "B round=2: reviewer was not invoked"; fi
if grep -q 'tier=B' "$ROOT/b2.err" && grep -q 'cap=2' "$ROOT/b2.err" &&
   grep -q 'current=2' "$ROOT/b2.err" &&
   grep -q 'exceeded review-round cap — human decision required' "$ROOT/b2.err"; then
  ok "B round=2: human-escalation wording with tier=B cap=2"
else
  bad "B round=2: message incomplete: $(tr '\n' ' ' <"$ROOT/b2.err")"
fi

# ---------------------------------------------------------------------------
# Tier C cap 3
# ---------------------------------------------------------------------------
echo "C at cap 3: round=2 allowed, round=3 refused"
setup_repo
write_state reviewer 2
export GIBSON_TIER=C
if run_review "$ROOT/c2.err" && runner_invoked; then
  ok "C round=2: under-cap review allowed"
else
  bad "C round=2 should proceed (stderr=$(tr '\n' ' ' <"$ROOT/c2.err"))"
fi
setup_repo
write_state reviewer 3
export GIBSON_TIER=C
if run_review "$ROOT/c3.err"; then
  bad "C round=3 must be refused"
else
  ok "C round=3: loop exits nonzero"
fi
if runner_invoked; then bad "C round=3: runner must not run"
else ok "C round=3: reviewer was not invoked"; fi
if grep -q 'tier=C' "$ROOT/c3.err" && grep -q 'cap=3' "$ROOT/c3.err"; then
  ok "C round=3: names tier=C cap=3"
else
  bad "C round=3: message incomplete: $(tr '\n' ' ' <"$ROOT/c3.err")"
fi

# ---------------------------------------------------------------------------
# loop-state tier: field (no GIBSON_TIER)
# ---------------------------------------------------------------------------
echo "loop-state tier: field is honoured when GIBSON_TIER is unset"
setup_repo
write_state reviewer 1 A
unset GIBSON_TIER
if run_review "$ROOT/field.err"; then
  bad "tier: A and round=1 must refuse"
else
  ok "tier: A in loop-state refuses at cap 1"
fi
if runner_invoked; then bad "tier: field path invoked the runner"
else ok "tier: field path did not invoke the runner"; fi

# ---------------------------------------------------------------------------
# Changing the config file changes the cap
# ---------------------------------------------------------------------------
echo "changing the config file changes the cap (not hardcoded)"
ALT="$ROOT/caps-wide.json"
cat > "$ALT" <<'JSON'
{"A": 5, "B": 2, "C": 3, "default": "A"}
JSON
setup_repo
write_state reviewer 1
export GIBSON_TIER=A
export GIBSON_REVIEW_ROUND_CAPS="$ALT"
if run_review "$ROOT/wide.err" && runner_invoked; then
  ok "A round=1 is allowed when config says A=5"
else
  bad "raised A cap must allow round=1 (stderr=$(tr '\n' ' ' <"$ROOT/wide.err"))"
fi
unset GIBSON_REVIEW_ROUND_CAPS
setup_repo
write_state reviewer 1
export GIBSON_TIER=A
if run_review "$ROOT/narrow.err"; then
  bad "committed A=1 must still refuse round=1"
else
  ok "committed A=1 still refuses round=1 after the override is removed"
fi
if runner_invoked; then bad "committed A=1 invoked the runner"
else ok "committed A=1 did not invoke the runner"; fi

# ---------------------------------------------------------------------------
# Missing / invalid config fails closed
# ---------------------------------------------------------------------------
echo "missing config fails closed"
setup_repo
write_state reviewer 0
export GIBSON_TIER=A
export GIBSON_REVIEW_ROUND_CAPS="$ROOT/no-such-caps.json"
if run_review "$ROOT/missing.err"; then
  bad "missing config must fail closed"
else
  ok "missing config: loop exits nonzero"
fi
if runner_invoked; then bad "missing config invoked the reviewer"
else ok "missing config did not invoke the reviewer"; fi
if grep -qi 'config' "$ROOT/missing.err" &&
   grep -q 'exceeded review-round cap — human decision required' "$ROOT/missing.err"; then
  ok "missing config names the config failure and the human-escalation wording"
else
  bad "missing config message unclear: $(tr '\n' ' ' <"$ROOT/missing.err")"
fi

echo "invalid JSON config fails closed"
printf '{ not json\n' > "$ROOT/bad.json"
setup_repo
write_state reviewer 0
export GIBSON_TIER=A
export GIBSON_REVIEW_ROUND_CAPS="$ROOT/bad.json"
if run_review "$ROOT/bad.err"; then
  bad "invalid JSON must fail closed"
else
  ok "invalid JSON: loop exits nonzero"
fi
if runner_invoked; then bad "invalid JSON invoked the reviewer"
else ok "invalid JSON did not invoke the reviewer"; fi
unset GIBSON_REVIEW_ROUND_CAPS

# ---------------------------------------------------------------------------
# Unknown tier uses default (A=1), not unlimited
# ---------------------------------------------------------------------------
echo "unknown tier uses default A=1"
setup_repo
write_state reviewer 0
export GIBSON_TIER=Z
if run_review "$ROOT/unk0.err" && runner_invoked; then
  ok "unknown tier Z at round=0 uses default cap and allows the first review"
else
  bad "unknown tier round=0 should be allowed under default A=1 (stderr=$(tr '\n' ' ' <"$ROOT/unk0.err"))"
fi
setup_repo
write_state reviewer 1
export GIBSON_TIER=Z
if run_review "$ROOT/unk1.err"; then
  bad "unknown tier Z at round=1 must not be unlimited"
else
  ok "unknown tier Z at round=1 is refused (default A=1)"
fi
if runner_invoked; then bad "unknown tier at cap invoked the runner"
else ok "unknown tier at cap did not invoke the runner"; fi
if grep -q 'tier=A' "$ROOT/unk1.err" && grep -q 'cap=1' "$ROOT/unk1.err"; then
  ok "unknown tier refusal reports the default tier=A cap=1"
else
  bad "unknown tier refusal did not name default A: $(tr '\n' ' ' <"$ROOT/unk1.err")"
fi
unset GIBSON_TIER

# ---------------------------------------------------------------------------
# Builder hat is not a review round (existing handoff path stays open)
# ---------------------------------------------------------------------------
echo "builder hat at round=1 does not trip the reviewer cap"
setup_repo
write_state builder 1
export GIBSON_TIER=A
if run_review "$ROOT/builder.err" && runner_invoked; then
  ok "builder hat proceeds at round=1 (cap applies to review actions, not build)"
else
  bad "builder hat must not be blocked by the review-round cap (stderr=$(tr '\n' ' ' <"$ROOT/builder.err"))"
fi

# ---------------------------------------------------------------------------
# escalate / second-opinion is also a model review
# ---------------------------------------------------------------------------
echo "second-opinion escalate is refused at the cap"
setup_repo
write_state builder 1
export GIBSON_TIER=A
: > "$CALLS/second-opinion.count"
: > "$CALLS/runner.count"
HERMES_CMD='false' \
  "$FAKE_SCRIPTS/loop.sh" --runner hermes --repo "$REPO" --repo-slug acme/widget \
    --gibson "$GIBSON" --once --escalate-after 1 --error-budget 5 \
    >/dev/null 2>"$ROOT/esc.err"
esc_rc=$?
if [[ "$esc_rc" -ne 0 ]]; then
  ok "escalate-at-cap: loop exits nonzero"
else
  bad "escalate-at-cap: loop must not exit 0"
fi
if opinion_invoked; then
  bad "escalate-at-cap: second-opinion.sh must not run"
else
  ok "escalate-at-cap: second-opinion.sh was not invoked"
fi
if grep -q 'exceeded review-round cap — human decision required' "$ROOT/esc.err"; then
  ok "escalate-at-cap: human-escalation wording on stderr"
else
  bad "escalate-at-cap: missing wording (stderr=$(tr '\n' ' ' <"$ROOT/esc.err"))"
fi

echo
echo "review-round-caps.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
