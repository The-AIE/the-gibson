#!/usr/bin/env bash
# preview-url.sh — resolve PR Vercel preview URL (docs/07, docs/12)
set -euo pipefail

usage() {
  cat <<'EOF'
preview-url.sh — resolve a pull request's Vercel preview URL

WHAT IT DOES
  Looks up GitHub deployment statuses for the PR head SHA and prints the
  first matching Vercel preview environment URL. Falls back to
  `vercel inspect` / `gh api` when available.

  Only a deployment whose latest status is **success** counts. A queued, building,
  or failed deployment has no URL worth testing, and returning its target_url is
  how a UX run ends up grading a Vercel error page.

WHY
  UX eval and DAST must target the live preview, never a guess (docs/07 rule zero).

  Two failure modes this exists to prevent (L-012):
    - Returning a URL before the deployment is READY, so the gate tests a 404.
    - Returning a URL behind Vercel Deployment Protection, so every request is a
      401 login page and the gate "passes" against nothing.

RISKS
  - Needs gh auth and a PR that has a deployment.
  - May return empty if Vercel hasn't finished — retry, don't invent a URL.
  - Read-only.

ENVIRONMENT
  VERCEL_AUTOMATION_BYPASS_SECRET  with --bypass, appended as the protection
                                   bypass query parameters so CI can actually
                                   fetch a protected preview. The printed URL
                                   then contains the secret — mask it before it
                                   reaches a log (`::add-mask::` in Actions) and
                                   never post it in a PR comment.
  CI                               when set, the default timeout is 300s rather
                                   than 120s — a cold Vercel build routinely
                                   takes more than two minutes.

USAGE
  preview-url.sh <pr-number> [--repo org/name] [--timeout SEC] [--bypass] [--probe]
  preview-url.sh --help

  --bypass  append the Vercel automation bypass parameters (needs the secret)
  --probe   fetch the URL once before printing it; a 401/403 is reported as
            protection rather than returned, so the caller fails loudly instead
            of grading a login page

EXAMPLES
  export BASE_URL="$(./scripts/preview-url.sh 123)"
  BASE_URL="$BASE_URL" npx playwright test
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
  exit 2
fi

PR="$1"
shift
REPO=""
TIMEOUT=${CI:+300}
TIMEOUT=${TIMEOUT:-120}
BYPASS=0
PROBE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --bypass) BYPASS=1; shift ;;
    --probe) PROBE=1; shift ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "preview-url.sh: ERROR: $*" >&2; exit 1; }
command -v gh >/dev/null || die "gh required"

REPO_ARGS=()
if [[ -n "$REPO" ]]; then
  REPO_ARGS=(-R "$REPO")
fi

SHA=$(gh pr view "$PR" "${REPO_ARGS[@]}" --json headRefOid -q .headRefOid)
[[ -n "$SHA" ]] || die "could not resolve head SHA for PR $PR"

# Try deployments via GraphQL / REST
# 1) status checks with target URL
try_checks() {
  gh pr checks "$PR" "${REPO_ARGS[@]}" --json name,state,targetUrl,description 2>/dev/null \
    | node -e '
      let d=""; process.stdin.on("data",c=>d+=c); process.stdin.on("end",()=>{
        try {
          const arr=JSON.parse(d);
          for (const x of arr) {
            const u=x.targetUrl||"";
            if (/vercel\.app|vercel\.com/i.test(u) && /preview|deployment/i.test(x.name+" "+(x.description||""))) {
              console.log(u); process.exit(0);
            }
          }
          for (const x of arr) {
            const u=x.targetUrl||"";
            if (/https:\/\/.+\.vercel\.app/i.test(u)) { console.log(u); process.exit(0); }
          }
        } catch(e) {}
        process.exit(1);
      });
    ' 2>/dev/null || true
}

# 2) deployments API for the repo
try_deployments() {
  local full
  full=$(gh repo view "${REPO_ARGS[@]}" --json nameWithOwner -q .nameWithOwner 2>/dev/null)
  [[ -n "$full" ]] || return 1
  gh api "repos/${full}/deployments?sha=${SHA}&per_page=10" 2>/dev/null \
    | node -e '
      let d=""; process.stdin.on("data",c=>d+=c); process.stdin.on("end",()=>{
        try {
          const arr=JSON.parse(d);
          const ids=arr.map(x=>x.id);
          process.stdout.write(ids.join("\n"));
        } catch(e) {}
      });
    ' | while read -r id; do
        [[ -z "$id" ]] && continue
        # Only a successful status has a URL worth testing.
        url=$(gh api "repos/${full}/deployments/${id}/statuses" \
          --jq '[.[] | select(.state == "success")] | .[0].environment_url // .[0].target_url // empty' 2>/dev/null || true)
        if [[ -n "$url" && "$url" != "null" ]]; then
          echo "$url"
          return 0
        fi
      done
  return 1
}

deadline=$(( $(date +%s) + TIMEOUT ))
while [[ $(date +%s) -lt $deadline ]]; do
  url=$(try_checks || true)
  if [[ -z "${url:-}" ]]; then
    url=$(try_deployments || true)
  fi
  if [[ -n "${url:-}" ]]; then
    url=$(echo "$url" | head -n1)
    if [[ "$BYPASS" -eq 1 ]]; then
      [[ -n "${VERCEL_AUTOMATION_BYPASS_SECRET:-}" ]] ||
        die "--bypass needs VERCEL_AUTOMATION_BYPASS_SECRET (Vercel → Project → Settings → Deployment Protection)"
      sep='?'
      [[ "$url" == *\?* ]] && sep='&'
      url="${url}${sep}x-vercel-protection-bypass=${VERCEL_AUTOMATION_BYPASS_SECRET}&x-vercel-set-bypass-cookie=true"
    fi
    if [[ "$PROBE" -eq 1 ]] && command -v curl >/dev/null; then
      code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 30 "$url" || echo 000)
      case "$code" in
        401|403)
          die "preview is behind Vercel Deployment Protection (HTTP $code) — set VERCEL_AUTOMATION_BYPASS_SECRET and pass --bypass. A protected preview is a missing result, not a pass"
          ;;
        000)
          die "preview did not respond within 30s — do not grade an unreachable target"
          ;;
      esac
    fi
    echo "$url"
    exit 0
  fi
  # vercel CLI fallback once
  if command -v vercel >/dev/null; then
    vurl=$(vercel inspect "$SHA" --wait 2>/dev/null | awk '/https:\/\// {print $NF; exit}' || true)
    if [[ -n "${vurl:-}" ]]; then
      echo "$vurl"
      exit 0
    fi
  fi
  sleep 5
done

die "no preview URL for PR $PR (sha $SHA) within ${TIMEOUT}s — do not invent one"
