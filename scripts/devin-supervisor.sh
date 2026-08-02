#!/usr/bin/env bash
# devin-supervisor.sh — persistent Devin cloud supervisor (docs/22)
set -euo pipefail

usage() {
  cat <<'EOF'
devin-supervisor.sh — one long-lived Devin cloud session that reviews finished
work and owns GitHub (PR, CI, merge) for a target repo

WHAT IT DOES
  ensure   get-or-create the supervisor session for this repo; if the cached
           session ended, wake a fresh one via the Devin webhook automation,
           falling back to the sessions API
  status   print the cached session id, URL, and live status
  wake     force the webhook wake path (used by cron, CI, or the loop driver)
  handoff  send a branch to the supervisor: review this diff, open/refresh the
           PR, keep CI green, merge if --merge. When --sha is supplied the
           remote tip of --branch must exist and match it, and the supervisor is
           instructed to reject the handoff if it moves afterwards (issue #55
           pin). --base defaults to main here; loop.sh always passes the target
           repo's resolved default branch, so a repo whose trunk is master is
           never diffed against a missing ref.

WHY
  Iteration is the expensive part and it runs on flat-rate local runners
  (docs/15). The cloud supervisor is paid only for a short, diff-scoped review
  plus the GitHub work — and it is the cross-vendor reviewer that AGENTS.md
  Law 5 and docs/20 rule 1 require, since it never wrote the code.

RISKS
  - Sends the task description, branch name, and diffstat to Devin. Never pass
    secrets in --task (docs/20 rule 6: secrets move by blind pipe).
  - With --merge the supervisor may merge without a human. Omit it for Tier C
    work (AGENTS.md Law 7 — money, auth, PII, security boundaries).
  - Each handoff spends ACUs. Cap it with DEVIN_MAX_ACU (default 10).
  - The session state file lives in <repo>/gibson/devin-session.json; deleting
    it orphans the session rather than closing it.

USAGE
  devin-supervisor.sh ensure  --repo <path>
  devin-supervisor.sh status  --repo <path>
  devin-supervisor.sh wake    --repo <path> [--reason TEXT]
  devin-supervisor.sh handoff --repo <path> --branch NAME [--base main]
                              [--sha SHA] [--base-sha SHA]
                              [--task TEXT | --task-file PATH]
                              [--merge] [--gate-status TEXT] [--review-file PATH]
                              [--wait] [--dry-run]

HANDOFF OPTIONS
  --branch NAME   head branch, already pushed (required)
  --base NAME     base branch the PR opens into (default: main)
  --sha SHA       exact head commit. The remote tip of --branch must exist and
                  still equal it, or the handoff fails (issue #55).
  --base-sha SHA  exact base commit. Requires --sha. When both are given the
                  diffstat is built from <base-sha>...<sha> — the same two
                  endpoints that were reviewed — instead of from the branch
                  names, whose local refs may have moved or gone stale. The
                  branch NAMES are still what the supervisor is told to open the
                  PR between.

ENVIRONMENT
  DEVIN_API_KEY      required — https://app.devin.ai/settings/api-keys
  DEVIN_WEBHOOK_URL  optional — webhook automation that spawns a supervisor
  DEVIN_API_BASE     default https://api.devin.ai
  DEVIN_MAX_ACU      default 10 (per supervisor session)

EXAMPLES
  export DEVIN_API_KEY=...
  ./scripts/devin-supervisor.sh ensure --repo ~/Code/acme-app
  ./scripts/devin-supervisor.sh handoff --repo ~/Code/acme-app \
      --branch gibson/42-password-reset --sha abc123... \
      --task-file gibson/issue-42.md --wait
EOF
}

CMD="${1:-}"
[[ -z "$CMD" || "$CMD" == "-h" || "$CMD" == "--help" ]] && { usage; exit 0; }
shift || true

REPO=""
BRANCH=""
BASE="main"
SHA=""
BASE_SHA=""
TASK=""
TASK_FILE=""
REVIEW_FILE=""
GATE_STATUS=""
REASON="supervisor session ended"
MERGE=0
WAIT=0
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
    --base-sha) BASE_SHA="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;;
    --task-file) TASK_FILE="$2"; shift 2 ;;
    --review-file) REVIEW_FILE="$2"; shift 2 ;;
    --gate-status) GATE_STATUS="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --merge) MERGE=1; shift ;;
    --wait) WAIT=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "devin-supervisor.sh: ERROR: $*" >&2; exit 1; }
info() { echo "devin-supervisor.sh: $*" >&2; }

[[ -n "$REPO" ]] || { usage; exit 2; }
[[ -d "$REPO" ]] || die "repo not a directory: $REPO"
[[ -n "${DEVIN_API_KEY:-}" || "$DRY" -eq 1 ]] || die "DEVIN_API_KEY is not set (https://app.devin.ai/settings/api-keys)"
command -v curl >/dev/null || die "curl not found"
command -v node >/dev/null || die "node not found (scripts use plain node for JSON)"

API="${DEVIN_API_BASE:-https://api.devin.ai}"
MAX_ACU="${DEVIN_MAX_ACU:-10}"
STATE_DIR="$REPO/gibson"
STATE_FILE="$STATE_DIR/devin-session.json"
mkdir -p "$STATE_DIR"

SLUG=$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#(git@[^:]+:|https?://[^/]+/)##; s/\.git$//' || true)
[[ -n "$SLUG" ]] || SLUG="$(basename "$REPO")"

json_get() {
  node -e '
    const [raw, path] = process.argv.slice(1);
    let cur; try { cur = JSON.parse(raw); } catch { process.exit(0); }
    for (const key of path.split(".")) {
      if (cur == null) break;
      cur = cur[key];
    }
    if (cur !== undefined && cur !== null) process.stdout.write(String(cur));
  ' "$1" "$2"
}

api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$API$path" \
      -H "Authorization: Bearer $DEVIN_API_KEY" \
      -H 'content-type: application/json' \
      -d "$body"
  else
    curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $DEVIN_API_KEY"
  fi
}

cached_id() { [[ -f "$STATE_FILE" ]] && json_get "$(cat "$STATE_FILE")" session_id || true; }

save_state() {
  node -e '
    const fs = require("fs");
    const [file, session_id, url] = process.argv.slice(1);
    fs.writeFileSync(file, JSON.stringify({ session_id, url, saved_at: new Date().toISOString() }, null, 2) + "\n");
  ' "$STATE_FILE" "$1" "$2"
}

session_status() {
  local resp
  resp=$(api GET "/v1/sessions/$1" || true)
  json_get "$resp" status_enum
}

session_pr() { json_get "$(api GET "/v1/sessions/$1" || true)" pull_request.url; }

alive() {
  case "$1" in
    working|blocked|resumed|resume_requested|resume_requested_frontend) return 0 ;;
    *) return 1 ;;
  esac
}

merge_clause() {
  if [[ "$MERGE" -eq 1 ]]; then
    echo "merge it once every required check is green (never before — docs/20 rule 4)."
  else
    echo "leave it green and ready; a human owns the merge (AGENTS.md Law 7)."
  fi
}

bootstrap_prompt() {
  cat <<EOF
You are the persistent Devin cloud supervisor for \`$SLUG\`, dispatched by The Gibson
harness (docs/20 coordinator pattern, docs/22).

Standing responsibilities:
1. Review diffs that local runners (Grok, Codex, Claude) hand you. They already passed
   the target repo's green gate locally, so review for correctness, security, scope, and
   spec fidelity — not style nits. You did not write this code, which is exactly why you
   are the reviewer (AGENTS.md Law 5).
2. A runner's PASS is a claim, not proof (docs/20 rule 2): re-read the diff and confirm
   the checks actually ran.
3. Own GitHub: push/refresh branches, open and update pull requests with a high-signal
   description, answer review comments, keep CI green, and $(merge_clause)
4. Stay economical: keep each review scoped to the diff you are given. Do not explore
   the whole repository unless the diff requires it, and do not start unrelated work.
5. Stop and ask a human for anything on the human-gate list (docs/14): destructive or
   irreversible changes, money, outward-facing publishing, ambiguous scope, credentials.
6. When a handoff includes a pinned SHA, verify that the remote tip of the branch still
   matches that SHA before opening or merging the PR. If it has moved, reject the
   handoff and report the mismatch (issue #55).

You will receive one follow-up message per finished task, each naming a branch that is
already pushed. Wait for those messages; do not go looking for work.
EOF
}

create_session() {
  local prompt payload resp id url
  prompt=$(bootstrap_prompt)
  payload=$(node -e '
    const [prompt, title, maxAcu] = process.argv.slice(1);
    process.stdout.write(JSON.stringify({
      prompt,
      title,
      tags: ["gibson", "supervisor"],
      max_acu_limit: Number(maxAcu) || undefined,
    }));
  ' "$prompt" "gibson supervisor: $SLUG" "$MAX_ACU")
  resp=$(api POST "/v1/sessions" "$payload")
  id=$(json_get "$resp" session_id)
  url=$(json_get "$resp" url)
  [[ -n "$id" ]] || die "could not create supervisor session: $resp"
  save_state "$id" "$url"
  info "created supervisor $id ($url)"
  echo "$id"
}

fire_webhook() {
  [[ -n "${DEVIN_WEBHOOK_URL:-}" ]] || return 1
  local body
  body=$(node -e '
    const [reason, slug, repo, prompt] = process.argv.slice(1);
    process.stdout.write(JSON.stringify({ source: "gibson/devin-supervisor.sh", reason, slug, repo, prompt }));
  ' "$REASON" "$SLUG" "$REPO" "$(bootstrap_prompt)")
  curl -sS -X POST "$DEVIN_WEBHOOK_URL" -H 'content-type: application/json' -d "$body" >/dev/null
}

webhook_session() {
  local previous="$1" attempts="${2:-10}" resp
  for _ in $(seq 1 "$attempts"); do
    sleep 15
    resp=$(api GET "/v1/sessions?limit=20" || true)
    local found
    found=$(node -e '
      const [raw, previous] = process.argv.slice(1);
      let data; try { data = JSON.parse(raw); } catch { process.exit(0); }
      const live = new Set(["working", "blocked", "resumed", "resume_requested"]);
      const hit = (data.sessions || []).find((s) =>
        s.session_id !== previous &&
        (s.tags || []).includes("gibson") &&
        live.has(s.status_enum || s.status));
      if (hit) {
        const url = hit.url || `https://app.devin.ai/sessions/${hit.session_id.replace(/^devin-/, "")}`;
        process.stdout.write(`${hit.session_id} ${url}`);
      }
    ' "$resp" "$previous")
    if [[ -n "$found" ]]; then
      save_state "${found%% *}" "${found#* }"
      echo "${found%% *}"
      return 0
    fi
  done
  return 1
}

ensure_session() {
  local id status woken
  id=$(cached_id)
  if [[ -n "$id" ]]; then
    status=$(session_status "$id")
    if alive "$status"; then
      echo "$id"
      return 0
    fi
    info "cached session $id is '${status:-unknown}' — waking a replacement"
    if fire_webhook; then
      if woken=$(webhook_session "$id"); then
        info "webhook woke $woken"
        echo "$woken"
        return 0
      fi
      info "webhook fired but no session appeared — falling back to the API"
    fi
  fi
  create_session
}

case "$CMD" in
  ensure)
    id=$(ensure_session)
    echo "$id $(json_get "$(cat "$STATE_FILE")" url)"
    ;;

  status)
    id=$(cached_id)
    [[ -n "$id" ]] || { echo "no supervisor session cached for $SLUG"; exit 0; }
    echo "session: $id"
    echo "url:     $(json_get "$(cat "$STATE_FILE")" url)"
    echo "status:  $(session_status "$id")"
    pr=$(session_pr "$id")
    [[ -z "$pr" ]] || echo "pr:      $pr"
    ;;

  wake)
    if fire_webhook; then
      info "webhook fired (reason: $REASON)"
      if id=$(webhook_session "$(cached_id)"); then echo "$id"; exit 0; fi
      info "no session from the webhook — creating one directly"
    else
      info "DEVIN_WEBHOOK_URL unset — creating a session directly"
    fi
    create_session >/dev/null
    json_get "$(cat "$STATE_FILE")" session_id
    ;;

  handoff)
    [[ -n "$BRANCH" ]] || die "--branch is required for handoff"
    [[ -n "$TASK_FILE" ]] && TASK=$(cat "$TASK_FILE")
    [[ -n "$TASK" ]] || die "--task or --task-file is required for handoff"
    REVIEWS=""
    [[ -n "$REVIEW_FILE" && -f "$REVIEW_FILE" ]] && REVIEWS=$(cat "$REVIEW_FILE")

    [[ -z "$BASE_SHA" || -n "$SHA" ]] || die "--base-sha requires --sha: half a pin describes half a diff"

    # Issue #55: when a SHA is pinned, the remote tip must exist and match it.
    # Every miss is fatal, not a warning. The supervisor opens the PR from the
    # REMOTE branch, so "origin has no such branch" or "cannot reach origin"
    # means the thing being handed off is not the thing that was reviewed — and
    # proceeding on the pin alone would send the supervisor after a branch it
    # cannot find, or one that has since been rewritten.
    if [[ -n "$SHA" ]]; then
      git -C "$REPO" remote get-url origin >/dev/null 2>&1 ||
        die "no origin configured in $REPO, so the pinned SHA $SHA cannot be confirmed against a remote branch. A pinned handoff needs a pushed branch."
      # NR==1: ls-remote for an exact ref should print one line, but a server
      # that also advertises a peeled tag or a same-named ref would append more.
      # Comparing a pin against a concatenation of SHAs always "mismatches".
      ls_out=$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" 2>/dev/null) ||
        die "git ls-remote origin refs/heads/$BRANCH failed — cannot confirm the remote tip of $BRANCH against the pinned SHA $SHA."
      remote_sha=$(printf '%s\n' "$ls_out" | awk 'NR==1 {print $1}')
      if [[ -z "$remote_sha" ]]; then
        die "origin has no refs/heads/$BRANCH — the branch was never pushed, so there is nothing for the supervisor to open a PR from. Push it, then re-run the handoff."
      fi
      if [[ "$remote_sha" != "$SHA" ]]; then
        die "pinned SHA $SHA no longer matches remote tip of $BRANCH ($remote_sha). Re-review the new tip before handoff."
      fi
    fi

    # The diffstat must describe the diff that was reviewed. Branch names are
    # moving targets and this clone's copies of them may be stale, so when both
    # exact endpoints are supplied the diffstat comes from those commits and
    # never from a local ref. If either object is missing from this clone we say
    # so plainly rather than substituting a different, readable diff — in the
    # loop.sh path both were fetched and verified before the review ran.
    if [[ -n "$BASE_SHA" && -n "$SHA" ]]; then
      if git -C "$REPO" rev-parse --verify --quiet "$BASE_SHA^{commit}" >/dev/null 2>&1 &&
         git -C "$REPO" rev-parse --verify --quiet "$SHA^{commit}" >/dev/null 2>&1; then
        DIFFSTAT=$(git -C "$REPO" diff --stat "$BASE_SHA...$SHA" 2>/dev/null || echo "n/a")
      else
        info "commits $BASE_SHA and/or $SHA are not in $REPO — reporting the diffstat as n/a rather than substituting a local-branch diff"
        DIFFSTAT="n/a — $BASE_SHA...$SHA is not readable in the handing-off clone; generate the diff yourself from the remote."
      fi
    else
      DIFFSTAT=$(git -C "$REPO" diff --stat "$BASE...$BRANCH" 2>/dev/null || echo "n/a")
    fi
    if [[ "$DRY" -eq 0 ]]; then id=$(ensure_session); else id="(dry-run)"; fi

    # Concatenated rather than heredoc'd because the base line is conditional:
    # the clause must start with a newline and end without one, exactly as the
    # MESSAGE template below expects.
    SHA_CLAUSE=""
    if [[ -n "$SHA" ]]; then
      SHA_CLAUSE="
## Pinned head (issue #55)
- Expected SHA: \`$SHA\`"
      if [[ -n "$BASE_SHA" ]]; then
        SHA_CLAUSE="$SHA_CLAUSE
- Reviewed against base commit: \`$BASE_SHA\` — the diffstat below is exactly \`$BASE_SHA...$SHA\`, the diff that was reviewed."
      fi
      SHA_CLAUSE="$SHA_CLAUSE
- Before opening or merging the PR, confirm that the tip of \`$BRANCH\` on the remote is still exactly this SHA. If it has moved, reject the handoff and report the mismatch — do not review or merge a different tip."
    fi

    MESSAGE=$(cat <<EOF
New candidate from the Gibson loop.

- Repository: \`$SLUG\`
- Branch: \`$BRANCH\` (pushed)
- Base: \`$BASE\`
- Local green gate: ${GATE_STATUS:-passed locally}
$SHA_CLAUSE
## Task
$TASK

## Diffstat
\`\`\`
$DIFFSTAT
\`\`\`
$([[ -n "$REVIEWS" ]] && printf '\n## Cross-vendor second opinion\n%s\n' "$REVIEWS")
## What to do
1. Review \`$BRANCH\` against \`$BASE\`: correctness, security, scope, spec fidelity.
   Re-verify the checks rather than trusting the runner's PASS (docs/20 rule 2).
2. Fix anything clearly wrong yourself, minimally and inside the diff's scope.
3. Open or update the pull request into \`$BASE\` with a high-signal description.
4. Wait for every required check, then $(merge_clause)
5. Reply with the PR URL and a one-line verdict.

If the change is fundamentally wrong, say so and stop instead of rewriting it.
EOF
)
    if [[ "$DRY" -eq 1 ]]; then
      echo "$MESSAGE"
      exit 0
    fi

    body=$(node -e 'process.stdout.write(JSON.stringify({ message: process.argv[1] }))' "$MESSAGE")
    api POST "/v1/sessions/$id/message" "$body" >/dev/null
    info "handed off $BRANCH${SHA:+ @$SHA} to $id"
    echo "$(json_get "$(cat "$STATE_FILE")" url)"

    if [[ "$WAIT" -eq 1 ]]; then
      info "waiting for the supervisor to finish…"
      while true; do
        sleep 30
        st=$(session_status "$id")
        [[ "$st" == "working" || "$st" == "resuming" || -z "$st" ]] || break
      done
      info "supervisor status: $st"
      pr=$(session_pr "$id")
      [[ -z "$pr" ]] || echo "$pr"
    fi
    ;;

  *) die "unknown command: $CMD (try --help)" ;;
esac
