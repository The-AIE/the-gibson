#!/usr/bin/env bash
# goose-recipes.test.sh — offline structural sensors for Goose recipe mirrors
# and the red-team toolchain lock (issue #25 partial slice).
#
# WHY
#   A recipe that validates in prose but drifts on pins, undeclared template
#   variables, or floating versions is not reproducible. This sensor is the
#   required offline green gate: no network, no Goose binary, no paid APIs,
#   no credentials, no mutation outside temp fixtures.
#
# USAGE
#   scripts/tests/goose-recipes.test.sh
#
# OPTIONAL
#   If `goose` is on PATH, also runs `goose recipe validate` on shipped
#   recipes. Absence is reported as NOT RUN and is not counted as external
#   validation success. The offline checks below remain the required gate.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
RECIPES_DIR="$REPO_ROOT/playbooks/recipes"
FINDINGS_TEMPLATE="$REPO_ROOT/playbooks/red-team/findings/TEMPLATE.md"
RED_TEAM_RECIPE="$RECIPES_DIR/red-team.yaml"
TOOLCHAIN_LOCK="$RECIPES_DIR/red-team.toolchain.json"
BUILDER_RECIPE="$RECIPES_DIR/builder.yaml"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-goose-recipes-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# ---------------------------------------------------------------------------
# Helpers (Bash 3.2-safe: no declare -A, no mapfile, no ${var,,})
# ---------------------------------------------------------------------------

sha256_file() {
  # Prefer shasum (macOS), fall back to sha256sum.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    echo ""
  fi
}

is_hex64() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
    *) return 1 ;;
  esac
}

# Python structural checker used for fixtures and shipped recipes.
# Args: path [--require-red-team]
# Exit 0 = structural pass for this path; non-zero = failure text on stdout/stderr.
check_recipe_py() {
  local path="$1"
  local mode="${2:-}"
  REPO_ROOT="$REPO_ROOT" python3 - "$path" "$mode" <<'PY'
import os, re, sys, json

path = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else ""
errors = []

try:
    import yaml
except ImportError:
    print("pyyaml missing")
    sys.exit(2)

with open(path, "r", encoding="utf-8") as f:
    raw = f.read()

# Full-line comment strip for "executable pin surface" (not instructions prose).
# Keep instructions/prompt bodies for template-var analysis separately.
def strip_hash_comments_outside_blocks(text):
    out = []
    in_block = False
    block_indent = None
    for line in text.splitlines(True):
        # crude block scalar tracking for | or >
        m = re.match(r'^(\s*)\S.*[|>][-+]?\s*$', line)
        if m and not in_block:
            in_block = True
            block_indent = len(m.group(1))
            out.append(line)
            continue
        if in_block:
            if line.strip() == "":
                out.append(line)
                continue
            ind = len(line) - len(line.lstrip(" "))
            if ind <= block_indent and line.strip() and not line.lstrip().startswith("#"):
                # only exit block when a non-empty line at <= indent that looks like a key
                if re.match(r'^\s{0,%d}\S' % block_indent, line) and re.match(r'^\s*\S+:', line):
                    in_block = False
                    block_indent = None
                else:
                    out.append(line)
                    continue
            else:
                out.append(line)
                continue
        # strip full-line comments and trailing comments on non-block lines
        if re.match(r'^\s*#', line):
            continue
        # drop trailing # comment carefully (not inside quotes)
        if "#" in line:
            # keep if it's only inside a quoted string roughly
            before = line.split("#", 1)[0]
            if before.count('"') % 2 == 0 and before.count("'") % 2 == 0:
                line = before.rstrip() + ("\n" if line.endswith("\n") else "")
        out.append(line)
    return "".join(out)

try:
    data = yaml.safe_load(raw)
except Exception as e:
    print("yaml parse error: %s" % e)
    sys.exit(1)

if not isinstance(data, dict):
    print("recipe root must be a mapping")
    sys.exit(1)

# Unsupported custom keys (official Goose Recipe 1.0.0 top-level only)
ALLOWED = {
    "version", "title", "description", "instructions", "prompt",
    "extensions", "settings", "activities", "author", "parameters",
    "response", "sub_recipes", "retry",
}
for k in data.keys():
    if k not in ALLOWED:
        errors.append("unsupported top-level key: %s" % k)

for req in ("version", "title", "description"):
    if req not in data or data[req] in (None, ""):
        errors.append("missing required field: %s" % req)

if not data.get("instructions") and not data.get("prompt"):
    errors.append("need instructions and/or prompt")

if str(data.get("version", "")) != "1.0.0":
    errors.append("Goose recipe schema version must be 1.0.0, got %r" % data.get("version"))

params = data.get("parameters") or []
if not isinstance(params, list):
    errors.append("parameters must be a list")
    params = []

param_keys = []
param_req = {}
for i, p in enumerate(params):
    if not isinstance(p, dict):
        errors.append("parameter[%d] not a mapping" % i)
        continue
    for f in ("key", "input_type", "requirement", "description"):
        if f not in p or p[f] in (None, ""):
            errors.append("parameter[%d] missing %s" % (i, f))
    key = p.get("key")
    if key:
        if key in param_keys:
            errors.append("duplicate parameter key: %s" % key)
        param_keys.append(key)
        param_req[key] = p.get("requirement")

# Built-in Goose template vars that need not be declared
BUILTIN_VARS = {"recipe_dir"}

instr = data.get("instructions") or ""
prompt = data.get("prompt") or ""
blob = "%s\n%s" % (instr, prompt)
used = sorted(set(re.findall(r"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}", blob)))
for v in used:
    if v in BUILTIN_VARS:
        continue
    if v not in param_keys:
        errors.append("undeclared template variable: %s" % v)
    else:
        req = param_req.get(v)
        if req != "required":
            errors.append("interpolated parameter %s must be required, got %r" % (v, req))

# Doctrine fork heuristic: long verbatim Law dumps / full protocol copy
doctrine_markers = [
    "The Ten Laws",
    "Law 1. **Read before you act.**",
    "### Phase 1 — Map the attack surface",
    "### Phase 2 — Automated sweep",
    "### Phase 3 — Adversarial subsystem attacks",
]
for m in doctrine_markers:
    if m in blob and mode != "allow-doctrine-fixture":
        # recipes may *name* Ten Laws; forbid large dumps. Require short mention only.
        if m.startswith("### Phase") or m.startswith("Law 1"):
            errors.append("doctrine appears copied into instructions: %s" % m)
        elif blob.count(m) and len(blob) > 8000:
            errors.append("suspiciously long instructions with doctrine marker: %s" % m)

# Extensions pin surface
exts = data.get("extensions") or []
if not isinstance(exts, list):
    errors.append("extensions must be a list")
    exts = []

FLOAT_VERSION = re.compile(
    r"(?i)(^|[@:=/\s-])(latest|stable)([@:=\s,\"']|$)|"
    r"(?i)[@/](main|master)([@:=\s,\"']|$)|"
    r"(?i):(latest|stable)\b|"
    r"(?i)\bnpm\s+install\s+[^@\s]+(?:\s|$)|"
    r"(?i)\bnpx\s+(?:-y\s+)?(?![^@\s]+@\d)[a-z0-9_@/.-]+\s*$|"
    r"[~^]\d|"
    r"(?i)\bversion\s*[:=]\s*['\"]?(x|\*|latest|stable)['\"]?"
)

def scan_float(s, where):
    if not isinstance(s, str):
        return
    # allow prose negatives in comments already stripped for pin surface
    if FLOAT_VERSION.search(s):
        # ignore documentation phrases that forbid floating pins
        low = s.lower()
        if "never" in low and "latest" in low:
            return
        if "do not" in low and ("latest" in low or "unpinned" in low):
            return
        errors.append("floating pin in %s: %r" % (where, s[:120]))

# Scan executable extension fields only (not instructions prose)
for i, e in enumerate(exts):
    if not isinstance(e, dict):
        errors.append("extension[%d] not a mapping" % i)
        continue
    et = e.get("type")
    name = e.get("name")
    if not et or not name:
        errors.append("extension[%d] needs type and name" % i)
    if et == "builtin":
        # bundled: version optional
        continue
    # external: require exact version somewhere in args/cmd/uri
    for field in ("cmd", "cmd_name", "uri", "version", "package", "image"):
        if field in e:
            scan_float(str(e[field]), "extension[%d].%s" % (i, field))
    args = e.get("args") or []
    if isinstance(args, list):
        joined = " ".join(str(a) for a in args)
        scan_float(joined, "extension[%d].args" % i)
        # unqualified npx package: args contain package without @version
        for a in args:
            a = str(a)
            if a in ("-y", "--yes"):
                continue
            if "/" in a or a.startswith("@"):
                # scoped or path-like package: require @version after last /
                if re.match(r"^(@?[^@\s]+)(@latest|@stable)?$", a) and "@" not in a[1:]:
                    # bare package name without version
                    if e.get("cmd") in ("npx", "npm", "pnpm", "yarn"):
                        errors.append("unqualified package without exact version in extension[%d]: %s" % (i, a))
                if re.search(r"@(latest|stable)\b", a):
                    errors.append("floating package tag in extension[%d]: %s" % (i, a))
            elif e.get("cmd") in ("npx", "npm") and re.match(r"^[a-zA-Z0-9_.-]+$", a):
                if "@" not in a:
                    errors.append("unqualified package without exact version in extension[%d]: %s" % (i, a))

# Comment/docs vs executable: full-line comments may mention latest; executable keys may not.
pin_surface = strip_hash_comments_outside_blocks(raw)
# Remove instructions/prompt block bodies from pin surface
pin_surface = re.sub(
    r"(?ms)^(instructions|prompt)\s*:\s*[|>][-+]?\s*\n(?:[ \t].*\n|\s*\n)*",
    r"\1: |\n  (body elided)\n",
    pin_surface,
)
for pat, label in (
    (r"(?i):\s*latest\b", "tag :latest"),
    (r"(?i)@latest\b", "@latest"),
    (r"(?i)image:\s*\S+:latest\b", "image:…:latest"),
    (r"(?i)version:\s*[\"']?latest[\"']?", "version: latest"),
    (r"(?i)version:\s*[\"']?stable[\"']?", "version: stable"),
    (r"(?i)ref:\s*[\"']?(main|master)[\"']?", "ref: main/master"),
    (r"(?i)tag:\s*[\"']?(latest|stable|main|master)[\"']?", "mutable tag"),
):
    if re.search(pat, pin_surface):
        errors.append("floating pin class on executable surface (%s)" % label)

# Red-team specific contract
if mode == "--require-red-team" or os.path.basename(path).startswith("red-team"):
    required_params = ["gibson", "repo", "target_url", "target_commit", "target_profile", "ledger"]
    for rp in required_params:
        if rp not in param_keys:
            errors.append("red-team missing required parameter: %s" % rp)
        elif param_req.get(rp) != "required":
            errors.append("red-team parameter %s must be required" % rp)
    for needle in (
        "playbooks/red-team/PROTOCOL.md",
        "findings/TEMPLATE.md",
        "red-team.toolchain.json",
    ):
        if needle not in blob:
            errors.append("red-team instructions must reference %s" % needle)
    # must not claim readiness / enforcement / permission mode authorization
    for banned in (
        "GOOSE_MODE=",
        "permission mode is set",
        "enforcement is active",
        "authorized for production",
        "READY FOR PRODUCTION",
    ):
        if banned.lower() in blob.lower():
            errors.append("red-team claims unauthorized readiness: %s" % banned)
    # target_commit must be described as full immutable commit
    for p in params:
        if p.get("key") == "target_commit":
            desc = (p.get("description") or "").lower()
            if "full" not in desc and "40" not in desc and "immutable" not in desc:
                errors.append("target_commit description must require full immutable commit")

if errors:
    for e in errors:
        print(e)
    sys.exit(1)
print("ok")
sys.exit(0)
PY
}

check_lock_py() {
  local path="$1"
  python3 - "$path" <<'PY'
import json, re, sys
path = sys.argv[1]
errors = []
with open(path, "r", encoding="utf-8") as f:
    raw = f.read()
try:
    data = json.loads(raw)
except Exception as e:
    print("invalid JSON: %s" % e)
    sys.exit(1)

if not isinstance(data, dict):
    print("lock root must be object")
    sys.exit(1)

for req in ("schema", "version", "tools"):
    if req not in data:
        errors.append("lock missing field: %s" % req)

if data.get("schema") != "gibson.toolchain-lock/v1":
    errors.append("unexpected schema: %r" % data.get("schema"))

tools = data.get("tools") or []
if not isinstance(tools, list) or not tools:
    errors.append("tools must be a non-empty list")

ids = []
required_ids = {"goose-cli", "gitleaks", "semgrep", "trufflehog", "socket-cli"}
found = set()
FLOAT = re.compile(r"(?i)^(latest|stable|main|master|\*|x)$|^\^|^\~|@latest|@stable|:latest$")

def bad_version(v, where):
    if v is None:
        return
    s = str(v).strip()
    if FLOAT.search(s) or s in ("latest", "stable", "main", "master", "*", "x"):
        errors.append("floating pin in %s: %r" % (where, s))
    if re.search(r"[~^]", s) and re.search(r"\d", s):
        errors.append("version range in %s: %r" % (where, s))

for i, t in enumerate(tools):
    if not isinstance(t, dict):
        errors.append("tools[%d] not object" % i)
        continue
    tid = t.get("id")
    if not tid:
        errors.append("tools[%d] missing id" % i)
    else:
        if tid in ids:
            errors.append("duplicate tool id: %s" % tid)
        ids.append(tid)
        found.add(tid)
    for f in ("name", "version", "identity", "source_url", "source_meta_url", "retrieved_utc", "execution"):
        if not t.get(f):
            errors.append("tools[%d] (%s) missing %s" % (i, tid, f))
    bad_version(t.get("version"), "tools[%d].version" % i)
    bad_version(t.get("identity"), "tools[%d].identity" % i)
    dig = t.get("digest") or {}
    if not isinstance(dig, dict) or not dig.get("algorithm") or not dig.get("value"):
        errors.append("tools[%d] (%s) missing digest algorithm/value" % (i, tid))
    else:
        val = str(dig.get("value", ""))
        algo = str(dig.get("algorithm", ""))
        if algo == "sha256":
            if not re.fullmatch(r"[0-9a-f]{64}", val):
                errors.append("tools[%d] noncanonical sha256 digest" % i)
        elif algo == "sha512-integrity":
            if not val.startswith("sha512-"):
                errors.append("tools[%d] noncanonical npm integrity digest" % i)
        else:
            # allow other algorithms but value must be non-empty exact
            if not val or FLOAT.search(val):
                errors.append("tools[%d] bad digest value" % i)
    url = t.get("source_url") or ""
    meta = t.get("source_meta_url") or ""
    if not (url.startswith("https://") and meta.startswith("https://")):
        errors.append("tools[%d] source URLs must be https" % i)
    # blog/snippet hosts are not authoritative
    for u in (url, meta):
        if re.search(r"(medium\.com|blogspot\.|dev\.to|twitter\.|x\.com/)", u):
            errors.append("tools[%d] non-authoritative source host: %s" % (i, u))
    ex = t.get("execution")
    if ex not in ("offline-validate-only", "pin-only", "owner-gated"):
        errors.append("tools[%d] unexpected execution: %r" % (i, ex))

missing = required_ids - found
for m in sorted(missing):
    errors.append("required tool id missing: %s" % m)

# Goose strategy pin
goose = next((t for t in tools if t.get("id") == "goose-cli"), None)
if goose:
    if str(goose.get("version")) != "1.45.0":
        errors.append("goose-cli version must remain strategy-pinned 1.45.0")
    dig = (goose.get("digest") or {}).get("value")
    if dig != "90c50d653d7fd978ec5d436b548eca8613dc2d26d028b486b7c52271267ec500":
        errors.append("goose-cli macOS arm64 SHA-256 does not match adapters/goose/README.md pin")

socket = next((t for t in tools if t.get("id") == "socket-cli"), None)
if socket:
    if socket.get("execution") != "owner-gated":
        errors.append("socket-cli must be execution owner-gated (paid credentials)")
    notes = (socket.get("notes") or "").lower()
    if "token" not in notes and "credential" not in notes:
        errors.append("socket-cli must document owner-gated credential truth")

# containers / mcp must be lists if present; entries unique + pinned
for list_key in ("containers", "mcp_packages"):
    items = data.get(list_key)
    if items is None:
        continue
    if not isinstance(items, list):
        errors.append("%s must be a list" % list_key)
        continue
    seen = set()
    for j, c in enumerate(items):
        if not isinstance(c, dict):
            errors.append("%s[%d] not object" % (list_key, j))
            continue
        cid = c.get("id") or c.get("name")
        if not cid:
            errors.append("%s[%d] missing id/name" % (list_key, j))
        elif cid in seen:
            errors.append("duplicate %s id: %s" % (list_key, cid))
        else:
            seen.add(cid)
        for field in ("version", "identity", "tag", "image", "ref", "digest"):
            if field in c:
                if field == "digest" and isinstance(c[field], dict):
                    bad_version(c[field].get("value"), "%s[%d].digest" % (list_key, j))
                else:
                    bad_version(c[field], "%s[%d].%s" % (list_key, j, field))

# digest instructions present
di = data.get("digest_instructions") or {}
if not isinstance(di, dict) or "macOS" not in di:
    errors.append("digest_instructions.macOS missing")
else:
    mac = di["macOS"]
    for k in ("recipe_sha256", "toolchain_lock_sha256"):
        if k not in mac:
            errors.append("digest_instructions.macOS.%s missing" % k)
        else:
            cmd = mac[k]
            if "shasum" not in cmd and "sha256sum" not in cmd:
                errors.append("digest instruction must use shasum/sha256sum")

# no floating tokens anywhere in string values of pin fields
def walk(obj, path=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("notes", "commit_policy", "digest_instructions"):
                # notes may mention the word latest as prohibition
                if isinstance(v, str) and re.search(r"(?i)\b(version|tag|image|ref)\b.*=.*\b(latest|stable)\b", v):
                    if "no " not in v.lower() and "never" not in v.lower() and "not" not in v.lower():
                        errors.append("possible floating pin in notes at %s" % path)
                continue
            walk(v, path + "." + k)
    elif isinstance(obj, list):
        for idx, v in enumerate(obj):
            walk(v, "%s[%d]" % (path, idx))
    elif isinstance(obj, str):
        if path.endswith(".version") or path.endswith(".identity") or path.endswith(".tag") or path.endswith(".image") or path.endswith(".ref"):
            bad_version(obj, path)

walk(data)

if errors:
    for e in errors:
        print(e)
    sys.exit(1)
print("ok")
sys.exit(0)
PY
}

expect_fail() {
  # $1 name, $2 command output, $3 rc, optional $4 needle
  local name="$1" out="$2" rc="$3" needle="${4:-}"
  if [[ "$rc" -ne 0 ]]; then
    if [[ -n "$needle" ]]; then
      if echo "$out" | grep -q "$needle"; then
        ok "$name"
      else
        bad "$name (rc=$rc but missing needle '$needle'): $out"
      fi
    else
      ok "$name"
    fi
  else
    bad "$name (expected fail, got pass): $out"
  fi
}

expect_pass() {
  local name="$1" out="$2" rc="$3"
  if [[ "$rc" -eq 0 ]]; then
    ok "$name"
  else
    bad "$name (rc=$rc): $out"
  fi
}

# ---------------------------------------------------------------------------
echo "shipped recipes exist and parse"
# ---------------------------------------------------------------------------
if [[ -f "$BUILDER_RECIPE" ]]; then
  ok "builder.yaml present"
else
  bad "builder.yaml missing"
fi
if [[ -f "$RED_TEAM_RECIPE" ]]; then
  ok "red-team.yaml present"
else
  bad "red-team.yaml missing"
fi
if [[ -f "$TOOLCHAIN_LOCK" ]]; then
  ok "red-team.toolchain.json present"
else
  bad "red-team.toolchain.json missing"
fi

# Discover all yaml/yml under recipes
shopt -s nullglob 2>/dev/null || true
RECIPE_FILES=()
for f in "$RECIPES_DIR"/*.yaml "$RECIPES_DIR"/*.yml; do
  [[ -f "$f" ]] || continue
  RECIPE_FILES+=("$f")
done

if [[ "${#RECIPE_FILES[@]}" -ge 2 ]]; then
  ok "discovered ${#RECIPE_FILES[@]} recipe yaml/yml files"
else
  bad "expected >=2 recipe files, found ${#RECIPE_FILES[@]}"
fi

for f in "${RECIPE_FILES[@]}"; do
  base=$(basename "$f")
  if [[ "$base" == red-team.yaml || "$base" == red-team.yml ]]; then
    out=$(check_recipe_py "$f" --require-red-team 2>&1); rc=$?
  else
    out=$(check_recipe_py "$f" 2>&1); rc=$?
  fi
  expect_pass "structural pass: $base" "$out" "$rc"
done

# ---------------------------------------------------------------------------
echo "toolchain lock structure + strategy goose pin"
# ---------------------------------------------------------------------------
out=$(check_lock_py "$TOOLCHAIN_LOCK" 2>&1); rc=$?
expect_pass "toolchain lock valid" "$out" "$rc"

# Deterministic JSON (re-parse round-trip key stability not required; must be valid)
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TOOLCHAIN_LOCK"; then
  ok "toolchain lock json.load"
else
  bad "toolchain lock json.load"
fi

# ---------------------------------------------------------------------------
echo "findings template stamp fields"
# ---------------------------------------------------------------------------
needles=(
  "Target commit"
  "Target URL classification"
  "Goose CLI version"
  "Goose CLI binary digest"
  "Recipe schema"
  "Recipe SHA-256"
  "Toolchain-lock SHA-256"
  "Target-profile SHA-256"
  "Start UTC"
  "End UTC"
  "Supervised mode"
  "Transcript / evidence reference"
)
missing_stamp=0
for n in "${needles[@]}"; do
  if grep -qF "$n" "$FINDINGS_TEMPLATE"; then
    :
  else
    bad "findings template missing stamp field: $n"
    missing_stamp=1
  fi
done
[[ "$missing_stamp" -eq 0 ]] && ok "findings template has all stamp fields"

# Must forbid secret/PII/home path leakage in stamp rules
if grep -qiE 'secret values|credential paths|real PII|private home' "$FINDINGS_TEMPLATE"; then
  ok "findings template documents stamp hygiene (no secrets/PII/home paths)"
else
  bad "findings template missing stamp hygiene rules"
fi

# Must not embed real secret-shaped values or absolute private homes as examples
if grep -E '/Users/[^/]+/' "$FINDINGS_TEMPLATE" | grep -vqE 'placeholder|example|<|Absolute path to the Gibson'; then
  # template should not show concrete /Users/me secrets; allow none
  if grep -E '/Users/[a-zA-Z0-9._-]+/' "$FINDINGS_TEMPLATE"; then
    bad "findings template contains absolute private home path"
  else
    ok "findings template has no absolute private home paths"
  fi
else
  ok "findings template has no absolute private home paths"
fi

# ---------------------------------------------------------------------------
echo "deterministic recipe/lock digest commands (temp fixtures)"
# ---------------------------------------------------------------------------
printf 'fixture-a\n' > "$ROOT/a.yaml"
printf 'fixture-b\n' > "$ROOT/b.json"
d1=$(sha256_file "$ROOT/a.yaml")
d2=$(sha256_file "$ROOT/a.yaml")
d3=$(sha256_file "$ROOT/b.json")
if is_hex64 "$d1" && [[ "$d1" == "$d2" ]]; then
  ok "sha256_file deterministic and 64-hex"
else
  bad "sha256_file not deterministic/canonical ($d1 / $d2)"
fi
if [[ "$d1" != "$d3" ]]; then
  ok "distinct fixtures produce distinct digests"
else
  bad "distinct fixtures collided"
fi

# Prove macOS instruction shape works on fixtures
if command -v shasum >/dev/null 2>&1; then
  dig=$(shasum -a 256 "$ROOT/a.yaml" | awk '{print $1}')
  if [[ "$dig" == "$d1" ]]; then
    ok "shasum -a 256 instruction matches helper"
  else
    bad "shasum mismatch ($dig vs $d1)"
  fi
else
  dig=$(sha256sum "$ROOT/a.yaml" | awk '{print $1}')
  if [[ "$dig" == "$d1" ]]; then
    ok "sha256sum instruction matches helper"
  else
    bad "sha256sum mismatch"
  fi
fi

# Shipped recipe digests are computable (not committed)
rd=$(sha256_file "$RED_TEAM_RECIPE")
ld=$(sha256_file "$TOOLCHAIN_LOCK")
if is_hex64 "$rd" && is_hex64 "$ld" && [[ "$rd" != "$ld" ]]; then
  ok "shipped recipe and lock digests computable (not requiring commit of digests)"
else
  bad "could not compute shipped digests"
fi

# ---------------------------------------------------------------------------
echo "red fixtures: floating pins, missing params, bad keys, doctrine copy"
# ---------------------------------------------------------------------------

# 1) floating latest in executable version field (.yaml)
cat > "$ROOT/bad-latest.yaml" <<'EOF'
version: "1.0.0"
title: Bad Latest
description: fixture
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
instructions: |
  Use {{ gibson }}
extensions:
  - type: stdio
    name: example
    cmd: npx
    args: ["-y", "some-mcp@latest"]
EOF
out=$(check_recipe_py "$ROOT/bad-latest.yaml" 2>&1); rc=$?
expect_fail "red: @latest package fails (.yaml)" "$out" "$rc" "float"

# 2) same class for .yml extension
cat > "$ROOT/bad-latest.yml" <<'EOF'
version: "1.0.0"
title: Bad Latest Yml
description: fixture
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
instructions: |
  Use {{ gibson }}
extensions:
  - type: stdio
    name: example
    cmd: npx
    args: ["-y", "other-mcp@latest"]
EOF
out=$(check_recipe_py "$ROOT/bad-latest.yml" 2>&1); rc=$?
expect_fail "red: @latest package fails (.yml)" "$out" "$rc" "float"

# 3) comments may mention latest without failing (not noisy)
cat > "$ROOT/ok-comment-latest.yaml" <<'EOF'
# Never pin with latest — this comment documents the rule.
version: "1.0.0"
title: Comment Latest OK
description: fixture that forbids latest in comments only
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
instructions: |
  Use {{ gibson }}. Never use latest pins.
extensions:
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/ok-comment-latest.yaml" 2>&1); rc=$?
expect_pass "green: comment/docs may mention latest" "$out" "$rc"

# 4) version: latest on executable surface fails
cat > "$ROOT/bad-ver-latest.yaml" <<'EOF'
version: "1.0.0"
title: Bad
description: fixture
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
instructions: |
  Use {{ gibson }}
extensions:
  - type: stdio
    name: example
    cmd: tool
    version: latest
EOF
out=$(check_recipe_py "$ROOT/bad-ver-latest.yaml" 2>&1); rc=$?
expect_fail "red: version latest fails" "$out" "$rc"

# 5) undeclared variable
cat > "$ROOT/bad-undeclared.yaml" <<'EOF'
version: "1.0.0"
title: Bad
description: fixture
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
instructions: |
  Use {{ gibson }} and {{ secret_path }}
extensions:
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/bad-undeclared.yaml" 2>&1); rc=$?
expect_fail "red: undeclared variable" "$out" "$rc" "undeclared"

# 6) optional interpolated parameter
cat > "$ROOT/bad-optional.yaml" <<'EOF'
version: "1.0.0"
title: Bad
description: fixture
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
  - key: issue
    input_type: string
    requirement: optional
    description: optional issue
instructions: |
  Issue {{ issue }} at {{ gibson }}
extensions:
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/bad-optional.yaml" 2>&1); rc=$?
expect_fail "red: optional interpolated parameter" "$out" "$rc" "required"

# 7) missing/duplicate parameters
cat > "$ROOT/bad-dup.yaml" <<'EOF'
version: "1.0.0"
title: Bad
description: fixture
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
  - key: gibson
    input_type: string
    requirement: required
    description: g2
instructions: |
  {{ gibson }}
extensions:
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/bad-dup.yaml" 2>&1); rc=$?
expect_fail "red: duplicate parameter" "$out" "$rc" "duplicate"

# 8) unsupported top-level key
cat > "$ROOT/bad-key.yaml" <<'EOF'
version: "1.0.0"
title: Bad
description: fixture
playbook: playbooks/builder.md
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
instructions: |
  {{ gibson }}
extensions:
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/bad-key.yaml" 2>&1); rc=$?
expect_fail "red: unsupported top-level key" "$out" "$rc" "unsupported"

# 9) doctrine copied into instructions
cat > "$ROOT/bad-doctrine.yaml" <<'EOF'
version: "1.0.0"
title: Bad
description: fixture
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
instructions: |
  ### Phase 1 — Map the attack surface
  Enumerate every route here instead of reading PROTOCOL.md.
  {{ gibson }}
extensions:
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/bad-doctrine.yaml" 2>&1); rc=$?
expect_fail "red: doctrine copied into instructions" "$out" "$rc" "doctrine"

# 10) red-team missing required param
cat > "$ROOT/bad-red-missing.yaml" <<'EOF'
version: "1.0.0"
title: Bad Red
description: fixture
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
  - key: repo
    input_type: string
    requirement: required
    description: r
instructions: |
  Read playbooks/red-team/PROTOCOL.md and findings/TEMPLATE.md and red-team.toolchain.json
  Only {{ gibson }} {{ repo }}
extensions:
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/bad-red-missing.yaml" --require-red-team 2>&1); rc=$?
expect_fail "red: red-team missing target_* params" "$out" "$rc" "missing required parameter"

# 11) mutable target commit description (branch tip)
cat > "$ROOT/bad-mutable-commit.yaml" <<'EOF'
version: "1.0.0"
title: Bad Red
description: fixture
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
  - key: repo
    input_type: string
    requirement: required
    description: r
  - key: target_url
    input_type: string
    requirement: required
    description: u
  - key: target_commit
    input_type: string
    requirement: required
    description: branch name or short sha tip
  - key: target_profile
    input_type: string
    requirement: required
    description: p
  - key: ledger
    input_type: string
    requirement: required
    description: l
instructions: |
  Read playbooks/red-team/PROTOCOL.md and findings/TEMPLATE.md and red-team.toolchain.json
  {{ gibson }} {{ repo }} {{ target_url }} {{ target_commit }} {{ target_profile }} {{ ledger }}
extensions:
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/bad-mutable-commit.yaml" --require-red-team 2>&1); rc=$?
expect_fail "red: mutable target_commit description" "$out" "$rc" "immutable"

# 12) lock with latest pin
cat > "$ROOT/bad-lock-latest.json" <<'EOF'
{
  "schema": "gibson.toolchain-lock/v1",
  "version": "1.0.0",
  "tools": [
    {
      "id": "goose-cli",
      "name": "Goose CLI",
      "version": "1.45.0",
      "identity": "v1.45.0",
      "source_url": "https://github.com/aaif-goose/goose/releases/download/v1.45.0/goose-aarch64-apple-darwin.tar.gz",
      "source_meta_url": "https://github.com/aaif-goose/goose/releases/tag/v1.45.0",
      "retrieved_utc": "2026-08-03",
      "execution": "offline-validate-only",
      "digest": {"algorithm": "sha256", "value": "90c50d653d7fd978ec5d436b548eca8613dc2d26d028b486b7c52271267ec500"}
    },
    {
      "id": "gitleaks",
      "name": "gitleaks",
      "version": "latest",
      "identity": "latest",
      "source_url": "https://github.com/gitleaks/gitleaks/releases",
      "source_meta_url": "https://github.com/gitleaks/gitleaks/releases",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    },
    {
      "id": "semgrep",
      "name": "Semgrep",
      "version": "1.172.0",
      "identity": "1.172.0",
      "source_url": "https://pypi.org/project/semgrep/1.172.0/",
      "source_meta_url": "https://pypi.org/pypi/semgrep/1.172.0/json",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
    },
    {
      "id": "trufflehog",
      "name": "TruffleHog",
      "version": "3.96.0",
      "identity": "v3.96.0",
      "source_url": "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0",
      "source_meta_url": "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}
    },
    {
      "id": "socket-cli",
      "name": "Socket CLI",
      "version": "1.1.147",
      "identity": "socket@1.1.147",
      "source_url": "https://registry.npmjs.org/socket/-/socket-1.1.147.tgz",
      "source_meta_url": "https://registry.npmjs.org/socket/1.1.147",
      "retrieved_utc": "2026-08-03",
      "execution": "owner-gated",
      "notes": "requires owner credential/token approval",
      "digest": {"algorithm": "sha512-integrity", "value": "sha512-TZWg3JQPuykBb1XKWVhmYQh+Zl1C0qU0nUxVzzPM5Q/AbC0oQGC9yKDmGQhizy/KLT64I671UjTvrjQ9MBOvGQ=="}
    }
  ],
  "digest_instructions": {
    "macOS": {
      "recipe_sha256": "shasum -a 256 playbooks/recipes/red-team.yaml | awk '{print $1}'",
      "toolchain_lock_sha256": "shasum -a 256 playbooks/recipes/red-team.toolchain.json | awk '{print $1}'"
    }
  }
}
EOF
out=$(check_lock_py "$ROOT/bad-lock-latest.json" 2>&1); rc=$?
expect_fail "red: lock version latest fails" "$out" "$rc" "floating"

# 13) malformed digest
cat > "$ROOT/bad-lock-digest.json" <<'EOF'
{
  "schema": "gibson.toolchain-lock/v1",
  "version": "1.0.0",
  "tools": [
    {
      "id": "goose-cli",
      "name": "Goose CLI",
      "version": "1.45.0",
      "identity": "v1.45.0",
      "source_url": "https://github.com/aaif-goose/goose/releases/download/v1.45.0/goose-aarch64-apple-darwin.tar.gz",
      "source_meta_url": "https://github.com/aaif-goose/goose/releases/tag/v1.45.0",
      "retrieved_utc": "2026-08-03",
      "execution": "offline-validate-only",
      "digest": {"algorithm": "sha256", "value": "not-a-digest"}
    },
    {
      "id": "gitleaks",
      "name": "gitleaks",
      "version": "8.30.1",
      "identity": "v8.30.1",
      "source_url": "https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1",
      "source_meta_url": "https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"}
    },
    {
      "id": "semgrep",
      "name": "Semgrep",
      "version": "1.172.0",
      "identity": "1.172.0",
      "source_url": "https://pypi.org/project/semgrep/1.172.0/",
      "source_meta_url": "https://pypi.org/pypi/semgrep/1.172.0/json",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "7377cc350c64c7b83de20090cb2843d875da1d806690fd604e446ed544b56d71"}
    },
    {
      "id": "trufflehog",
      "name": "TruffleHog",
      "version": "3.96.0",
      "identity": "v3.96.0",
      "source_url": "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0",
      "source_meta_url": "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "87478306b95ca2420cfb844b7582383ac60b922e262350a0088e797f328d2e62"}
    },
    {
      "id": "socket-cli",
      "name": "Socket CLI",
      "version": "1.1.147",
      "identity": "socket@1.1.147",
      "source_url": "https://registry.npmjs.org/socket/-/socket-1.1.147.tgz",
      "source_meta_url": "https://registry.npmjs.org/socket/1.1.147",
      "retrieved_utc": "2026-08-03",
      "execution": "owner-gated",
      "notes": "requires owner credential/token approval",
      "digest": {"algorithm": "sha512-integrity", "value": "sha512-TZWg3JQPuykBb1XKWVhmYQh+Zl1C0qU0nUxVzzPM5Q/AbC0oQGC9yKDmGQhizy/KLT64I671UjTvrjQ9MBOvGQ=="}
    }
  ],
  "digest_instructions": {
    "macOS": {
      "recipe_sha256": "shasum -a 256 playbooks/recipes/red-team.yaml | awk '{print $1}'",
      "toolchain_lock_sha256": "shasum -a 256 playbooks/recipes/red-team.toolchain.json | awk '{print $1}'"
    }
  }
}
EOF
out=$(check_lock_py "$ROOT/bad-lock-digest.json" 2>&1); rc=$?
expect_fail "red: malformed noncanonical digest" "$out" "$rc" "noncanonical"

# 14) socket missing owner-gated truth
cat > "$ROOT/bad-lock-socket.json" <<'EOF'
{
  "schema": "gibson.toolchain-lock/v1",
  "version": "1.0.0",
  "tools": [
    {
      "id": "goose-cli",
      "name": "Goose CLI",
      "version": "1.45.0",
      "identity": "v1.45.0",
      "source_url": "https://github.com/aaif-goose/goose/releases/download/v1.45.0/goose-aarch64-apple-darwin.tar.gz",
      "source_meta_url": "https://github.com/aaif-goose/goose/releases/tag/v1.45.0",
      "retrieved_utc": "2026-08-03",
      "execution": "offline-validate-only",
      "digest": {"algorithm": "sha256", "value": "90c50d653d7fd978ec5d436b548eca8613dc2d26d028b486b7c52271267ec500"}
    },
    {
      "id": "gitleaks",
      "name": "gitleaks",
      "version": "8.30.1",
      "identity": "v8.30.1",
      "source_url": "https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1",
      "source_meta_url": "https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"}
    },
    {
      "id": "semgrep",
      "name": "Semgrep",
      "version": "1.172.0",
      "identity": "1.172.0",
      "source_url": "https://pypi.org/project/semgrep/1.172.0/",
      "source_meta_url": "https://pypi.org/pypi/semgrep/1.172.0/json",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "7377cc350c64c7b83de20090cb2843d875da1d806690fd604e446ed544b56d71"}
    },
    {
      "id": "trufflehog",
      "name": "TruffleHog",
      "version": "3.96.0",
      "identity": "v3.96.0",
      "source_url": "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0",
      "source_meta_url": "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "87478306b95ca2420cfb844b7582383ac60b922e262350a0088e797f328d2e62"}
    },
    {
      "id": "socket-cli",
      "name": "Socket CLI",
      "version": "1.1.147",
      "identity": "socket@1.1.147",
      "source_url": "https://registry.npmjs.org/socket/-/socket-1.1.147.tgz",
      "source_meta_url": "https://registry.npmjs.org/socket/1.1.147",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "notes": "runs freely",
      "digest": {"algorithm": "sha512-integrity", "value": "sha512-TZWg3JQPuykBb1XKWVhmYQh+Zl1C0qU0nUxVzzPM5Q/AbC0oQGC9yKDmGQhizy/KLT64I671UjTvrjQ9MBOvGQ=="}
    }
  ],
  "digest_instructions": {
    "macOS": {
      "recipe_sha256": "shasum -a 256 playbooks/recipes/red-team.yaml | awk '{print $1}'",
      "toolchain_lock_sha256": "shasum -a 256 playbooks/recipes/red-team.toolchain.json | awk '{print $1}'"
    }
  }
}
EOF
out=$(check_lock_py "$ROOT/bad-lock-socket.json" 2>&1); rc=$?
expect_fail "red: socket not owner-gated fails" "$out" "$rc" "owner-gated"

# 15) unqualified npx package
cat > "$ROOT/bad-npx.yaml" <<'EOF'
version: "1.0.0"
title: Bad
description: fixture
parameters:
  - key: gibson
    input_type: string
    requirement: required
    description: g
instructions: |
  {{ gibson }}
extensions:
  - type: stdio
    name: example
    cmd: npx
    args: ["-y", "some-mcp"]
EOF
out=$(check_recipe_py "$ROOT/bad-npx.yaml" 2>&1); rc=$?
expect_fail "red: unqualified npx package" "$out" "$rc" "unqualified"

# 16) caret range in lock
cat > "$ROOT/bad-lock-caret.json" <<'EOF'
{
  "schema": "gibson.toolchain-lock/v1",
  "version": "1.0.0",
  "tools": [
    {
      "id": "goose-cli",
      "name": "Goose CLI",
      "version": "1.45.0",
      "identity": "v1.45.0",
      "source_url": "https://github.com/aaif-goose/goose/releases/download/v1.45.0/goose-aarch64-apple-darwin.tar.gz",
      "source_meta_url": "https://github.com/aaif-goose/goose/releases/tag/v1.45.0",
      "retrieved_utc": "2026-08-03",
      "execution": "offline-validate-only",
      "digest": {"algorithm": "sha256", "value": "90c50d653d7fd978ec5d436b548eca8613dc2d26d028b486b7c52271267ec500"}
    },
    {
      "id": "gitleaks",
      "name": "gitleaks",
      "version": "^8.30.1",
      "identity": "^8.30.1",
      "source_url": "https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1",
      "source_meta_url": "https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"}
    },
    {
      "id": "semgrep",
      "name": "Semgrep",
      "version": "1.172.0",
      "identity": "1.172.0",
      "source_url": "https://pypi.org/project/semgrep/1.172.0/",
      "source_meta_url": "https://pypi.org/pypi/semgrep/1.172.0/json",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "7377cc350c64c7b83de20090cb2843d875da1d806690fd604e446ed544b56d71"}
    },
    {
      "id": "trufflehog",
      "name": "TruffleHog",
      "version": "3.96.0",
      "identity": "v3.96.0",
      "source_url": "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0",
      "source_meta_url": "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "87478306b95ca2420cfb844b7582383ac60b922e262350a0088e797f328d2e62"}
    },
    {
      "id": "socket-cli",
      "name": "Socket CLI",
      "version": "1.1.147",
      "identity": "socket@1.1.147",
      "source_url": "https://registry.npmjs.org/socket/-/socket-1.1.147.tgz",
      "source_meta_url": "https://registry.npmjs.org/socket/1.1.147",
      "retrieved_utc": "2026-08-03",
      "execution": "owner-gated",
      "notes": "requires owner credential/token approval",
      "digest": {"algorithm": "sha512-integrity", "value": "sha512-TZWg3JQPuykBb1XKWVhmYQh+Zl1C0qU0nUxVzzPM5Q/AbC0oQGC9yKDmGQhizy/KLT64I671UjTvrjQ9MBOvGQ=="}
    }
  ],
  "digest_instructions": {
    "macOS": {
      "recipe_sha256": "shasum -a 256 playbooks/recipes/red-team.yaml | awk '{print $1}'",
      "toolchain_lock_sha256": "shasum -a 256 playbooks/recipes/red-team.toolchain.json | awk '{print $1}'"
    }
  }
}
EOF
out=$(check_lock_py "$ROOT/bad-lock-caret.json" 2>&1); rc=$?
expect_fail "red: caret version range fails" "$out" "$rc" "range"

# 17) container floating tag fixture
cat > "$ROOT/bad-lock-container.json" <<'EOF'
{
  "schema": "gibson.toolchain-lock/v1",
  "version": "1.0.0",
  "tools": [
    {
      "id": "goose-cli",
      "name": "Goose CLI",
      "version": "1.45.0",
      "identity": "v1.45.0",
      "source_url": "https://github.com/aaif-goose/goose/releases/download/v1.45.0/goose-aarch64-apple-darwin.tar.gz",
      "source_meta_url": "https://github.com/aaif-goose/goose/releases/tag/v1.45.0",
      "retrieved_utc": "2026-08-03",
      "execution": "offline-validate-only",
      "digest": {"algorithm": "sha256", "value": "90c50d653d7fd978ec5d436b548eca8613dc2d26d028b486b7c52271267ec500"}
    },
    {
      "id": "gitleaks",
      "name": "gitleaks",
      "version": "8.30.1",
      "identity": "v8.30.1",
      "source_url": "https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1",
      "source_meta_url": "https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"}
    },
    {
      "id": "semgrep",
      "name": "Semgrep",
      "version": "1.172.0",
      "identity": "1.172.0",
      "source_url": "https://pypi.org/project/semgrep/1.172.0/",
      "source_meta_url": "https://pypi.org/pypi/semgrep/1.172.0/json",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "7377cc350c64c7b83de20090cb2843d875da1d806690fd604e446ed544b56d71"}
    },
    {
      "id": "trufflehog",
      "name": "TruffleHog",
      "version": "3.96.0",
      "identity": "v3.96.0",
      "source_url": "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0",
      "source_meta_url": "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0",
      "retrieved_utc": "2026-08-03",
      "execution": "pin-only",
      "digest": {"algorithm": "sha256", "value": "87478306b95ca2420cfb844b7582383ac60b922e262350a0088e797f328d2e62"}
    },
    {
      "id": "socket-cli",
      "name": "Socket CLI",
      "version": "1.1.147",
      "identity": "socket@1.1.147",
      "source_url": "https://registry.npmjs.org/socket/-/socket-1.1.147.tgz",
      "source_meta_url": "https://registry.npmjs.org/socket/1.1.147",
      "retrieved_utc": "2026-08-03",
      "execution": "owner-gated",
      "notes": "requires owner credential/token approval",
      "digest": {"algorithm": "sha512-integrity", "value": "sha512-TZWg3JQPuykBb1XKWVhmYQh+Zl1C0qU0nUxVzzPM5Q/AbC0oQGC9yKDmGQhizy/KLT64I671UjTvrjQ9MBOvGQ=="}
    }
  ],
  "containers": [
    {
      "id": "gitleaks-image",
      "image": "zricethezav/gitleaks:latest",
      "tag": "latest",
      "version": "latest"
    }
  ],
  "digest_instructions": {
    "macOS": {
      "recipe_sha256": "shasum -a 256 playbooks/recipes/red-team.yaml | awk '{print $1}'",
      "toolchain_lock_sha256": "shasum -a 256 playbooks/recipes/red-team.toolchain.json | awk '{print $1}'"
    }
  }
}
EOF
out=$(check_lock_py "$ROOT/bad-lock-container.json" 2>&1); rc=$?
expect_fail "red: container :latest fails" "$out" "$rc" "floating"

# ---------------------------------------------------------------------------
echo "docs truth boundary (no readiness upgrade)"
# ---------------------------------------------------------------------------
for doc in \
  "$REPO_ROOT/playbooks/recipes/README.md" \
  "$REPO_ROOT/playbooks/red-team/README.md"
do
  if grep -qiE 'NOT RUN|validation-only|owner-gated|#25 remains open|still open' "$doc"; then
    ok "$(basename "$(dirname "$doc")")/$(basename "$doc") states offline/NOT RUN/open boundary"
  else
    bad "$doc missing offline/NOT RUN/open boundary language"
  fi
  if grep -qiE 'authorized for live|enforcement is complete|permission mode is decided|build-on decided' "$doc"; then
    bad "$doc claims unauthorized readiness/enforcement"
  else
    ok "$(basename "$doc") does not claim live readiness/enforcement"
  fi
done

# ---------------------------------------------------------------------------
echo "optional official Goose recipe validate"
# ---------------------------------------------------------------------------
GOOSE_VALIDATE_STATUS="NOT RUN"
if command -v goose >/dev/null 2>&1; then
  gv_fail=0
  for f in "${RECIPE_FILES[@]}"; do
    out=$(goose recipe validate "$f" 2>&1); rc=$?
    if [[ "$rc" -eq 0 ]]; then
      ok "goose recipe validate: $(basename "$f")"
    else
      bad "goose recipe validate failed: $(basename "$f"): $out"
      gv_fail=1
    fi
  done
  if [[ "$gv_fail" -eq 0 ]]; then
    GOOSE_VALIDATE_STATUS="RAN (pass)"
  else
    GOOSE_VALIDATE_STATUS="RAN (fail)"
  fi
else
  echo "  note — goose binary absent: official recipe validate NOT RUN (not counted as success)"
  ok "goose absence reported as NOT RUN (offline sensor remains the gate)"
  GOOSE_VALIDATE_STATUS="NOT RUN"
fi

# ---------------------------------------------------------------------------
echo "bash -n self"
# ---------------------------------------------------------------------------
if bash -n "$0" 2>"$ROOT/bashn.err"; then
  ok "bash -n goose-recipes.test.sh"
else
  bad "bash -n failed: $(cat "$ROOT/bashn.err")"
fi

echo
echo "goose-recipes.test.sh: $PASS passed, $FAIL failed"
echo "goose recipe validate status: $GOOSE_VALIDATE_STATUS"
[[ "$FAIL" -eq 0 ]]
