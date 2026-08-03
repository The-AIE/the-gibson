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

# Exact canonical numeric semver: MAJOR.MINOR.PATCH digits only.
# Reject x/X/*, missing segments, prerelease/build, whitespace, operators,
# ranges (|| , hyphen caret tilde), branch words.
EXACT_SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
FLOAT_WORDS = re.compile(
    r"(^|[@:=/\s-])(latest|stable|main|master)([@:=\s,\"']|$)|"
    r":(latest|stable|main|master)\b|"
    r"@(latest|stable|main|master)\b",
    re.I,
)
RANGE_MARKERS = re.compile(
    r"(\|\||\s,\s|>=|<=|~(?=\d)|(?<![a-zA-Z])\^(?=\d)|(?<![a-zA-Z0-9])\*(?![a-zA-Z0-9])|"
    r"(?:^|[@=])x(?:\.|$)|(?:^|[@=\.])X(?:\.|$)|\.x(?:\.|$)|\.X(?:\.|$)|"
    r"\.\*|-\s*\d|\d\s*-\s*\d)",
    re.I,
)

def is_exact_numeric_semver(s):
    return isinstance(s, str) and bool(EXACT_SEMVER.fullmatch(s))

def package_version_suffix(token):
    """Return version after last @ for npm-style package tokens, else None."""
    if not isinstance(token, str) or "@" not in token:
        return None
    # scoped: @scope/name@version  → last @
    if token.startswith("@"):
        if token.count("@") < 2:
            return None
        return token.rsplit("@", 1)[1]
    return token.rsplit("@", 1)[1]

def reject_nonexact_version(s, where):
    """Fail closed: version-like fields must be exact MAJOR.MINOR.PATCH."""
    if s is None:
        return
    if not isinstance(s, str):
        s = str(s)
    if s != s.strip() or any(ch.isspace() for ch in s):
        errors.append("non-exact semver (whitespace) in %s: %r" % (where, s))
        return
    if FLOAT_WORDS.search(s) or RANGE_MARKERS.search(s) or not is_exact_numeric_semver(s):
        errors.append("non-exact semver in %s: %r" % (where, s))

def scan_float_token(s, where):
    if not isinstance(s, str):
        return
    low = s.lower()
    if ("never" in low and "latest" in low) or (
        "do not" in low and ("latest" in low or "unpinned" in low)
    ):
        return
    if FLOAT_WORDS.search(s) or RANGE_MARKERS.search(s):
        errors.append("floating pin in %s: %r" % (where, s[:120]))
        return
    # bare branch words / incomplete versions as whole token
    if re.fullmatch(r"(latest|stable|main|master|x|\*)", s.strip(), re.I):
        errors.append("floating pin in %s: %r" % (where, s[:120]))

schema_ver = data.get("version", "")
if not isinstance(schema_ver, str) or schema_ver != schema_ver.strip():
    errors.append("Goose recipe schema version must be exact 1.0.0, got %r" % schema_ver)
elif not is_exact_numeric_semver(schema_ver):
    errors.append("Goose recipe schema version must be exact numeric semver 1.0.0, got %r" % schema_ver)
elif schema_ver != "1.0.0":
    errors.append("Goose recipe schema version must be 1.0.0, got %r" % schema_ver)

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
        # bundled: version optional; if present must still be exact
        if "version" in e and e["version"] not in (None, ""):
            reject_nonexact_version(str(e["version"]), "extension[%d].version" % i)
        continue
    # external: version/package fields must be exact when present
    if "version" in e and e["version"] not in (None, ""):
        reject_nonexact_version(str(e["version"]), "extension[%d].version" % i)
    if "package" in e and e["package"] not in (None, ""):
        pkg = str(e["package"])
        ver = package_version_suffix(pkg)
        if ver is None and "==" in pkg:
            ver = pkg.split("==", 1)[1]
        if ver is None:
            # bare package name without version pin
            if re.fullmatch(r"[A-Za-z0-9_@/.-]+", pkg):
                errors.append("unqualified package without exact version in extension[%d]: %s" % (i, pkg))
            else:
                scan_float_token(pkg, "extension[%d].package" % i)
        else:
            reject_nonexact_version(ver, "extension[%d].package version" % i)
    if "image" in e and e["image"] not in (None, ""):
        img = str(e["image"])
        if not re.fullmatch(r".+@sha256:[0-9a-f]{64}", img):
            errors.append("container image must be immutable @sha256:<64hex> in extension[%d]: %r" % (i, img))
    for field in ("cmd", "cmd_name", "uri", "ref", "tag"):
        if field in e and e[field] not in (None, ""):
            scan_float_token(str(e[field]), "extension[%d].%s" % (i, field))
            if field == "ref":
                ref = str(e[field])
                if ref.startswith("refs/") or not re.fullmatch(r"[0-9a-f]{40}", ref):
                    if not is_exact_numeric_semver(ref):
                        errors.append("git/MCP ref must be full commit SHA or exact semver in extension[%d].ref: %r" % (i, ref))
    args = e.get("args") or []
    if isinstance(args, list):
        joined = " ".join(str(a) for a in args)
        scan_float_token(joined, "extension[%d].args" % i)
        for a in args:
            a = str(a)
            if a in ("-y", "--yes"):
                continue
            if e.get("cmd") in ("npx", "npm", "pnpm", "yarn"):
                ver = package_version_suffix(a)
                if ver is None:
                    # bare package (scoped or not) without @version
                    if re.match(r"^@[^@\s]+/[^@\s]+$", a) or re.match(r"^[a-zA-Z0-9_.-]+$", a):
                        errors.append("unqualified package without exact version in extension[%d]: %s" % (i, a))
                    continue
                reject_nonexact_version(ver, "extension[%d].args package" % i)

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
    (r"(?i):\s*stable\b", "tag :stable"),
    (r"(?i)@latest\b", "@latest"),
    (r"(?i)@stable\b", "@stable"),
    (r"(?i)image:\s*\S+:(latest|stable|main|master)\b", "image:…:mutable-tag"),
    (r"(?i)image:\s*\S+:\d+\.\d+\.\d+\s*$", "image:…:semver-tag (not digest)"),
    (r"(?i)version:\s*[\"']?(latest|stable|main|master|x|\*|>=|<=|[~^]|[0-9]+\.x|[0-9]+\.\*|[0-9]+\.[0-9]+\.\*)[\"']?", "version non-exact"),
    (r"(?i)ref:\s*[\"']?(main|master|refs/)[\"']?", "ref: mutable"),
    (r"(?i)tag:\s*[\"']?(latest|stable|main|master)[\"']?", "mutable tag"),
    (r"(?i)version:\s*[\"']?[0-9]+\.x", "version x-wildcard"),
    (r"(?i)version:\s*[\"']?[0-9]+\.[0-9]+\.\*", "version star-wildcard"),
    (r"(?i)version:\s*[\"']?(>=|<=|>|<|~|\^)", "version operator/range"),
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
import base64
import json
import re
import sys

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

EXACT_SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
IMAGE_DIGEST = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
FLOAT_WORD = re.compile(r"^(latest|stable|main|master|\*|x)$", re.I)
# Operators, wildcards, ranges, incomplete segments
NONEXACT = re.compile(
    r"(\|\||>=|<=|[<>]|~|\^|,|\.x\b|\.X\b|\.\*|\bx\.|\bX\.|"
    r"refs/heads/|refs/tags/|(^|/)(main|master|latest|stable)(/|$))",
    re.I,
)

def is_exact_numeric_semver(s):
    return isinstance(s, str) and bool(EXACT_SEMVER.fullmatch(s))

def reject_nonexact_semver(s, where):
    if s is None:
        errors.append("missing version at %s" % where)
        return
    if not isinstance(s, str):
        s = str(s)
    if s != s.strip() or any(ch.isspace() for ch in s):
        errors.append("non-exact semver (whitespace/operator) in %s: %r" % (where, s))
        return
    if FLOAT_WORD.fullmatch(s) or NONEXACT.search(s) or not is_exact_numeric_semver(s):
        errors.append("non-exact semver in %s: %r" % (where, s))

def is_ok_identity(s):
    """Identity may be plain exact semver, v-prefixed, or name@exact."""
    if not isinstance(s, str) or s != s.strip() or any(ch.isspace() for ch in s):
        return False
    if is_exact_numeric_semver(s):
        return True
    if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", s):
        return True
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*@[0-9]+\.[0-9]+\.[0-9]+", s):
        return True
    return False

def reject_identity(s, where):
    if s is None:
        errors.append("missing identity at %s" % where)
        return
    s = str(s)
    if not is_ok_identity(s):
        errors.append("non-exact identity pin in %s: %r" % (where, s))

def validate_sha256_value(val, where):
    if not isinstance(val, str) or not HEX64.fullmatch(val):
        errors.append("%s noncanonical sha256 digest (need exactly 64 lowercase hex)" % where)
        return False
    return True

def validate_npm_integrity(val, where):
    """npm integrity: sha512- + standard base64 that decodes to 64 bytes (SHA-512)."""
    if not isinstance(val, str) or any(ch.isspace() for ch in val):
        errors.append("%s malformed npm integrity (empty/whitespace)" % where)
        return False
    if not val.startswith("sha512-"):
        errors.append("%s noncanonical npm integrity (need sha512- prefix)" % where)
        return False
    b64 = val[len("sha512-"):]
    if not b64:
        errors.append("%s malformed npm integrity (empty payload)" % where)
        return False
    # Only standard base64 alphabet + padding
    if not re.fullmatch(r"[A-Za-z0-9+/]+=*$", b64):
        errors.append("%s malformed npm integrity (non-base64 payload)" % where)
        return False
    try:
        raw = base64.b64decode(b64, validate=True)
    except Exception:
        errors.append("%s malformed npm integrity (base64 decode failed)" % where)
        return False
    if len(raw) != 64:
        errors.append("%s malformed npm integrity (decoded length %d, want 64)" % (where, len(raw)))
        return False
    return True

def validate_digest_obj(dig, where, allowed=None):
    """Digest object: algorithm must match field class; no md5/sha1/shape games."""
    if allowed is None:
        allowed = ("sha256", "sha512-integrity")
    if not isinstance(dig, dict):
        errors.append("%s digest must be object {algorithm,value}" % where)
        return
    algo = dig.get("algorithm")
    val = dig.get("value")
    if algo is None or val is None or algo == "" or val == "":
        errors.append("%s missing digest algorithm/value" % where)
        return
    algo = str(algo)
    val = str(val)
    if algo not in allowed:
        errors.append("%s unsupported/forbidden digest algorithm %r (allowed: %s)" % (
            where, algo, ",".join(allowed)))
        return
    if algo == "sha256":
        validate_sha256_value(val, where)
    elif algo == "sha512-integrity":
        validate_npm_integrity(val, where)

# lock document version
if "version" in data:
    reject_nonexact_semver(str(data.get("version")), "lock.version")

tools = data.get("tools") or []
if not isinstance(tools, list) or not tools:
    errors.append("tools must be a non-empty list")

ids = []
required_ids = {"goose-cli", "gitleaks", "semgrep", "trufflehog", "socket-cli"}
found = set()

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
    reject_nonexact_semver(t.get("version"), "tools[%d].version" % i)
    reject_identity(t.get("identity"), "tools[%d].identity" % i)
    if t.get("package") not in (None, ""):
        pkg = str(t["package"])
        if "==" in pkg:
            name, ver = pkg.split("==", 1)
            if not name or not is_exact_numeric_semver(ver):
                errors.append("tools[%d] package must be name==exact-semver, got %r" % (i, pkg))
        elif "@" in pkg:
            ver = pkg.rsplit("@", 1)[1]
            if not is_exact_numeric_semver(ver):
                errors.append("tools[%d] package must be name@exact-semver, got %r" % (i, pkg))
        else:
            errors.append("tools[%d] package missing exact version pin: %r" % (i, pkg))
    dig = t.get("digest")
    if dig is None:
        errors.append("tools[%d] (%s) missing digest algorithm/value" % (i, tid))
    else:
        # socket-cli uses npm integrity; others sha256
        if tid == "socket-cli":
            validate_digest_obj(dig, "tools[%d]" % i, allowed=("sha512-integrity",))
        else:
            validate_digest_obj(dig, "tools[%d]" % i, allowed=("sha256",))
    url = t.get("source_url") or ""
    meta = t.get("source_meta_url") or ""
    if not (url.startswith("https://") and meta.startswith("https://")):
        errors.append("tools[%d] source URLs must be https" % i)
    for u in (url, meta):
        if re.search(r"(medium\.com|blogspot\.|dev\.to|twitter\.|x\.com/)", u):
            errors.append("tools[%d] non-authoritative source host: %s" % (i, u))
    ex = t.get("execution")
    if ex not in ("offline-validate-only", "pin-only", "owner-gated"):
        errors.append("tools[%d] unexpected execution: %r" % (i, ex))

missing = required_ids - found
for m in sorted(missing):
    errors.append("required tool id missing: %s" % m)

goose = next((t for t in tools if isinstance(t, dict) and t.get("id") == "goose-cli"), None)
if goose:
    if str(goose.get("version")) != "1.45.0":
        errors.append("goose-cli version must remain strategy-pinned 1.45.0")
    dig = (goose.get("digest") or {}).get("value") if isinstance(goose.get("digest"), dict) else None
    if dig != "90c50d653d7fd978ec5d436b548eca8613dc2d26d028b486b7c52271267ec500":
        errors.append("goose-cli macOS arm64 SHA-256 does not match adapters/goose/README.md pin")

socket = next((t for t in tools if isinstance(t, dict) and t.get("id") == "socket-cli"), None)
if socket:
    if socket.get("execution") != "owner-gated":
        errors.append("socket-cli must be execution owner-gated (paid credentials)")
    notes = (socket.get("notes") or "").lower()
    if "token" not in notes and "credential" not in notes:
        errors.append("socket-cli must document owner-gated credential truth")

def check_container_entry(c, where):
    """Containers must be immutable digest refs (@sha256:64hex). Tags are not enough."""
    image = c.get("image")
    dig = c.get("digest")
    has_image_digest = isinstance(image, str) and bool(IMAGE_DIGEST.fullmatch(image))
    has_digest_obj = False
    if dig is not None:
        if isinstance(dig, dict):
            validate_digest_obj(dig, where + ".digest", allowed=("sha256",))
            has_digest_obj = (
                str(dig.get("algorithm")) == "sha256"
                and isinstance(dig.get("value"), str)
                and bool(HEX64.fullmatch(str(dig.get("value"))))
            )
        elif isinstance(dig, str):
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", dig):
                errors.append("%s.digest string must be sha256:<64hex>, got %r" % (where, dig))
            else:
                has_digest_obj = True
        else:
            errors.append("%s.digest bad shape" % where)
    if not has_image_digest and not has_digest_obj:
        # tag-only / floating image (latest, stable, semver tags, bare names)
        if image is not None:
            errors.append(
                "%s image must be immutable @sha256:<64hex> (tag-only not enough): %r"
                % (where, image)
            )
        elif c.get("tag") is not None or c.get("version") is not None:
            errors.append(
                "%s tag/version without digest is not immutable: tag=%r version=%r"
                % (where, c.get("tag"), c.get("version"))
            )
        else:
            errors.append("%s missing immutable digest reference" % where)
    else:
        # even with digest, reject explicit floating tags/versions on the side
        for field in ("tag", "version"):
            if field in c and c[field] not in (None, ""):
                val = str(c[field])
                if FLOAT_WORD.fullmatch(val) or NONEXACT.search(val) or not is_exact_numeric_semver(val):
                    # semver tags alone are also not preferred when image lacks @sha256
                    if not has_image_digest:
                        errors.append("%s.%s is not immutable digest pin: %r" % (where, field, val))
                    elif FLOAT_WORD.fullmatch(val) or NONEXACT.search(val):
                        errors.append("floating pin in %s.%s: %r" % (where, field, val))
    for field in ("identity", "ref"):
        if field in c and c[field] not in (None, ""):
            val = str(c[field])
            if field == "ref" or val.startswith("refs/"):
                if not HEX40.fullmatch(val):
                    errors.append("%s.%s must be full 40-char commit SHA, got %r" % (where, field, val))
            elif not (IMAGE_DIGEST.fullmatch(val) or is_ok_identity(val) or re.fullmatch(r"sha256:[0-9a-f]{64}", val)):
                errors.append("floating/non-exact pin in %s.%s: %r" % (where, field, val))

def check_mcp_entry(c, where):
    """MCP/git refs: full commit SHA or exact package version/digest only."""
    for field in ("ref", "commit", "revision", "sha"):
        if field in c and c[field] not in (None, ""):
            val = str(c[field])
            if not HEX40.fullmatch(val):
                errors.append(
                    "%s.%s must be exact immutable full commit SHA (40 hex), got %r"
                    % (where, field, val)
                )
    if "version" in c and c["version"] not in (None, ""):
        reject_nonexact_semver(str(c["version"]), where + ".version")
    if "identity" in c and c["identity"] not in (None, ""):
        reject_identity(str(c["identity"]), where + ".identity")
    if "package" in c and c["package"] not in (None, ""):
        pkg = str(c["package"])
        if "@" in pkg:
            ver = pkg.rsplit("@", 1)[1]
            if not is_exact_numeric_semver(ver):
                errors.append("%s.package non-exact version: %r" % (where, pkg))
        elif "==" in pkg:
            ver = pkg.split("==", 1)[1]
            if not is_exact_numeric_semver(ver):
                errors.append("%s.package non-exact version: %r" % (where, pkg))
        else:
            errors.append("%s.package missing exact version: %r" % (where, pkg))
    if "digest" in c and c["digest"] is not None:
        dig = c["digest"]
        if isinstance(dig, dict):
            validate_digest_obj(dig, where + ".digest")
        elif isinstance(dig, str):
            if dig.startswith("sha512-"):
                validate_npm_integrity(dig, where + ".digest")
            elif dig.startswith("sha256:"):
                validate_sha256_value(dig[7:], where + ".digest")
            elif HEX64.fullmatch(dig):
                pass
            else:
                errors.append("%s.digest malformed: %r" % (where, dig))
    # Reject branch-like tags without commit
    for field in ("tag", "branch"):
        if field in c and c[field] not in (None, ""):
            errors.append("%s.%s is mutable; require full commit SHA instead: %r" % (where, field, c[field]))

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
        where = "%s[%d]" % (list_key, j)
        if list_key == "containers":
            check_container_entry(c, where)
        else:
            check_mcp_entry(c, where)

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

def walk(obj, path=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("notes", "commit_policy", "digest_instructions"):
                if isinstance(v, str) and re.search(
                    r"(?i)\b(version|tag|image|ref)\b.*=.*\b(latest|stable)\b", v
                ):
                    if "no " not in v.lower() and "never" not in v.lower() and "not" not in v.lower():
                        errors.append("possible floating pin in notes at %s" % path)
                continue
            walk(v, path + "." + k)
    elif isinstance(obj, list):
        for idx, v in enumerate(obj):
            walk(v, "%s[%d]" % (path, idx))
    elif isinstance(obj, str):
        if path.endswith(".version"):
            reject_nonexact_semver(obj, path)
        elif path.endswith(".identity"):
            reject_identity(obj, path)
        elif path.endswith(".tag") or path.endswith(".image") or path.endswith(".ref"):
            # containers/mcp handlers already cover entries; still catch float words
            if FLOAT_WORD.fullmatch(obj.strip()) or obj.startswith("refs/heads/"):
                errors.append("floating pin in %s: %r" % (path, obj))
            if path.endswith(".image") and obj and not IMAGE_DIGEST.fullmatch(obj):
                # only flag when under containers path
                if ".containers" in path or path.startswith(".containers"):
                    errors.append("non-digest container image in %s: %r" % (path, obj))

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
expect_fail "red: lock version latest fails" "$out" "$rc" "semver"

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
expect_fail "red: caret version range fails" "$out" "$rc" "semver"

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
echo "red fixtures: exact-semver / digest / ref mutant regressions (P1 repair)"
# ---------------------------------------------------------------------------
# Clone shipped lock and apply a Python mutation (no network, no extra deps).
lock_mutant() {
  local dest="$1"
  local mut="$2"
  python3 -c '
import json, sys
src, dst, mut = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as fh:
    data = json.load(fh)
exec(mut, {"data": data, "json": json})
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
' "$TOOLCHAIN_LOCK" "$dest" "$mut"
}

# --- Recipe schema / version wildcards & operators ---
cat > "$ROOT/bad-recipe-ver-x.yaml" <<'EOF'
version: "1.x"
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
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/bad-recipe-ver-x.yaml" 2>&1); rc=$?
expect_fail "red: recipe version 1.x fails" "$out" "$rc" "semver"

cat > "$ROOT/bad-recipe-ver-star.yaml" <<'EOF'
version: "1.2.*"
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
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/bad-recipe-ver-star.yaml" 2>&1); rc=$?
expect_fail "red: recipe version 1.2.* fails" "$out" "$rc" "semver"

cat > "$ROOT/bad-recipe-ver-ge.yaml" <<'EOF'
version: ">=1.2.3"
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
  - type: builtin
    name: developer
EOF
out=$(check_recipe_py "$ROOT/bad-recipe-ver-ge.yaml" 2>&1); rc=$?
expect_fail "red: recipe version >=1.2.3 fails" "$out" "$rc" "semver"

# Extension tool version wildcards (executable field, both yaml/yml)
cat > "$ROOT/bad-ext-ver-x.yaml" <<'EOF'
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
    cmd: tool
    version: "1.x"
EOF
out=$(check_recipe_py "$ROOT/bad-ext-ver-x.yaml" 2>&1); rc=$?
expect_fail "red: extension version 1.x fails (.yaml)" "$out" "$rc" "semver"

cat > "$ROOT/bad-ext-ver-star.yml" <<'EOF'
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
    cmd: tool
    version: "1.2.*"
EOF
out=$(check_recipe_py "$ROOT/bad-ext-ver-star.yml" 2>&1); rc=$?
expect_fail "red: extension version 1.2.* fails (.yml)" "$out" "$rc" "semver"

cat > "$ROOT/bad-ext-ver-range.yaml" <<'EOF'
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
    cmd: tool
    version: ">=1.2.3"
EOF
out=$(check_recipe_py "$ROOT/bad-ext-ver-range.yaml" 2>&1); rc=$?
expect_fail "red: extension version >=1.2.3 fails" "$out" "$rc" "semver"

# Package pin wildcards / operators / tilde / prerelease / whitespace / || / comma
cat > "$ROOT/bad-pkg-tilde.yaml" <<'EOF'
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
    args: ["-y", "some-mcp@~1.2.3"]
EOF
out=$(check_recipe_py "$ROOT/bad-pkg-tilde.yaml" 2>&1); rc=$?
expect_fail "red: package tilde range fails" "$out" "$rc" "semver"

cat > "$ROOT/bad-pkg-prerelease.yaml" <<'EOF'
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
    args: ["-y", "some-mcp@1.2.3-rc.1"]
EOF
out=$(check_recipe_py "$ROOT/bad-pkg-prerelease.yaml" 2>&1); rc=$?
expect_fail "red: package prerelease fails" "$out" "$rc" "semver"

cat > "$ROOT/bad-pkg-ws.yaml" <<'EOF'
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
    cmd: tool
    version: " 1.2.3"
EOF
out=$(check_recipe_py "$ROOT/bad-pkg-ws.yaml" 2>&1); rc=$?
expect_fail "red: version whitespace prefix fails" "$out" "$rc" "semver"

cat > "$ROOT/bad-pkg-or.yaml" <<'EOF'
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
    cmd: tool
    version: "1.2.3 || 1.3.0"
EOF
out=$(check_recipe_py "$ROOT/bad-pkg-or.yaml" 2>&1); rc=$?
expect_fail "red: version || range fails" "$out" "$rc"

cat > "$ROOT/bad-pkg-missing-seg.yaml" <<'EOF'
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
    cmd: tool
    version: "1.2"
EOF
out=$(check_recipe_py "$ROOT/bad-pkg-missing-seg.yaml" 2>&1); rc=$?
expect_fail "red: incomplete semver 1.2 fails" "$out" "$rc" "semver"

# Image tag-only (exact-looking semver tag still not immutable)
cat > "$ROOT/bad-ext-image-tag.yaml" <<'EOF'
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
    cmd: docker
    image: "registry/tool:1.2.3"
EOF
out=$(check_recipe_py "$ROOT/bad-ext-image-tag.yaml" 2>&1); rc=$?
expect_fail "red: extension image semver tag not immutable" "$out" "$rc" "sha256"

# MCP/git ref branch on recipe extension
cat > "$ROOT/bad-ext-ref-branch.yaml" <<'EOF'
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
    cmd: tool
    ref: "refs/heads/main"
EOF
out=$(check_recipe_py "$ROOT/bad-ext-ref-branch.yaml" 2>&1); rc=$?
expect_fail "red: extension ref refs/heads/main fails" "$out" "$rc" "commit"

# --- Lock tool version wildcards ---
lock_mutant "$ROOT/bad-lock-8x.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["version"] = "8.x"
        t["identity"] = "v8.x"
'
out=$(check_lock_py "$ROOT/bad-lock-8x.json" 2>&1); rc=$?
expect_fail "red: lock version 8.x fails" "$out" "$rc" "semver"

lock_mutant "$ROOT/bad-lock-830star.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["version"] = "8.30.*"
        t["identity"] = "v8.30.*"
'
out=$(check_lock_py "$ROOT/bad-lock-830star.json" 2>&1); rc=$?
expect_fail "red: lock version 8.30.* fails" "$out" "$rc" "semver"

lock_mutant "$ROOT/bad-lock-tilde.json" '
for t in data["tools"]:
    if t.get("id") == "semgrep":
        t["version"] = "~1.172.0"
'
out=$(check_lock_py "$ROOT/bad-lock-tilde.json" 2>&1); rc=$?
expect_fail "red: lock tilde version fails" "$out" "$rc"

lock_mutant "$ROOT/bad-lock-prerelease.json" '
for t in data["tools"]:
    if t.get("id") == "semgrep":
        t["version"] = "1.172.0-rc1"
'
out=$(check_lock_py "$ROOT/bad-lock-prerelease.json" 2>&1); rc=$?
expect_fail "red: lock prerelease version fails" "$out" "$rc" "semver"

lock_mutant "$ROOT/bad-lock-ws-ver.json" '
for t in data["tools"]:
    if t.get("id") == "semgrep":
        t["version"] = " 1.172.0"
'
out=$(check_lock_py "$ROOT/bad-lock-ws-ver.json" 2>&1); rc=$?
expect_fail "red: lock version whitespace fails" "$out" "$rc" "semver"

# Container registry/tool:stable (independent review mutant)
lock_mutant "$ROOT/bad-lock-stable-image.json" '
data["containers"] = [{
    "id": "tool-image",
    "image": "registry/tool:stable",
    "tag": "stable",
    "version": "stable",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-stable-image.json" 2>&1); rc=$?
expect_fail "red: container registry/tool:stable fails" "$out" "$rc" "immutable"

# Container exact-looking semver tag without digest
lock_mutant "$ROOT/bad-lock-semver-tag-image.json" '
data["containers"] = [{
    "id": "tool-image",
    "image": "registry/tool:1.2.3",
    "tag": "1.2.3",
    "version": "1.2.3",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-semver-tag-image.json" 2>&1); rc=$?
expect_fail "red: container semver tag without digest fails" "$out" "$rc" "immutable"

# Malformed container digest
lock_mutant "$ROOT/bad-lock-bad-image-digest.json" '
data["containers"] = [{
    "id": "tool-image",
    "image": "registry/tool@sha256:deadbeef",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-bad-image-digest.json" 2>&1); rc=$?
expect_fail "red: container malformed @sha256 fails" "$out" "$rc"

# MCP git ref refs/heads/main
lock_mutant "$ROOT/bad-lock-mcp-branch.json" '
data["mcp_packages"] = [{
    "id": "example-mcp",
    "name": "example-mcp",
    "ref": "refs/heads/main",
    "version": "1.0.0",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-branch.json" 2>&1); rc=$?
expect_fail "red: MCP ref refs/heads/main fails" "$out" "$rc" "commit"

# MCP short SHA
lock_mutant "$ROOT/bad-lock-mcp-shortsha.json" '
data["mcp_packages"] = [{
    "id": "example-mcp",
    "name": "example-mcp",
    "ref": "90c50d653d7fd978ec5d",
    "version": "1.0.0",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-shortsha.json" 2>&1); rc=$?
expect_fail "red: MCP short SHA fails" "$out" "$rc" "commit"

# MCP branch word main
lock_mutant "$ROOT/bad-lock-mcp-main.json" '
data["mcp_packages"] = [{
    "id": "example-mcp",
    "name": "example-mcp",
    "ref": "main",
    "version": "1.0.0",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-main.json" 2>&1); rc=$?
expect_fail "red: MCP ref main fails" "$out" "$rc" "commit"

# Malformed Socket integrity sha512-not-base64
lock_mutant "$ROOT/bad-lock-socket-b64.json" '
for t in data["tools"]:
    if t.get("id") == "socket-cli":
        t["digest"] = {"algorithm": "sha512-integrity", "value": "sha512-not-base64"}
'
out=$(check_lock_py "$ROOT/bad-lock-socket-b64.json" 2>&1); rc=$?
expect_fail "red: socket integrity sha512-not-base64 fails" "$out" "$rc" "malformed"

# Empty integrity payload
lock_mutant "$ROOT/bad-lock-socket-empty.json" '
for t in data["tools"]:
    if t.get("id") == "socket-cli":
        t["digest"] = {"algorithm": "sha512-integrity", "value": "sha512-"}
'
out=$(check_lock_py "$ROOT/bad-lock-socket-empty.json" 2>&1); rc=$?
expect_fail "red: socket integrity empty payload fails" "$out" "$rc" "malformed"

# Wrong algorithm on socket (sha256 instead of integrity)
lock_mutant "$ROOT/bad-lock-socket-algo.json" '
for t in data["tools"]:
    if t.get("id") == "socket-cli":
        t["digest"] = {"algorithm": "sha256", "value": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
'
out=$(check_lock_py "$ROOT/bad-lock-socket-algo.json" 2>&1); rc=$?
expect_fail "red: socket wrong digest algorithm fails" "$out" "$rc" "algorithm"

# digest object {algorithm: md5, value: abc}
lock_mutant "$ROOT/bad-lock-md5.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["digest"] = {"algorithm": "md5", "value": "abc"}
'
out=$(check_lock_py "$ROOT/bad-lock-md5.json" 2>&1); rc=$?
expect_fail "red: digest algorithm md5 value abc fails" "$out" "$rc" "algorithm"

# sha1 forbidden
lock_mutant "$ROOT/bad-lock-sha1.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["digest"] = {"algorithm": "sha1", "value": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
'
out=$(check_lock_py "$ROOT/bad-lock-sha1.json" 2>&1); rc=$?
expect_fail "red: digest algorithm sha1 fails" "$out" "$rc" "algorithm"

# short sha256
lock_mutant "$ROOT/bad-lock-short-sha.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["digest"] = {"algorithm": "sha256", "value": "b40ab0ae55c50596"}
'
out=$(check_lock_py "$ROOT/bad-lock-short-sha.json" 2>&1); rc=$?
expect_fail "red: short sha256 digest fails" "$out" "$rc" "noncanonical"

# nonhex sha256
lock_mutant "$ROOT/bad-lock-nonhex-sha.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["digest"] = {"algorithm": "sha256", "value": "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"}
'
out=$(check_lock_py "$ROOT/bad-lock-nonhex-sha.json" 2>&1); rc=$?
expect_fail "red: nonhex sha256 digest fails" "$out" "$rc" "noncanonical"

# long sha256
lock_mutant "$ROOT/bad-lock-long-sha.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["digest"] = {"algorithm": "sha256", "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5ff"}
'
out=$(check_lock_py "$ROOT/bad-lock-long-sha.json" 2>&1); rc=$?
expect_fail "red: long sha256 digest fails" "$out" "$rc" "noncanonical"

# Green: valid immutable container + MCP commit pin still passes lock checker
lock_mutant "$ROOT/ok-lock-immutable.json" '
data["containers"] = [{
    "id": "tool-image",
    "image": "registry/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
data["mcp_packages"] = [{
    "id": "example-mcp",
    "name": "example-mcp",
    "ref": "90c50d653d7fd978ec5d436b548eca8613dc2d26",
    "version": "1.0.0",
    "identity": "example-mcp@1.0.0",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-immutable.json" 2>&1); rc=$?
expect_pass "green: lock with digest image + full commit MCP ref" "$out" "$rc"

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
