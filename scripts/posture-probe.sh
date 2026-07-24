#!/usr/bin/env bash
# posture-probe.sh — runtime posture vs. URL (docs/08 layer 8)
set -euo pipefail

usage() {
  cat <<'EOF'
posture-probe.sh — assert security headers, cookies, and basic rate limits

WHAT IT DOES
  GETs a URL and checks response headers (CSP, HSTS, X-Frame-Options /
  frame-ancestors, etc.), Set-Cookie flags on any cookies, and optionally
  bursts a public POST path expecting HTTP 429 after N requests.

WHY
  Layer 8 hard-fail on regression: posture can drift from platform config
  changes even when no PR caused it (docs/08).

RISKS
  - Generates a short request burst (rate-limit test) — use on preview/staging,
    never load-test production carelessly.
  - Network required. Failures are exit codes for CI.

USAGE
  posture-probe.sh <url> [--post-path /api/...] [--burst N] [--no-burst]
  posture-probe.sh --help

EXAMPLES
  ./scripts/posture-probe.sh https://my-app-git-feat-42.vercel.app
  ./scripts/posture-probe.sh https://staging.example.com --post-path /api/contact --burst 30
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
  exit 2
fi

URL="$1"
shift
POST_PATH=""
BURST=25
DO_BURST=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --post-path) POST_PATH="$2"; shift 2 ;;
    --burst) BURST="$2"; shift 2 ;;
    --no-burst) DO_BURST=0; shift ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "posture-probe: FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "posture-probe: OK: $*"; }
FAILS=0

command -v curl >/dev/null || { echo "curl required" >&2; exit 2; }

TMP=$(mktemp)
HDR=$(mktemp)
trap 'rm -f "$TMP" "$HDR"' EXIT

code=$(curl -sS -D "$HDR" -o "$TMP" -w "%{http_code}" --max-time 30 "$URL" || echo "000")
if [[ "$code" == "000" ]]; then
  echo "posture-probe: ERROR: could not fetch $URL" >&2
  exit 2
fi
echo "posture-probe: GET $URL → $code"

# Normalize headers to lowercase names for matching
headers_lc=$(tr -d '\r' < "$HDR" | awk 'BEGIN{IGNORECASE=1} {print tolower($0)}')

has_header() {
  echo "$headers_lc" | grep -qiE "^$1:"
}
header_val() {
  echo "$headers_lc" | awk -F': ' -v k="$(echo "$1" | tr '[:upper:]' '[:lower:]')" 'tolower($1)==k {print $2; exit}'
}

# CSP
if has_header "content-security-policy"; then
  ok "Content-Security-Policy present"
else
  die "missing Content-Security-Policy"
fi

# HSTS (critical on https)
case "$URL" in
  https://*)
    if has_header "strict-transport-security"; then
      ok "Strict-Transport-Security present"
    else
      die "missing Strict-Transport-Security on https URL"
    fi
    ;;
esac

# Frame protection: X-FO or CSP frame-ancestors
csp=$(header_val "content-security-policy")
if has_header "x-frame-options"; then
  ok "X-Frame-Options present"
elif echo "$csp" | grep -qi "frame-ancestors"; then
  ok "CSP frame-ancestors present"
else
  die "missing frame protection (X-Frame-Options or CSP frame-ancestors)"
fi

# nosniff
if has_header "x-content-type-options"; then
  xcto=$(header_val "x-content-type-options")
  if echo "$xcto" | grep -qi "nosniff"; then
    ok "X-Content-Type-Options: nosniff"
  else
    die "X-Content-Type-Options present but not nosniff"
  fi
else
  die "missing X-Content-Type-Options"
fi

# Cookies
if grep -qi '^set-cookie:' "$HDR"; then
  while IFS= read -r line; do
    low=$(echo "$line" | tr '[:upper:]' '[:lower:]')
    echo "$low" | grep -q 'httponly' || die "cookie missing HttpOnly: $line"
    case "$URL" in https://*)
      echo "$low" | grep -q 'secure' || die "cookie missing Secure: $line"
      ;;
    esac
    echo "$low" | grep -qE 'samesite=(lax|strict|none)' || die "cookie missing SameSite: $line"
  done < <(tr -d '\r' < "$HDR" | grep -i '^set-cookie:')
  ok "Set-Cookie flags checked"
else
  ok "no Set-Cookie on this response (skip cookie flags)"
fi

# Optional burst rate limit
if [[ "$DO_BURST" -eq 1 && -n "$POST_PATH" ]]; then
  base=$(echo "$URL" | sed -E 's#(https?://[^/]+).*#\1#')
  target="${base}${POST_PATH}"
  echo "posture-probe: bursting POST $target x$BURST"
  got429=0
  for i in $(seq 1 "$BURST"); do
    c=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -X POST "$target" || echo 000)
    if [[ "$c" == "429" ]]; then got429=1; break; fi
  done
  if [[ "$got429" -eq 1 ]]; then
    ok "received 429 under burst (rate limit appears active)"
  else
    die "no 429 after $BURST POSTs to $POST_PATH (rate limit missing? ConferenceOS gap class)"
  fi
elif [[ "$DO_BURST" -eq 1 ]]; then
  echo "posture-probe: skip burst (pass --post-path to enable)"
fi

if [[ "$FAILS" -gt 0 ]]; then
  echo "posture-probe: $FAILS failure(s)"
  exit 1
fi
echo "posture-probe: GREEN"
exit 0
