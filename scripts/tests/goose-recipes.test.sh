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

# Hermetic git identity (#101): suites that commit must not read ambient global
# user.name/email. Pass with HOME pointed at an empty directory.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"


SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
RECIPES_DIR="$REPO_ROOT/playbooks/recipes"
FINDINGS_TEMPLATE="$REPO_ROOT/playbooks/red-team/findings/TEMPLATE.md"
RED_TEAM_RECIPE="$RECIPES_DIR/red-team.yaml"
TOOLCHAIN_LOCK="$RECIPES_DIR/red-team.toolchain.json"
BUILDER_RECIPE="$RECIPES_DIR/builder.yaml"
REVIEWER_RECIPE="$RECIPES_DIR/reviewer.yaml"
SECURITY_RECIPE="$RECIPES_DIR/security.yaml"
# Core role mirrors (#34) — prose playbook is source of truth; recipe pins its sha256.
ROLE_RECIPES=(builder reviewer security)

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
# ranges (|| , hyphen caret tilde), branch words, and leading zeros
# (except the single digit 0 as a complete numeric identifier).
EXACT_SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
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
import os
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

# Closed-world top-level schema for gibson.toolchain-lock/v1.
# Exact allowed key set; reject unknown/extra top-level fields.
LOCK_ALLOWED_TOP = {
    "schema",
    "version",
    "recipe",
    "goose_recipe_schema",
    "retrieved_utc",
    "notes",
    "digest_instructions",
    "tools",
    "containers",
    "mcp_packages",
    "bundled_extensions",
}
for k in data.keys():
    if k not in LOCK_ALLOWED_TOP:
        errors.append("unsupported top-level lock key: %s" % k)

# recipe + goose_recipe_schema are identity claims bound to the shipped recipe
# (not free-form metadata). Missing either is fail-closed.
for req in ("schema", "version", "tools", "recipe", "goose_recipe_schema"):
    if req not in data:
        errors.append("lock missing field: %s" % req)

if data.get("schema") != "gibson.toolchain-lock/v1":
    errors.append("unexpected schema: %r" % data.get("schema"))

# Exact MAJOR.MINOR.PATCH; leading zeros forbidden except sole digit 0.
EXACT_SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
# Registry/repository path required before @sha256 (digest-only is not a locator).
IMAGE_DIGEST = re.compile(r"^.+/.+@sha256:[0-9a-f]{64}$")
FLOAT_WORD = re.compile(r"^(latest|stable|main|master|\*|x)$", re.I)
# Operators, wildcards, ranges, incomplete segments
NONEXACT = re.compile(
    r"(\|\||>=|<=|[<>]|~|\^|,|\.x\b|\.X\b|\.\*|\bx\.|\bX\.|"
    r"refs/heads/|refs/tags/|(^|/)(main|master|latest|stable)(/|$))",
    re.I,
)
# Embedded version-like tokens in free-text locator fields (URLs, assets, …).
# Captures optional v prefix + three numeric segments; used for cross-binding.
EMBEDDED_VER = re.compile(
    r"(?<![0-9])(v?)([0-9]+)\.([0-9]+)\.([0-9]+)(?![0-9])"
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
    if s.startswith("v") and is_exact_numeric_semver(s[1:]):
        return True
    # name@exact or @scope/name@exact (not name==ver — that is package only)
    if "==" in s:
        return False
    if "@" in s:
        name, ver = s.rsplit("@", 1)
        if name and is_exact_numeric_semver(ver):
            if s.startswith("@"):
                # scoped: @scope/name@version requires ≥2 @
                return s.count("@") >= 2 and "/" in name
            return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", name))
    return False

def reject_identity(s, where):
    if s is None:
        errors.append("missing identity at %s" % where)
        return
    s = str(s)
    if not is_ok_identity(s):
        errors.append("non-exact identity pin in %s: %r" % (where, s))

def identity_claimed_version(s):
    """Return the exact version pin claimed by a tool identity, or None."""
    if not isinstance(s, str) or s != s.strip() or any(ch.isspace() for ch in s):
        return None
    if is_exact_numeric_semver(s):
        return s
    if s.startswith("v") and is_exact_numeric_semver(s[1:]):
        return s[1:]
    if "==" in s:
        return None
    if "@" in s:
        name, ver = s.rsplit("@", 1)
        if name and is_exact_numeric_semver(ver):
            return ver
    return None

def package_claimed_pin(pkg):
    """Parse package pin → (name, exact-version) or None."""
    if not isinstance(pkg, str) or pkg != pkg.strip() or any(ch.isspace() for ch in pkg):
        return None
    if "==" in pkg:
        name, ver = pkg.split("==", 1)
        if name and is_exact_numeric_semver(ver):
            return (name, ver)
        return None
    if "@" in pkg:
        name, ver = pkg.rsplit("@", 1)
        if name and is_exact_numeric_semver(ver):
            return (name, ver)
    return None

def identity_package_name(s):
    """If identity is name@ver (or scoped), return name; else None."""
    if not isinstance(s, str) or "==" in s or "@" not in s:
        return None
    if not is_ok_identity(s):
        return None
    name, ver = s.rsplit("@", 1)
    if name and is_exact_numeric_semver(ver):
        return name
    return None

def iter_embedded_version_claims(text):
    """Yield (raw_token, normalized_or_None, leading_zero) from free text."""
    if not isinstance(text, str):
        return
    for m in EMBEDDED_VER.finditer(text):
        raw = m.group(0)
        a, b, c = m.group(2), m.group(3), m.group(4)
        leading = any((p.startswith("0") and p != "0") for p in (a, b, c))
        if leading:
            yield (raw, None, True)
        else:
            yield (raw, "%s.%s.%s" % (a, b, c), False)

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

# lock document version — exact semver and pinned for gibson.toolchain-lock/v1
# (adjacent top-level version claim; free 9.9.9 would otherwise pass shape checks)
if "version" in data:
    reject_nonexact_semver(str(data.get("version")), "lock.version")
    ver_s = str(data.get("version"))
    if is_exact_numeric_semver(ver_s) and ver_s != "1.0.0":
        errors.append(
            "lock.version must be 1.0.0 for gibson.toolchain-lock/v1 (got %r)"
            % data.get("version")
        )

# --- Fail-closed top-level recipe / goose_recipe_schema binding ---
# Independent review: recipe→other.yaml and goose_recipe_schema→9.9.9 returned
# rc=0 while only schema/version/tools were required. Bind identity claims to
# the shipped red-team recipe reference and its Goose schema/version contract.
CANON_RECIPE_REF = "red-team.yaml"
recipe_ref = data.get("recipe")
if recipe_ref is None or recipe_ref == "":
    pass  # missing already reported
elif not isinstance(recipe_ref, str):
    errors.append(
        "lock.recipe must be the canonical shipped recipe reference %r (got %r)"
        % (CANON_RECIPE_REF, recipe_ref)
    )
elif recipe_ref != recipe_ref.strip() or any(ch.isspace() for ch in recipe_ref):
    errors.append(
        "lock.recipe must be exact basename %r without whitespace (got %r)"
        % (CANON_RECIPE_REF, recipe_ref)
    )
elif recipe_ref != CANON_RECIPE_REF:
    errors.append(
        "lock.recipe must be the canonical shipped recipe reference %r (got %r)"
        % (CANON_RECIPE_REF, recipe_ref)
    )

# Prefer schema/version derived from the resolvable recipe file when present
# (shipped lock lives beside red-team.yaml). Temp lock fixtures keep the Goose
# Recipe type contract 1.0.0 — same pin enforced by check_recipe_py.
expected_goose_schema = "1.0.0"
lock_dir = os.path.dirname(os.path.abspath(path))
recipe_path = os.path.join(lock_dir, CANON_RECIPE_REF)
if os.path.isfile(recipe_path):
    try:
        import yaml as _yaml  # optional; offline sensor may lack PyYAML
        with open(recipe_path, "r", encoding="utf-8") as _rf:
            _rdata = _yaml.safe_load(_rf.read())
        if isinstance(_rdata, dict) and _rdata.get("version") not in (None, ""):
            expected_goose_schema = str(_rdata.get("version")).strip()
    except Exception:
        pass

grs = data.get("goose_recipe_schema")
if grs is None or grs == "":
    pass  # missing already reported
else:
    grs_s = str(grs)
    if grs_s != grs_s.strip() or any(ch.isspace() for ch in grs_s):
        errors.append(
            "lock.goose_recipe_schema non-exact (whitespace): %r" % grs
        )
    elif not is_exact_numeric_semver(grs_s):
        errors.append(
            "lock.goose_recipe_schema non-exact semver: %r" % grs
        )
    elif grs_s != expected_goose_schema:
        errors.append(
            "lock.goose_recipe_schema must equal recipe schema/version "
            "contract %r (got %r)" % (expected_goose_schema, grs)
        )

# Fail-closed digest_instructions: closed schema + exact shipped commands.
# Recipe hashing must use exactly one canonical repository-relative operand
# playbooks/recipes/red-team.yaml — never absolute paths, basename-only
# matches, ambiguity, repeated operands, shell composition, or alternate files.
# (Independent review residual fail-opens: portable deleted, /tmp/red-team.yaml
# basename-only match, dual /tmp + playbooks operands with equal basenames.)
CANON_RECIPE_REPO_PATH = "playbooks/recipes/red-team.yaml"
CANON_LOCK_REPO_PATH = "playbooks/recipes/red-team.toolchain.json"
CANON_DIGEST_INSTRUCTIONS = {
    "macOS": {
        "recipe_sha256": (
            "shasum -a 256 playbooks/recipes/red-team.yaml | awk '{print $1}'"
        ),
        "toolchain_lock_sha256": (
            "shasum -a 256 playbooks/recipes/red-team.toolchain.json"
            " | awk '{print $1}'"
        ),
        "target_profile_sha256": (
            "shasum -a 256 <target-profile-path> | awk '{print $1}'"
        ),
    },
    "portable": {
        "recipe_sha256": (
            "sha256sum playbooks/recipes/red-team.yaml | awk '{print $1}'"
        ),
        "toolchain_lock_sha256": (
            "sha256sum playbooks/recipes/red-team.toolchain.json"
            " | awk '{print $1}'"
        ),
        "target_profile_sha256": (
            "sha256sum <target-profile-path> | awk '{print $1}'"
        ),
    },
    "commit_policy": (
        "Do not commit generated run digests. Stamp digests into the dated "
        "findings ledger at run time only."
    ),
}
# Path tokens: absolute or relative paths ending in .yaml/.yml/.json
PATH_TOKEN = re.compile(
    r"(?<![A-Za-z0-9._-])("
    r"(?:/[A-Za-z0-9._-]+)+(?:\.ya?ml|\.json)"
    r"|(?:[A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+(?:\.ya?ml|\.json)"
    r")\b"
)
YAML_PATH_TOKEN = re.compile(
    r"(?<![A-Za-z0-9._-])((?:/?[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.ya?ml)\b"
)

di_bind = data.get("digest_instructions")
if di_bind is None or di_bind == "":
    errors.append("digest_instructions missing")
elif not isinstance(di_bind, dict):
    errors.append("digest_instructions must be an object")
else:
    di_keys = set(di_bind.keys())
    expected_di_keys = {"macOS", "portable", "commit_policy"}
    for extra in sorted(di_keys - expected_di_keys):
        errors.append("digest_instructions unsupported key: %s" % extra)
    for miss in sorted(expected_di_keys - di_keys):
        errors.append("digest_instructions missing required key: %s" % miss)
    # commit_policy exact
    if "commit_policy" in di_bind:
        if di_bind.get("commit_policy") != CANON_DIGEST_INSTRUCTIONS["commit_policy"]:
            errors.append(
                "digest_instructions.commit_policy must equal shipped canonical "
                "policy text (got %r)" % di_bind.get("commit_policy")
            )
    for platform_key in ("macOS", "portable"):
        if platform_key not in di_bind:
            continue
        plat = di_bind.get(platform_key)
        where_plat = "digest_instructions.%s" % platform_key
        if not isinstance(plat, dict):
            errors.append("%s must be an object" % where_plat)
            continue
        expected_plat = CANON_DIGEST_INSTRUCTIONS[platform_key]
        plat_keys = set(plat.keys())
        exp_plat_keys = set(expected_plat.keys())
        for extra in sorted(plat_keys - exp_plat_keys):
            errors.append("%s unsupported key: %s" % (where_plat, extra))
        for miss in sorted(exp_plat_keys - plat_keys):
            errors.append("%s missing required key: %s" % (where_plat, miss))
        for cmd_key, expected_cmd in expected_plat.items():
            where_di = "%s.%s" % (where_plat, cmd_key)
            if cmd_key not in plat:
                continue
            cmd = plat.get(cmd_key)
            if not isinstance(cmd, str) or not cmd.strip():
                errors.append(
                    "%s must be the exact shipped digest command string" % where_di
                )
                continue
            # Exact equality to shipped command (closed-world reproducibility lock)
            if cmd != expected_cmd:
                errors.append(
                    "%s must equal exact shipped command %r (got %r)"
                    % (where_di, expected_cmd, cmd)
                )
            # Structural path rules for recipe_sha256 (defense in depth / readable)
            if cmd_key == "recipe_sha256":
                yaml_tokens = YAML_PATH_TOKEN.findall(cmd)
                if len(yaml_tokens) != 1:
                    errors.append(
                        "%s must contain exactly one .yaml/.yml path operand "
                        "(got %r); no repeated/ambiguous/absolute dual paths"
                        % (where_di, yaml_tokens)
                    )
                elif yaml_tokens[0] != CANON_RECIPE_REPO_PATH:
                    errors.append(
                        "%s recipe path must be exact repository-relative %r "
                        "(got %r; basename-only/absolute/alternate paths rejected)"
                        % (where_di, CANON_RECIPE_REPO_PATH, yaml_tokens[0])
                    )
                if recipe_ref and isinstance(recipe_ref, str):
                    if os.path.basename(CANON_RECIPE_REPO_PATH) != recipe_ref:
                        errors.append(
                            "lock.recipe %r inconsistent with canonical recipe "
                            "path %r" % (recipe_ref, CANON_RECIPE_REPO_PATH)
                        )
            if cmd_key == "toolchain_lock_sha256":
                # Require exact repo-relative lock path; reject absolute/basename games
                if CANON_LOCK_REPO_PATH not in cmd:
                    errors.append(
                        "%s must reference exact repository-relative lock path %r"
                        % (where_di, CANON_LOCK_REPO_PATH)
                    )
                abs_like = re.findall(
                    r"(?<![A-Za-z0-9._-])(/[A-Za-z0-9._/-]+\.json)\b", cmd
                )
                for ap in abs_like:
                    if ap != CANON_LOCK_REPO_PATH:
                        errors.append(
                            "%s absolute/non-canonical lock path rejected: %r"
                            % (where_di, ap)
                        )

tools = data.get("tools") or []
if not isinstance(tools, list) or not tools:
    errors.append("tools must be a non-empty list")

ids = []
required_ids = {"goose-cli", "gitleaks", "semgrep", "trufflehog", "socket-cli"}
found = set()

# Canonical supported-core-tool closed profiles (fixed lock set).
# Exact name/kind/version/identity/execution/digest/origin/asset — not shape-only.
# Version-token scanning alone is not identity binding; digest must match the
# shipped accurate lock values, not merely well-formed hex/SRI.
CORE_TOOL_PROFILES = {
    "goose-cli": {
        "name": "Goose CLI",
        "kind": "cli",
        "version": "1.45.0",
        "identity": "v1.45.0",
        "platform": "darwin-arm64",
        "asset": "goose-aarch64-apple-darwin.tar.gz",
        "digest_algorithm": "sha256",
        "digest_value": (
            "90c50d653d7fd978ec5d436b548eca8613dc2d26d028b486b7c52271267ec500"
        ),
        "source_url": (
            "https://github.com/aaif-goose/goose/releases/download/"
            "v1.45.0/goose-aarch64-apple-darwin.tar.gz"
        ),
        "source_meta_url": (
            "https://github.com/aaif-goose/goose/releases/tag/v1.45.0"
        ),
        "execution": "offline-validate-only",
        "origin_stem": "aaif-goose/goose",
    },
    "gitleaks": {
        "name": "gitleaks",
        "kind": "cli",
        "version": "8.30.1",
        "identity": "v8.30.1",
        "platform": "darwin-arm64",
        "asset": "gitleaks_8.30.1_darwin_arm64.tar.gz",
        "digest_algorithm": "sha256",
        "digest_value": (
            "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"
        ),
        "source_url": (
            "https://github.com/gitleaks/gitleaks/releases/download/"
            "v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz"
        ),
        "source_meta_url": (
            "https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1"
        ),
        "execution": "pin-only",
        "origin_stem": "gitleaks/gitleaks",
    },
    "semgrep": {
        "name": "Semgrep",
        "kind": "cli",
        "version": "1.172.0",
        "identity": "1.172.0",
        "package": "semgrep==1.172.0",
        "distribution": "pypi",
        "asset": "semgrep-1.172.0.tar.gz",
        "digest_algorithm": "sha256",
        "digest_value": (
            "7377cc350c64c7b83de20090cb2843d875da1d806690fd604e446ed544b56d71"
        ),
        "source_url": "https://pypi.org/project/semgrep/1.172.0/",
        "source_meta_url": "https://pypi.org/pypi/semgrep/1.172.0/json",
        "execution": "pin-only",
        "origin_stem": "project/semgrep",
    },
    "trufflehog": {
        "name": "TruffleHog",
        "kind": "cli",
        "version": "3.96.0",
        "identity": "v3.96.0",
        "platform": "darwin-arm64",
        "asset": "trufflehog_3.96.0_darwin_arm64.tar.gz",
        "digest_algorithm": "sha256",
        "digest_value": (
            "87478306b95ca2420cfb844b7582383ac60b922e262350a0088e797f328d2e62"
        ),
        "source_url": (
            "https://github.com/trufflesecurity/trufflehog/releases/download/"
            "v3.96.0/trufflehog_3.96.0_darwin_arm64.tar.gz"
        ),
        "source_meta_url": (
            "https://github.com/trufflesecurity/trufflehog/releases/tag/v3.96.0"
        ),
        "execution": "pin-only",
        "origin_stem": "trufflesecurity/trufflehog",
    },
    "socket-cli": {
        "name": "Socket CLI",
        "kind": "cli",
        "version": "1.1.147",
        "identity": "socket@1.1.147",
        "package": "socket@1.1.147",
        "distribution": "npm",
        "asset": "socket-1.1.147.tgz",
        "digest_algorithm": "sha512-integrity",
        "digest_value": (
            "sha512-TZWg3JQPuykBb1XKWVhmYQh+Zl1C0qU0nUxVzzPM5Q/"
            "AbC0oQGC9yKDmGQhizy/KLT64I671UjTvrjQ9MBOvGQ=="
        ),
        "source_url": (
            "https://registry.npmjs.org/socket/-/socket-1.1.147.tgz"
        ),
        "source_meta_url": "https://registry.npmjs.org/socket/1.1.147",
        "execution": "owner-gated",
        "origin_stem": "socket",
    },
}
# Keys present on every shipped core tool entry.
TOOL_REQUIRED_KEYS = {
    "id", "name", "kind", "version", "identity", "asset", "digest",
    "source_url", "source_meta_url", "retrieved_utc", "execution", "notes",
}
# Optional equal-only locator aliases (not in shipped entries; if present must
# equal the canonical field). repository/ref are NOT allowed on tools[].
TOOL_OPTIONAL_EQUAL_ALIASES = {
    "artifact", "filename", "tarball", "source", "download_url", "url",
    "integrity",
}
TOOL_FORBIDDEN_ALIASES = {"repository", "ref", "repo", "git", "commit", "tag"}

for i, t in enumerate(tools):
    if not isinstance(t, dict):
        errors.append("tools[%d] not object" % i)
        continue
    tid = t.get("id")
    where = "tools[%d]" % i
    if not tid:
        errors.append("%s missing id" % where)
    else:
        if tid in ids:
            errors.append("duplicate tool id: %s" % tid)
        ids.append(tid)
        found.add(tid)
    for f in ("name", "version", "identity", "source_url", "source_meta_url", "retrieved_utc", "execution"):
        if not t.get(f):
            errors.append("%s (%s) missing %s" % (where, tid, f))
    reject_nonexact_semver(t.get("version"), "%s.version" % where)
    reject_identity(t.get("identity"), "%s.identity" % where)
    if t.get("package") not in (None, ""):
        pkg = str(t["package"])
        parsed_pkg = package_claimed_pin(pkg)
        if parsed_pkg is None:
            if "==" in pkg or "@" in pkg:
                errors.append(
                    "%s package must be name==exact-semver or name@exact-semver, got %r"
                    % (where, pkg)
                )
            else:
                errors.append("%s package missing exact version pin: %r" % (where, pkg))
    dig = t.get("digest")
    if dig is None:
        errors.append("%s (%s) missing digest algorithm/value" % (where, tid))
    else:
        # socket-cli uses npm integrity; others sha256
        if tid == "socket-cli":
            validate_digest_obj(dig, where, allowed=("sha512-integrity",))
        else:
            validate_digest_obj(dig, where, allowed=("sha256",))
    url = t.get("source_url") or ""
    meta = t.get("source_meta_url") or ""
    if not (url.startswith("https://") and meta.startswith("https://")):
        errors.append("%s source URLs must be https" % where)
    for u in (url, meta):
        if re.search(r"(medium\.com|blogspot\.|dev\.to|twitter\.|x\.com/)", u):
            errors.append("%s non-authoritative source host: %s" % (where, u))
    ex = t.get("execution")
    if ex not in ("offline-validate-only", "pin-only", "owner-gated"):
        errors.append("%s unexpected execution: %r" % (where, ex))

    # --- Fail-closed cross-field binding for core tools[] ---
    # Canonical identity/pin: required exact tools[i].version.
    # Every redundant locator claim (identity/package/asset/artifact/source*/
    # repository/ref/url aliases/integrity) must be absent or normalize to
    # exactly that pin (and package-shaped names must agree with each other).
    # Independent syntactic validity of a field is not enough.
    ver = t.get("version")
    if isinstance(ver, str) and is_exact_numeric_semver(ver):
        canon = ver
        # Structured identity claim
        ident = t.get("identity")
        id_ver = None
        if ident not in (None, ""):
            id_ver = identity_claimed_version(str(ident))
            if id_ver is not None and id_ver != canon:
                errors.append(
                    "%s conflicting identity vs version "
                    "(identity %r != canonical pin %r)" % (where, ident, canon)
                )
        # Structured package claim
        pkg_pin = None
        if t.get("package") not in (None, ""):
            pkg_pin = package_claimed_pin(str(t["package"]))
            if pkg_pin is not None and pkg_pin[1] != canon:
                errors.append(
                    "%s conflicting package vs version "
                    "(package %r != canonical pin %r)"
                    % (where, t["package"], canon)
                )
        # Package-shaped identity must agree with package field when both present
        if pkg_pin is not None and ident not in (None, ""):
            iname = identity_package_name(str(ident))
            if iname is not None and iname != pkg_pin[0]:
                errors.append(
                    "%s conflicting package identity name "
                    "(identity %r vs package %r)" % (where, ident, t["package"])
                )
        # integrity alias must equal digest.value when both present
        if t.get("integrity") not in (None, ""):
            dval = None
            if isinstance(t.get("digest"), dict):
                dval = t["digest"].get("value")
            if dval is None or str(t["integrity"]) != str(dval):
                errors.append(
                    "%s conflicting integrity vs digest.value" % where
                )
        # Free-text / filename / URL embedding: every version-like token must
        # equal the canonical pin (no hard-coded mutant strings).
        # notes/retrieved_utc are intentionally excluded (prose / dates).
        locator_fields = (
            "identity",
            "package",
            "asset",
            "artifact",
            "source_url",
            "source_meta_url",
            "source",
            "repository",
            "ref",
            "tarball",
            "filename",
            "download_url",
            "url",
        )
        for field in locator_fields:
            if field not in t or t[field] in (None, ""):
                continue
            val = str(t[field])
            for raw, norm, leading_zero in iter_embedded_version_claims(val):
                if leading_zero:
                    errors.append(
                        "%s.%s embeds non-exact/leading-zero version %r"
                        % (where, field, raw)
                    )
                elif norm != canon:
                    errors.append(
                        "%s conflicting %s version claim %r vs canonical pin %r"
                        % (where, field, raw, canon)
                    )
        # Optional artifact must not contradict asset when both present as
        # equal-shaped filenames without version tokens is fine; when both
        # embed versions, the free-text scan already enforces pin agreement.
        # repository / ref without version tokens are allowed only as optional
        # non-version locators (no alternate pin).

    # --- Fail-closed exact canonical profile for supported core tools ---
    # Closed-world: exact id set, name, kind, identity, execution, digest
    # value (not merely well-formed), origin URLs, asset, package/platform.
    # Unsupported tool aliases (repository/ref/…) are rejected; optional
    # equal-only aliases must match the canonical field exactly (no substring).
    if tid in CORE_TOOL_PROFILES:
        prof = CORE_TOOL_PROFILES[tid]
        # Closed key set for this tool entry
        allowed_keys = set(TOOL_REQUIRED_KEYS) | set(TOOL_OPTIONAL_EQUAL_ALIASES)
        if "platform" in prof:
            allowed_keys.add("platform")
        if "package" in prof:
            allowed_keys.add("package")
        if "distribution" in prof:
            allowed_keys.add("distribution")
        for k in t.keys():
            if k in TOOL_FORBIDDEN_ALIASES:
                errors.append(
                    "%s (%s) unsupported tool alias %r (not in shipped schema; "
                    "reject repository/ref/commit-style fields on tools[])"
                    % (where, tid, k)
                )
            elif k not in allowed_keys:
                errors.append(
                    "%s (%s) unknown/extra tool field: %s" % (where, tid, k)
                )
        for rk in TOOL_REQUIRED_KEYS:
            if rk == "id":
                continue
            if t.get(rk) in (None, ""):
                errors.append(
                    "%s (%s) missing required field %s" % (where, tid, rk)
                )
        # Exact name / kind / version / execution
        if t.get("name") not in (None, "") and str(t.get("name")) != prof["name"]:
            errors.append(
                "%s (%s) name must be exact canonical %r (got %r)"
                % (where, tid, prof["name"], t.get("name"))
            )
        if t.get("kind") in (None, ""):
            errors.append(
                "%s (%s) missing required kind %r" % (where, tid, prof["kind"])
            )
        elif str(t.get("kind")) != prof["kind"]:
            errors.append(
                "%s (%s) kind must be exact %r (got %r)"
                % (where, tid, prof["kind"], t.get("kind"))
            )
        if str(t.get("version") or "") != prof["version"]:
            errors.append(
                "%s (%s) version must be supported core pin %r (got %r)"
                % (where, tid, prof["version"], t.get("version"))
            )
        # Exact identity: profile identity string byte-for-byte after only
        # documented normalization (str() of a non-empty field). Reject bare
        # version, alternate v-prefix, and package-shaped shorthands even when
        # version-equivalent (e.g. gitleaks 8.30.1 != v8.30.1; semgrep
        # v1.172.0/semgrep@1.172.0 != 1.172.0; socket v1.1.147 != socket@1.1.147).
        ident_s = t.get("identity")
        if ident_s not in (None, ""):
            if str(ident_s) != prof["identity"]:
                errors.append(
                    "%s (%s) identity must equal exact profile identity %r "
                    "(got %r; shorthand/alternate prefix/package forms rejected)"
                    % (where, tid, prof["identity"], ident_s)
                )
        # Exact execution mode per tool (enum shape alone is not enough)
        if t.get("execution") not in (None, ""):
            if str(t.get("execution")) != prof["execution"]:
                errors.append(
                    "%s (%s) execution must be exact %r (got %r)"
                    % (where, tid, prof["execution"], t.get("execution"))
                )
        # Exact digest algorithm + value (shipped lock pins, not well-formed-only)
        dig = t.get("digest")
        if isinstance(dig, dict):
            dig_algo = dig.get("algorithm")
            dig_val = dig.get("value")
            if dig_algo not in (None, "") and str(dig_algo) != prof["digest_algorithm"]:
                errors.append(
                    "%s (%s) digest.algorithm must be exact %r (got %r)"
                    % (where, tid, prof["digest_algorithm"], dig_algo)
                )
            if dig_val not in (None, "") and str(dig_val) != prof["digest_value"]:
                errors.append(
                    "%s (%s) digest.value must equal exact shipped pin "
                    "(got well-formed but non-canonical value)"
                    % (where, tid)
                )
            # Digest object closed key set
            for dk in dig.keys():
                if dk not in ("algorithm", "value"):
                    errors.append(
                        "%s (%s) digest unknown key: %s" % (where, tid, dk)
                    )
        # Required artifact basename (official supported platform package)
        asset_val = t.get("asset")
        if asset_val in (None, ""):
            errors.append(
                "%s (%s) missing required asset (canonical supported artifact)"
                % (where, tid)
            )
        elif str(asset_val) != prof["asset"]:
            errors.append(
                "%s (%s) asset must be canonical supported artifact %r (got %r)"
                % (where, tid, prof["asset"], asset_val)
            )
        # Required source URL = official origin release/download locator
        src = t.get("source_url")
        if src in (None, ""):
            pass  # already reported as missing required field
        elif str(src) != prof["source_url"]:
            errors.append(
                "%s (%s) source_url must be canonical supported origin URL "
                "for pin %r (got %r)"
                % (where, tid, prof["version"], src)
            )
        # Required source metadata URL = official origin tag/registry meta
        meta_u = t.get("source_meta_url")
        if meta_u in (None, ""):
            pass
        elif str(meta_u) != prof["source_meta_url"]:
            errors.append(
                "%s (%s) source_meta_url must be canonical supported origin "
                "metadata URL for pin %r (got %r)"
                % (where, tid, prof["version"], meta_u)
            )
        # Platform when the supported artifact is platform-specific
        if "platform" in prof:
            plat_v = t.get("platform")
            if plat_v in (None, ""):
                errors.append(
                    "%s (%s) missing required platform %r"
                    % (where, tid, prof["platform"])
                )
            elif str(plat_v) != prof["platform"]:
                errors.append(
                    "%s (%s) platform must be %r (got %r)"
                    % (where, tid, prof["platform"], plat_v)
                )
        else:
            if t.get("platform") not in (None, ""):
                errors.append(
                    "%s (%s) unexpected platform field (registry-distributed tool)"
                    % (where, tid)
                )
        # Package pin when the tool is registry-distributed
        if "package" in prof:
            pkg_v = t.get("package")
            if pkg_v in (None, ""):
                errors.append(
                    "%s (%s) missing required package %r"
                    % (where, tid, prof["package"])
                )
            elif str(pkg_v) != prof["package"]:
                errors.append(
                    "%s (%s) package must be canonical %r (got %r)"
                    % (where, tid, prof["package"], pkg_v)
                )
        else:
            if t.get("package") not in (None, ""):
                errors.append(
                    "%s (%s) unexpected package field (binary-release tool)"
                    % (where, tid)
                )
        if "distribution" in prof:
            dist_v = t.get("distribution")
            if dist_v in (None, ""):
                errors.append(
                    "%s (%s) missing required distribution %r"
                    % (where, tid, prof["distribution"])
                )
            elif str(dist_v) != prof["distribution"]:
                errors.append(
                    "%s (%s) distribution must be %r (got %r)"
                    % (where, tid, prof["distribution"], dist_v)
                )
        else:
            if t.get("distribution") not in (None, ""):
                errors.append(
                    "%s (%s) unexpected distribution field" % (where, tid)
                )
        # Optional source/asset aliases — exact equality only, never substring
        for alias in ("artifact", "filename", "tarball"):
            if t.get(alias) not in (None, ""):
                if str(t[alias]) != prof["asset"]:
                    errors.append(
                        "%s (%s) %s must equal canonical asset %r (got %r)"
                        % (where, tid, alias, prof["asset"], t[alias])
                    )
        for alias in ("source", "download_url", "url"):
            if t.get(alias) not in (None, ""):
                if str(t[alias]) != prof["source_url"]:
                    errors.append(
                        "%s (%s) %s must equal canonical source_url for "
                        "supported origin (got %r)"
                        % (where, tid, alias, t[alias])
                    )
        if t.get("integrity") not in (None, ""):
            if str(t["integrity"]) != prof["digest_value"]:
                errors.append(
                    "%s (%s) integrity must equal exact shipped digest.value"
                    % (where, tid)
                )

# Exact tool id set: no extras, no omissions, no duplicates (dupes checked above).
missing = required_ids - found
for m in sorted(missing):
    errors.append("required tool id missing: %s" % m)
extra_ids = found - required_ids
for e in sorted(extra_ids):
    errors.append(
        "unsupported extra tool id: %s (exact set is %s)"
        % (e, ",".join(sorted(required_ids)))
    )
if isinstance(tools, list) and tools and found == required_ids and len(ids) != len(required_ids):
    # Duplicate within required set already reported; count mismatch is extra signal
    pass

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

def package_embeds_exact_version(pkg):
    """True when package string embeds name + exact MAJOR.MINOR.PATCH."""
    return split_package_pin(pkg) is not None

def is_package_at_identity(s):
    """name@exact-semver package identity (not bare v1.2.3; not name==ver)."""
    if not isinstance(s, str) or "==" in s:
        return False
    return split_package_pin(s) is not None

def split_package_pin(s):
    """Parse name + exact version from package/identity pin. Returns (name, ver) or None."""
    if not isinstance(s, str) or s != s.strip() or any(ch.isspace() for ch in s):
        return None
    if s.startswith("@"):
        # scoped: @scope/name@version (not ==)
        if s.count("@") < 2:
            return None
        name, ver = s.rsplit("@", 1)
        if name and is_exact_numeric_semver(ver):
            return (name, ver)
        return None
    if "==" in s:
        name, ver = s.split("==", 1)
        if name and is_exact_numeric_semver(ver):
            return (name, ver)
        return None
    if "@" in s:
        name, ver = s.rsplit("@", 1)
        if name and is_exact_numeric_semver(ver):
            return (name, ver)
        return None
    return None

def normalize_repo_path(s):
    """Strict normalization for container registry/repository identity comparison."""
    if not isinstance(s, str):
        s = str(s)
    s = s.strip()
    for prefix in ("docker://", "oci://", "https://", "http://"):
        if s.lower().startswith(prefix):
            s = s[len(prefix):]
            break
    # drop trailing slashes only
    while s.endswith("/"):
        s = s[:-1]
    return s

def parse_image_locator(val):
    """Return (normalized_repo, dig_hex, raw) from registry/repo@sha256:hex, else None."""
    if not isinstance(val, str) or not IMAGE_DIGEST.fullmatch(val):
        return None
    repo, dig = val.rsplit("@sha256:", 1)
    return (normalize_repo_path(repo), dig, val)

def parse_image_digest_hex(val):
    """Return 64-hex digest from registry/repo@sha256:hex, else None."""
    parsed = parse_image_locator(val)
    return None if parsed is None else parsed[1]

# Closed key set for every container entry shape. One supported closed shape
# (image@sha256 or artifact@sha256) plus documented equal-only aliases only.
# Unknown keys always fail — even when another valid locator is present.
CONTAINER_ALLOWED_KEYS = {
    "id", "name",
    "image", "artifact",          # primary immutable locators (exactly one)
    "digest",                     # equal companion digest object/string
    "repository", "repo",         # equal-only repository path aliases
    "identity", "ref",            # equal-only identity/locator aliases
    "tag", "version",             # never sufficient alone; floating rejected
}

def check_container_entry(c, where):
    """Every container needs exactly one immutable image/artifact locator:
    registry/repository identity + @sha256:<64hex>. A free-standing digest
    (no repository identity) is not a locator. Tags/semver tags are not enough.

    Closed-world: only CONTAINER_ALLOWED_KEYS. Unknown keys fail even if a
    valid image/artifact locator is also present (no evil_locator adjacency).

    Cross-field consistency: any redundant repository/name/identity/digest/image/
    artifact claim must be absent or exactly agree with the single canonical
    locator after strict normalization. Contradiction is always a failure."""
    if not isinstance(c, dict):
        errors.append("%s not object" % where)
        return

    for k in c.keys():
        if k not in CONTAINER_ALLOWED_KEYS:
            errors.append(
                "%s unknown/extra container key: %s "
                "(closed schema; unknown keys fail even with a valid locator)"
                % (where, k)
            )

    # Collect documented locator fields (image / artifact only — unknown keys do not pin).
    locators = []  # (field, full_value, repo_norm, digest_hex)
    for field in ("image", "artifact"):
        if field not in c or c[field] in (None, ""):
            continue
        val = str(c[field])
        parsed = parse_image_locator(val)
        if parsed is None:
            errors.append(
                "%s.%s must be immutable registry/repo@sha256:<64hex> "
                "(tag-only/semver-tag/digest-only not enough): %r"
                % (where, field, val)
            )
        else:
            repo_norm, dig_hex, _raw = parsed
            locators.append((field, val, repo_norm, dig_hex))

    # Optional companion digest object/string — must not replace repository identity.
    dig = c.get("digest")
    dig_value = None
    if dig is not None:
        if isinstance(dig, dict):
            validate_digest_obj(dig, where + ".digest", allowed=("sha256",))
            if (
                str(dig.get("algorithm")) == "sha256"
                and isinstance(dig.get("value"), str)
                and HEX64.fullmatch(str(dig.get("value")))
            ):
                dig_value = str(dig.get("value"))
        elif isinstance(dig, str):
            if re.fullmatch(r"sha256:[0-9a-f]{64}", dig):
                dig_value = dig[len("sha256:"):]
            elif HEX64.fullmatch(dig):
                dig_value = dig
            else:
                errors.append("%s.digest string must be sha256:<64hex>, got %r" % (where, dig))
        else:
            errors.append("%s.digest bad shape" % where)

    canon_repo = None
    canon_dig = None
    if len(locators) > 1:
        digs = set(d for _, _, _, d in locators)
        repos = set(r for _, _, r, _ in locators)
        if len(digs) > 1 or len(repos) > 1:
            errors.append(
                "%s multiple conflicting image/artifact locators" % where
            )
        else:
            errors.append(
                "%s multiple image/artifact locators; require exactly one" % where
            )
        # still bind first for further checks
        canon_repo, canon_dig = locators[0][2], locators[0][3]
    elif len(locators) == 1:
        canon_repo, canon_dig = locators[0][2], locators[0][3]
        if dig_value is not None and dig_value != canon_dig:
            errors.append(
                "%s conflicting digest vs image/artifact locator "
                "(digest %s != locator %s)" % (where, dig_value, canon_dig)
            )
    else:
        # No full image/artifact@sha256 locator.
        if dig_value is not None:
            errors.append(
                "%s free-standing digest is not an immutable image locator "
                "(need registry/repo@sha256:<64hex>; digest-only rejected)" % where
            )
        elif c.get("image") not in (None, "") or c.get("artifact") not in (None, ""):
            # malformed image/artifact already reported above
            pass
        elif c.get("tag") is not None or c.get("version") is not None:
            errors.append(
                "%s tag/version without immutable image locator: tag=%r version=%r"
                % (where, c.get("tag"), c.get("version"))
            )
        else:
            # id/name-only, empty, or unknown-key-only shapes
            errors.append(
                "%s missing immutable image locator "
                "(registry/repo@sha256:<64hex>; id/name/tag/digest-only not enough)" % where
            )

    # Floating side tags/versions never substitute for the locator.
    for field in ("tag", "version"):
        if field in c and c[field] not in (None, ""):
            val = str(c[field])
            if FLOAT_WORD.fullmatch(val) or NONEXACT.search(val):
                errors.append("floating pin in %s.%s: %r" % (where, field, val))
            elif not is_exact_numeric_semver(val) and len(locators) == 0:
                errors.append("%s.%s is not immutable digest pin: %r" % (where, field, val))
            elif is_exact_numeric_semver(val) and len(locators) == 0:
                # exact-looking semver tag alone is not immutable
                errors.append(
                    "%s.%s exact-looking semver tag is not an immutable image locator: %r"
                    % (where, field, val)
                )

    # Redundant repository/repo/identity must agree with canonical locator.
    # Without a locator these fields cannot form an immutable pin alone.
    for field in ("repository", "repo"):
        if field not in c or c[field] in (None, ""):
            continue
        val = str(c[field])
        val_norm = normalize_repo_path(val)
        if canon_repo is None:
            errors.append(
                "%s.%s without @sha256 image/artifact locator is not immutable: %r"
                % (where, field, val)
            )
        elif val_norm != canon_repo:
            errors.append(
                "%s conflicting repository vs image/artifact locator "
                "(%s=%r != locator repo %r)" % (where, field, val, canon_repo)
            )

    if "identity" in c and c["identity"] not in (None, ""):
        val = str(c["identity"])
        if canon_repo is None:
            if not (
                IMAGE_DIGEST.fullmatch(val)
                or is_ok_identity(val)
                or re.fullmatch(r"sha256:[0-9a-f]{64}", val)
            ):
                errors.append("floating/non-exact pin in %s.identity: %r" % (where, val))
            elif not IMAGE_DIGEST.fullmatch(val):
                errors.append(
                    "%s.identity without @sha256 image/artifact locator is not immutable: %r"
                    % (where, val)
                )
        else:
            id_loc = parse_image_locator(val)
            if id_loc is not None:
                id_repo, id_dig, _ = id_loc
                if id_repo != canon_repo or id_dig != canon_dig:
                    errors.append(
                        "%s conflicting identity vs image/artifact locator "
                        "(identity %r != locator)" % (where, val)
                    )
            elif normalize_repo_path(val) == canon_repo:
                pass  # redundant-equal repository identity
            elif re.fullmatch(r"sha256:[0-9a-f]{64}", val):
                if val[len("sha256:"):] != canon_dig:
                    errors.append(
                        "%s conflicting identity digest vs locator: %r" % (where, val)
                    )
            elif HEX64.fullmatch(val):
                if val != canon_dig:
                    errors.append(
                        "%s conflicting identity digest vs locator: %r" % (where, val)
                    )
            else:
                errors.append(
                    "%s conflicting/alternate identity vs image/artifact locator: %r"
                    % (where, val)
                )

    if "ref" in c and c["ref"] not in (None, ""):
        val = str(c["ref"])
        # Container refs are not git commits. Any supplied ref that denotes a
        # repository+digest or digest-only alias must normalize and exactly
        # agree with the canonical image/artifact locator when one is present.
        # Syntactically valid IMAGE_DIGEST / sha256 forms alone are not enough.
        if val.startswith("refs/"):
            errors.append(
                "%s.ref must be full 40-char commit SHA or agree with image locator, got %r"
                % (where, val)
            )
        elif HEX40.fullmatch(val):
            # bare 40-hex on a container is an alternate pin form — reject with locator
            if canon_repo is not None:
                errors.append(
                    "%s.ref alternate commit identity conflicts with image/artifact locator: %r"
                    % (where, val)
                )
        elif canon_repo is None:
            # No canonical locator yet: accept only forms that could still be
            # identity-like; free-standing digests/refs still fail the locator
            # gate above. Reject floating/mutable tags.
            if not (
                IMAGE_DIGEST.fullmatch(val)
                or re.fullmatch(r"sha256:[0-9a-f]{64}", val)
                or HEX64.fullmatch(val)
            ):
                errors.append(
                    "%s.ref must be full 40-char commit SHA or agree with image locator, got %r"
                    % (where, val)
                )
        else:
            ref_loc = parse_image_locator(val)
            if ref_loc is not None:
                ref_repo, ref_dig, _ = ref_loc
                if ref_repo != canon_repo or ref_dig != canon_dig:
                    errors.append(
                        "%s conflicting ref vs image/artifact locator "
                        "(ref %r != locator)" % (where, val)
                    )
            elif normalize_repo_path(val) == canon_repo:
                pass  # redundant-equal repository path
            elif re.fullmatch(r"sha256:[0-9a-f]{64}", val):
                if val[len("sha256:"):] != canon_dig:
                    errors.append(
                        "%s conflicting ref digest vs locator: %r" % (where, val)
                    )
            elif HEX64.fullmatch(val):
                if val != canon_dig:
                    errors.append(
                        "%s conflicting ref digest vs locator: %r" % (where, val)
                    )
            else:
                errors.append(
                    "%s.ref must be full 40-char commit SHA or agree with image locator, got %r"
                    % (where, val)
                )

# Closed key set for every MCP entry shape. Exactly one of package / git /
# artifact completed shapes, plus documented equal-only aliases within that
# shape. Unknown keys always fail even with another valid locator present.
MCP_ALLOWED_KEYS = {
    "id", "name",
    # package shape
    "package", "version", "identity",
    # git/source shape
    "source", "repository", "repo", "url", "git", "source_url",
    "ref", "commit", "revision", "sha",
    # artifact shape
    "artifact", "asset", "artifact_url", "tarball",
    "digest",
    # mutable side fields (always rejected when present, but known keys)
    "tag", "branch",
}

def check_mcp_entry(c, where):
    """Every MCP entry needs exactly one immutable executable/source locator:
      (1) exact package identity + exact canonical version
      (2) exact git/source identity + full 40-hex commit
      (3) artifact identity + sha256 digest
    Id/name-only, empty, incomplete, cross-wired, or unknown-key pins fail closed.

    Closed-world: only MCP_ALLOWED_KEYS. Unknown keys fail even if a valid
    package/git/artifact locator is also present (no evil_locator adjacency).

    Cross-field consistency: parse one canonical identity + immutable pin per
    shape. Any redundant name/package/version/identity/source/ref/artifact/digest
    must be absent or exactly agree after strict normalization. Contradiction,
    ambiguous multiple identities, and cross-shape field mixtures always fail."""
    if not isinstance(c, dict):
        errors.append("%s not object" % where)
        return

    for k in c.keys():
        if k not in MCP_ALLOWED_KEYS:
            errors.append(
                "%s unknown/extra MCP key: %s "
                "(closed schema; unknown keys fail even with a valid locator)"
                % (where, k)
            )

    shapes = []  # completed locator shape names

    # --- shape 1: package identity + exact version ---
    package = c.get("package")
    version = c.get("version")
    identity = c.get("identity")
    name = c.get("name")
    has_package = package not in (None, "")
    has_version = version not in (None, "")
    has_identity = identity not in (None, "")
    has_name = name not in (None, "")

    # Collect every (name, version) claim from package / identity / name+version.
    # All claims must agree; one agreed pair is the canonical package pin.
    pkg_claims = []  # (source_field, name, version)

    if has_package:
        pkg = str(package)
        parsed = split_package_pin(pkg)
        if parsed is None:
            errors.append("%s.package missing exact version: %r" % (where, pkg))
        else:
            pkg_claims.append(("package", parsed[0], parsed[1]))

    if has_version:
        reject_nonexact_semver(str(version), where + ".version")

    if has_identity:
        idv = str(identity)
        parsed = split_package_pin(idv)
        if parsed is not None and "==" not in idv:
            pkg_claims.append(("identity", parsed[0], parsed[1]))
        elif is_exact_numeric_semver(idv) or re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", idv):
            # version-only identity is a version claim, not a full package pin alone
            ver_only = (
                idv[1:]
                if idv.startswith("v") and is_exact_numeric_semver(idv[1:])
                else idv
            )
            if is_exact_numeric_semver(ver_only):
                if has_version and is_exact_numeric_semver(str(version)) and str(version) != ver_only:
                    errors.append(
                        "%s conflicting identity version vs version field "
                        "(identity %r != version %r)" % (where, idv, version)
                    )
            # else non-exact — reject_identity below after shape resolution
        # else: non-package identity (artifact name, source URL, etc.) deferred
        # to shape-specific cross-field checks so equal artifact/git aliases stay green.

    # name + exact version is a package locator claim
    if has_name and has_version and is_exact_numeric_semver(str(version)):
        n = str(name).strip()
        if n and not FLOAT_WORD.fullmatch(n):
            pkg_claims.append(("name+version", n, str(version)))

    # version present without any package identity field
    if has_version and not (has_package or has_identity or has_name):
        errors.append(
            "%s version without package identity is not an immutable MCP locator"
            % where
        )

    # Cross-check all package claims for exact agreement
    canon_pkg_name = None
    canon_pkg_ver = None
    pkg_complete = False
    if pkg_claims:
        names = set(n for _, n, _ in pkg_claims)
        vers = set(v for _, _, v in pkg_claims)
        if len(names) > 1 or len(vers) > 1:
            errors.append(
                "%s conflicting package identity claims: %s"
                % (
                    where,
                    "; ".join("%s=%s@%s" % (src, n, v) for src, n, v in pkg_claims),
                )
            )
        else:
            canon_pkg_name = next(iter(names))
            canon_pkg_ver = next(iter(vers))
            pkg_complete = True
            # Redundant split version must match embedded package version
            if has_version and is_exact_numeric_semver(str(version)):
                if str(version) != canon_pkg_ver:
                    errors.append(
                        "%s conflicting version vs package pin "
                        "(version %r != package version %r)"
                        % (where, version, canon_pkg_ver)
                    )
                    pkg_complete = False
            # Redundant name must match package name (id is separate entry key)
            if has_name:
                if str(name).strip() != canon_pkg_name:
                    # only when name was not the sole claim source, or always?
                    # Always require name agree with package identity when both present.
                    if has_package or (has_identity and split_package_pin(str(identity)) is not None):
                        errors.append(
                            "%s conflicting name vs package pin "
                            "(name %r != package name %r)"
                            % (where, name, canon_pkg_name)
                        )
                        pkg_complete = False

    if pkg_complete:
        shapes.append("package")

    # --- shape 2: git/source identity + full 40-hex commit ---
    SOURCE_KEYS = ("source", "repository", "repo", "url", "git", "source_url")
    COMMIT_KEYS = ("ref", "commit", "revision", "sha")
    source_vals = []  # (key, normalized_value)
    for sk in SOURCE_KEYS:
        if sk in c and c[sk] not in (None, ""):
            source_vals.append((sk, str(c[sk]).strip()))
    source_val = None
    source_key = None
    if len(source_vals) > 1:
        norms = set(normalize_repo_path(v) for _, v in source_vals)
        if len(norms) > 1:
            errors.append(
                "%s conflicting source identity fields: %s"
                % (where, ",".join("%s=%r" % (k, v) for k, v in source_vals))
            )
        else:
            # equal aliases: fail closed (ambiguous multiple canonical keys)
            errors.append(
                "%s multiple source identity aliases (use exactly one): %s"
                % (where, ",".join(k for k, _ in source_vals))
            )
        source_key, source_val = source_vals[0]
    elif len(source_vals) == 1:
        source_key, source_val = source_vals[0]

    commit_vals = []  # (key, value)
    for ck in COMMIT_KEYS:
        if ck in c and c[ck] not in (None, ""):
            commit_vals.append((ck, str(c[ck])))
    commit_val = None
    commit_key = None
    commit_hex_ok = False
    if len(commit_vals) > 1:
        hexes = set(v for _, v in commit_vals)
        if len(hexes) > 1:
            errors.append(
                "%s conflicting commit/ref fields: %s"
                % (where, ",".join("%s=%r" % (k, v) for k, v in commit_vals))
            )
        else:
            errors.append(
                "%s multiple commit/ref aliases (use exactly one): %s"
                % (where, ",".join(k for k, _ in commit_vals))
            )
        commit_key, commit_val = commit_vals[0]
        commit_hex_ok = bool(HEX40.fullmatch(commit_val))
        if not commit_hex_ok:
            errors.append(
                "%s.%s must be exact immutable full commit SHA (40 hex), got %r"
                % (where, commit_key, commit_val)
            )
    elif len(commit_vals) == 1:
        commit_key, commit_val = commit_vals[0]
        if HEX40.fullmatch(commit_val):
            commit_hex_ok = True
        else:
            errors.append(
                "%s.%s must be exact immutable full commit SHA (40 hex), got %r"
                % (where, commit_key, commit_val)
            )

    if source_val is not None and commit_hex_ok:
        if (
            FLOAT_WORD.fullmatch(source_val)
            or source_val.startswith("refs/")
            or NONEXACT.search(source_val)
        ):
            errors.append(
                "%s.%s is not a fixed git/source identity: %r"
                % (where, source_key, source_val)
            )
        else:
            shapes.append("git")
    elif commit_val is not None and source_val is None:
        errors.append(
            "%s %s without source identity is not an immutable MCP locator"
            % (where, commit_key or "ref")
        )
    elif source_val is not None and commit_val is None:
        errors.append(
            "%s source without full commit SHA is not an immutable MCP locator"
            % where
        )

    # --- shape 3: artifact identity + digest ---
    ARTIFACT_KEYS = ("artifact", "asset", "artifact_url", "tarball")
    art_vals = []
    for ak in ARTIFACT_KEYS:
        if ak in c and c[ak] not in (None, ""):
            art_vals.append((ak, str(c[ak]).strip()))
    art_val = None
    art_key = None
    if len(art_vals) > 1:
        norms = set(v for _, v in art_vals)
        if len(norms) > 1:
            errors.append(
                "%s conflicting artifact identity fields: %s"
                % (where, ",".join("%s=%r" % (k, v) for k, v in art_vals))
            )
        else:
            errors.append(
                "%s multiple artifact identity aliases (use exactly one): %s"
                % (where, ",".join(k for k, _ in art_vals))
            )
        art_key, art_val = art_vals[0]
    elif len(art_vals) == 1:
        art_key, art_val = art_vals[0]

    dig = c.get("digest")
    dig_ok = False
    dig_canon = None  # normalized digest string for comparison
    if dig is not None:
        if isinstance(dig, dict):
            before = len(errors)
            validate_digest_obj(dig, where + ".digest", allowed=("sha256", "sha512-integrity"))
            dig_ok = len(errors) == before
            if dig_ok:
                algo = str(dig.get("algorithm"))
                val = str(dig.get("value"))
                if algo == "sha256":
                    dig_canon = "sha256:" + val
                else:
                    dig_canon = val
        elif isinstance(dig, str):
            if dig.startswith("sha512-"):
                dig_ok = validate_npm_integrity(dig, where + ".digest")
                if dig_ok:
                    dig_canon = dig
            elif dig.startswith("sha256:"):
                dig_ok = validate_sha256_value(dig[7:], where + ".digest")
                if dig_ok:
                    dig_canon = dig
            elif HEX64.fullmatch(dig):
                dig_ok = True
                dig_canon = "sha256:" + dig
            else:
                errors.append("%s.digest malformed: %r" % (where, dig))
                dig_ok = False
        else:
            errors.append("%s.digest bad shape" % where)

    if art_val is not None and dig_ok:
        shapes.append("artifact")
    elif dig is not None and art_val is None:
        errors.append(
            "%s digest without artifact identity is not an immutable MCP locator"
            % where
        )
    elif art_val is not None and not dig_ok:
        errors.append(
            "%s artifact without digest is not an immutable MCP locator"
            % where
        )

    # Mutable git tags/branches never count as a locator.
    for field in ("tag", "branch"):
        if field in c and c[field] not in (None, ""):
            errors.append(
                "%s.%s is mutable; require full commit SHA or exact package pin instead: %r"
                % (where, field, c[field])
            )

    # Exactly one completed shape. Unknown keys cannot form a locator.
    if len(shapes) == 0:
        errors.append(
            "%s missing immutable MCP locator "
            "(need package@version, source+40-hex commit, or artifact+digest; "
            "id/name-only rejected)" % where
        )
    elif len(shapes) > 1:
        errors.append(
            "%s multiple conflicting locator shapes: %s" % (where, ",".join(shapes))
        )
    else:
        # Cross-shape field mixtures: fields belonging to other shapes must be absent.
        shape = shapes[0]
        if shape == "package":
            if source_val is not None or commit_val is not None:
                errors.append(
                    "%s package locator mixed with git/source fields (cross-shape)"
                    % where
                )
            if art_val is not None or dig is not None:
                errors.append(
                    "%s package locator mixed with artifact/digest fields (cross-shape)"
                    % where
                )
            # identity must be package-at matching canon, or version-only matching canon
            if has_identity and canon_pkg_name is not None:
                idv = str(identity)
                parsed = split_package_pin(idv)
                if parsed is not None and "==" not in idv:
                    if parsed[0] != canon_pkg_name or parsed[1] != canon_pkg_ver:
                        errors.append(
                            "%s conflicting identity vs package pin: %r" % (where, idv)
                        )
                else:
                    ver_only = (
                        idv[1:]
                        if idv.startswith("v") and is_exact_numeric_semver(idv[1:])
                        else idv
                    )
                    if is_exact_numeric_semver(ver_only):
                        if ver_only != canon_pkg_ver:
                            errors.append(
                                "%s conflicting identity version vs package pin: %r"
                                % (where, idv)
                            )
                    else:
                        errors.append(
                            "%s non-agreeing identity vs package pin: %r" % (where, idv)
                        )
        elif shape == "git":
            # package/version/identity package-claims are already multi-shape if complete.
            # Incomplete package fields mixed into git still fail closed.
            if has_package or (
                has_identity and split_package_pin(str(identity)) is not None
            ):
                errors.append(
                    "%s git locator mixed with package identity fields (cross-shape)"
                    % where
                )
            if art_val is not None or dig is not None:
                errors.append(
                    "%s git locator mixed with artifact/digest fields (cross-shape)"
                    % where
                )
            # Redundant identity (non-package) on git must agree with source or commit
            if has_identity and split_package_pin(str(identity)) is None:
                idv = str(identity)
                if (
                    normalize_repo_path(idv) == normalize_repo_path(source_val)
                    or idv == commit_val
                ):
                    pass  # redundant-equal
                elif is_exact_numeric_semver(idv) or re.fullmatch(
                    r"v[0-9]+\.[0-9]+\.[0-9]+", idv
                ):
                    errors.append(
                        "%s git locator mixed with package-version identity (cross-shape): %r"
                        % (where, idv)
                    )
                else:
                    errors.append(
                        "%s conflicting identity vs git source: %r" % (where, idv)
                    )
        elif shape == "artifact":
            if source_val is not None or commit_val is not None:
                errors.append(
                    "%s artifact locator mixed with git/source fields (cross-shape)"
                    % where
                )
            if has_package or (
                has_identity and split_package_pin(str(identity)) is not None
            ):
                errors.append(
                    "%s artifact locator mixed with package identity fields (cross-shape)"
                    % where
                )
            # identity agreeing with artifact name or digest is ok; contradiction fails
            if has_identity and split_package_pin(str(identity)) is None:
                idv = str(identity)
                if idv == art_val:
                    pass
                elif dig_canon and (
                    idv == dig_canon
                    or idv == dig_canon.replace("sha256:", "")
                    or (idv.startswith("sha256:") and idv == dig_canon)
                ):
                    pass
                elif is_exact_numeric_semver(idv) or re.fullmatch(
                    r"v[0-9]+\.[0-9]+\.[0-9]+", idv
                ):
                    errors.append(
                        "%s artifact locator mixed with package-version identity (cross-shape): %r"
                        % (where, idv)
                    )
                else:
                    errors.append(
                        "%s conflicting identity vs artifact: %r" % (where, idv)
                    )

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

# ---------------------------------------------------------------------------
# bundled_extensions — required closed-world exact shipped structure.
# Exact type/cardinality/entry key sets; order-insensitive content match to
# the shipped developer builtin; cross-bind bundled_with to locked Goose
# identity/version and to the recipe developer extension contract
# (type=builtin, name=developer). No omissions/extras/unknown keys/duplicates.
# ---------------------------------------------------------------------------
BUNDLED_EXT_ALLOWED_KEYS = {"id", "name", "type", "bundled_with", "notes"}
# Exact shipped entry fields (notes required non-empty; content may vary in
# prose but key must be present). Identity fields are exact.
BUNDLED_EXT_CANON = {
    "id": "developer",
    "name": "developer",
    "type": "builtin",
}
# goose-cli pin used for bundled_with cross-bind (from CORE_TOOL_PROFILES).
_goose_prof = CORE_TOOL_PROFILES.get("goose-cli") or {}
_goose_ver = str(_goose_prof.get("version") or "1.45.0")
BUNDLED_WITH_CANON = "goose-cli@%s" % _goose_ver

if "bundled_extensions" not in data:
    errors.append(
        "lock missing required field: bundled_extensions "
        "(exact shipped developer builtin contract)"
    )
else:
    bexts = data.get("bundled_extensions")
    if not isinstance(bexts, list):
        errors.append("bundled_extensions must be a list")
    else:
        # Exact cardinality of the shipped lock (one developer builtin).
        if len(bexts) != 1:
            errors.append(
                "bundled_extensions must contain exactly 1 entry "
                "(shipped developer builtin; got %d; no extras/omissions)"
                % len(bexts)
            )
        seen_bext_ids = set()
        for j, be in enumerate(bexts):
            where_b = "bundled_extensions[%d]" % j
            if not isinstance(be, dict):
                errors.append("%s not object" % where_b)
                continue
            for k in be.keys():
                if k not in BUNDLED_EXT_ALLOWED_KEYS:
                    errors.append(
                        "%s unknown/extra key: %s "
                        "(closed bundled_extensions schema)" % (where_b, k)
                    )
            for rk in BUNDLED_EXT_ALLOWED_KEYS:
                if rk not in be or be.get(rk) in (None, ""):
                    errors.append(
                        "%s missing required field %s" % (where_b, rk)
                    )
            bid = be.get("id")
            if bid not in (None, ""):
                if bid in seen_bext_ids:
                    errors.append(
                        "duplicate bundled_extensions id: %s" % bid
                    )
                seen_bext_ids.add(bid)
            # Exact identity fields for the shipped developer contract
            for field, expected in BUNDLED_EXT_CANON.items():
                val = be.get(field)
                if val not in (None, "") and str(val) != expected:
                    errors.append(
                        "%s.%s must be exact shipped %r (got %r; "
                        "recipe developer extension contract)"
                        % (where_b, field, expected, val)
                    )
            # Cross-bind bundled_with to exact locked Goose CLI pin
            bw = be.get("bundled_with")
            if bw not in (None, ""):
                if str(bw) != BUNDLED_WITH_CANON:
                    errors.append(
                        "%s.bundled_with must equal exact locked Goose "
                        "identity %r (got %r; cross-bound to goose-cli "
                        "version %r)"
                        % (where_b, BUNDLED_WITH_CANON, bw, _goose_ver)
                    )
                # Also require goose-cli tool pin agrees when present
                if goose is not None:
                    gver = str(goose.get("version") or "")
                    if gver and gver != _goose_ver:
                        errors.append(
                            "%s.bundled_with cross-bind: goose-cli version "
                            "%r disagrees with profile pin %r"
                            % (where_b, gver, _goose_ver)
                        )
                    expected_bw = "goose-cli@%s" % gver if gver else BUNDLED_WITH_CANON
                    if str(bw) != expected_bw and str(bw) != BUNDLED_WITH_CANON:
                        errors.append(
                            "%s.bundled_with %r disagrees with goose-cli@%s"
                            % (where_b, bw, gver)
                        )
            # type must remain builtin (recipe developer extension contract)
            if be.get("type") not in (None, "") and str(be.get("type")) != "builtin":
                errors.append(
                    "%s.type must be 'builtin' (recipe developer extension)"
                    % where_b
                )
            if be.get("name") not in (None, "") and str(be.get("name")) != "developer":
                # already covered by CANON exact match; keep explicit signal
                pass
        # Order-insensitive content: required id set must be exactly {developer}
        if isinstance(bexts, list) and len(bexts) >= 1:
            expected_ids = {"developer"}
            if seen_bext_ids and seen_bext_ids != expected_ids:
                # only report when cardinality matched enough to inspect ids
                missing_b = expected_ids - seen_bext_ids
                extra_b = seen_bext_ids - expected_ids
                for m in sorted(missing_b):
                    errors.append(
                        "bundled_extensions missing required id: %s" % m
                    )
                for e in sorted(extra_b):
                    errors.append(
                        "bundled_extensions unsupported extra id: %s "
                        "(exact set is developer)" % e
                    )

# digest_instructions closed schema + exact commands already validated above
# (macOS + portable + commit_policy). Keep a minimal presence cross-check so
# older fixtures still report macOS/portable when DI is wholly absent.
di = data.get("digest_instructions") or {}
if not isinstance(di, dict):
    pass  # already reported
else:
    if "macOS" not in di:
        errors.append("digest_instructions.macOS missing")
    if "portable" not in di:
        errors.append("digest_instructions.portable missing")

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
            # containers/mcp handlers own entry-level version cross-field rules
            if ".containers[" in path or ".mcp_packages[" in path:
                if FLOAT_WORD.fullmatch(obj.strip()) or NONEXACT.search(obj):
                    errors.append("floating pin in %s: %r" % (path, obj))
            else:
                reject_nonexact_semver(obj, path)
        elif path.endswith(".identity"):
            # tools[] use package-style identity; containers/mcp allow locator-equal
            # aliases (image@sha256, artifact names, source URLs) validated in handlers.
            if ".containers[" in path or ".mcp_packages[" in path:
                if FLOAT_WORD.fullmatch(obj.strip()) or obj.startswith("refs/heads/"):
                    errors.append("floating pin in %s: %r" % (path, obj))
            else:
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
if [[ -f "$REVIEWER_RECIPE" ]]; then
  ok "reviewer.yaml present"
else
  bad "reviewer.yaml missing"
fi
if [[ -f "$SECURITY_RECIPE" ]]; then
  ok "security.yaml present"
else
  bad "security.yaml missing"
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

if [[ "${#RECIPE_FILES[@]}" -ge 4 ]]; then
  ok "discovered ${#RECIPE_FILES[@]} recipe yaml/yml files"
else
  bad "expected >=4 recipe files (builder/reviewer/security/red-team), found ${#RECIPE_FILES[@]}"
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
echo "core role playbook↔recipe drift (#34)"
# ---------------------------------------------------------------------------
sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    echo ""
  fi
}

for role in "${ROLE_RECIPES[@]}"; do
  recipe="$RECIPES_DIR/${role}.yaml"
  playbook="$REPO_ROOT/playbooks/${role}.md"
  if [[ ! -f "$recipe" ]]; then
    bad "role recipe missing: ${role}.yaml"
    continue
  fi
  if [[ ! -f "$playbook" ]]; then
    bad "role playbook missing: playbooks/${role}.md"
    continue
  fi
  # Recipe must name the prose source (reference, not fork)
  if grep -qF "playbooks/${role}.md" "$recipe"; then
    ok "${role}.yaml references playbooks/${role}.md"
  else
    bad "${role}.yaml does not reference playbooks/${role}.md"
  fi
  # Instructions must use replacement-not-additive local playbook rule
  if grep -qE "local/playbooks/${role}\\.md" "$recipe"; then
    ok "${role}.yaml mounts local playbook replacement rule"
  else
    bad "${role}.yaml missing local/playbooks/${role}.md replacement rule"
  fi
  # playbook-sha256 pin must match current playbook bytes
  pinned=$(awk '/^# playbook-sha256:/{print $3; exit}' "$recipe" || true)
  actual=$(sha256_file "$playbook")
  if [[ -z "$pinned" ]]; then
    bad "${role}.yaml missing # playbook-sha256: pin"
  elif [[ -z "$actual" ]]; then
    bad "cannot hash playbooks/${role}.md (need sha256sum or shasum)"
  elif [[ "$pinned" == "$actual" ]]; then
    ok "${role}.yaml playbook-sha256 matches playbooks/${role}.md"
  else
    bad "${role}.yaml playbook-sha256 drift (pin=${pinned:0:12}… actual=${actual:0:12}…) — recompute after playbook edit"
  fi
  # No @latest in role recipes (belt + suspenders; structural checker also enforces)
  if grep -nE '@latest|[[:space:]]latest[[:space:]]*$' "$recipe" | grep -vE '^\s*#' | grep -vqE 'do not|never|not |unpinned|comment'; then
    # Allow only comment mentions of latest
    if grep -nE '@latest' "$recipe" | grep -vE '#|do not|never|unpinned|Example'; then
      bad "${role}.yaml contains @latest pin"
    else
      ok "${role}.yaml has no executable @latest pin"
    fi
  else
    ok "${role}.yaml has no executable @latest pin"
  fi
done

# ---------------------------------------------------------------------------
echo "recipe-stamp audit helper (#34)"
# ---------------------------------------------------------------------------
STAMP="$REPO_ROOT/scripts/recipe-stamp.sh"
LEDGER="$REPO_ROOT/memory/recipe-runs.md"
if [[ -x "$STAMP" ]]; then
  ok "recipe-stamp.sh is executable"
else
  bad "recipe-stamp.sh missing or not executable"
fi
if [[ -f "$LEDGER" ]] && grep -qE '^\| UTC \|' "$LEDGER"; then
  ok "memory/recipe-runs.md ledger header present"
else
  bad "memory/recipe-runs.md missing table header"
fi
# Dry-run stamp into a temp copy of the ledger layout (do not pollute real ledger in CI)
stamp_root=$(mktemp -d "${TMPDIR:-/tmp}/gibson-recipe-stamp.XXXXXX")
mkdir -p "$stamp_root/memory" "$stamp_root/scripts" "$stamp_root/playbooks/recipes"
cp "$STAMP" "$stamp_root/scripts/recipe-stamp.sh"
chmod +x "$stamp_root/scripts/recipe-stamp.sh"
cp "$BUILDER_RECIPE" "$stamp_root/playbooks/recipes/builder.yaml"
# Point stamp at temp gibson root by invoking from a fake tree: rewrite GIBSON_ROOT via path
# recipe-stamp resolves GIBSON_ROOT from script location — so run the copy under stamp_root.
out=$("$stamp_root/scripts/recipe-stamp.sh" \
  --role builder \
  --recipe "$stamp_root/playbooks/recipes/builder.yaml" \
  --issue 34 \
  --repo "$stamp_root/fake-wt" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'builder' "$stamp_root/memory/recipe-runs.md" && grep -q '34' "$stamp_root/memory/recipe-runs.md"; then
  ok "recipe-stamp.sh appends audit row (role+issue)"
else
  bad "recipe-stamp.sh dry run failed (rc=$rc): $out"
fi
rm -rf "$stamp_root"

# Role recipes must instruct stamping
for role in "${ROLE_RECIPES[@]}"; do
  if grep -qF "recipe-stamp.sh" "$RECIPES_DIR/${role}.yaml"; then
    ok "${role}.yaml instructs recipe-stamp.sh"
  else
    bad "${role}.yaml missing recipe-stamp.sh instruction"
  fi
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

# Green: valid immutable container + MCP package pin still passes lock checker
lock_mutant "$ROOT/ok-lock-immutable.json" '
data["containers"] = [{
    "id": "tool-image",
    "image": "registry/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
data["mcp_packages"] = [{
    "id": "example-mcp",
    "name": "example-mcp",
    "package": "example-mcp@1.0.0",
    "version": "1.0.0",
    "identity": "example-mcp@1.0.0",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-immutable.json" 2>&1); rc=$?
expect_pass "green: lock with digest image + full commit MCP ref" "$out" "$rc"

# ---------------------------------------------------------------------------
echo "red fixtures: container/MCP identity locator fail-opens (P2 repair)"
# ---------------------------------------------------------------------------

# Independent mutant 1: free-standing digest without image/artifact identity
lock_mutant "$ROOT/bad-lock-container-digest-only.json" '
data["containers"] = [{
    "id": "probe",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-digest-only.json" 2>&1); rc=$?
expect_fail "red: container digest-only without image fails" "$out" "$rc" "digest-only\|free-standing\|image locator"

# Independent mutant 2: MCP id/name-only without immutable locator
lock_mutant "$ROOT/bad-lock-mcp-name-only.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "name": "probe",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-name-only.json" 2>&1); rc=$?
expect_fail "red: MCP id/name-only without locator fails" "$out" "$rc" "id/name-only\|missing immutable MCP locator"

# --- Container negatives: incomplete / cross-wired / unknown shapes ---
lock_mutant "$ROOT/bad-lock-container-id-only.json" '
data["containers"] = [{"id": "probe"}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-id-only.json" 2>&1); rc=$?
expect_fail "red: container id-only fails" "$out" "$rc" "missing immutable image locator"

lock_mutant "$ROOT/bad-lock-container-tag-only.json" '
data["containers"] = [{"id": "probe", "tag": "1.2.3", "version": "1.2.3"}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-tag-only.json" 2>&1); rc=$?
expect_fail "red: container tag/semver-only fails" "$out" "$rc" "immutable\|locator\|tag"

lock_mutant "$ROOT/bad-lock-container-split-no-repo.json" '
data["containers"] = [{
    "id": "probe",
    "tag": "1.2.3",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-split-no-repo.json" 2>&1); rc=$?
expect_fail "red: container split digest+tag without repository fails" "$out" "$rc" "free-standing\|digest-only\|image locator"

lock_mutant "$ROOT/bad-lock-container-repo-no-digest.json" '
data["containers"] = [{
    "id": "probe",
    "repository": "registry/tool",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-repo-no-digest.json" 2>&1); rc=$?
expect_fail "red: container repository+digest split without image@sha256 fails" "$out" "$rc" "free-standing\|digest-only\|image locator\|without @sha256"

lock_mutant "$ROOT/bad-lock-container-conflict.json" '
data["containers"] = [{
    "id": "probe",
    "image": "registry/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "digest": {
        "algorithm": "sha256",
        "value": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    },
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-conflict.json" 2>&1); rc=$?
expect_fail "red: container conflicting image vs digest fails" "$out" "$rc" "conflict"

lock_mutant "$ROOT/bad-lock-container-multi-locator.json" '
data["containers"] = [{
    "id": "probe",
    "image": "registry/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "artifact": "other/repo@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-multi-locator.json" 2>&1); rc=$?
expect_fail "red: container multiple conflicting locators fails" "$out" "$rc" "multiple\|conflict"

lock_mutant "$ROOT/bad-lock-container-unknown-key.json" '
data["containers"] = [{
    "id": "probe",
    "oci_ref": "registry/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-unknown-key.json" 2>&1); rc=$?
expect_fail "red: container unknown-key locator bypass fails" "$out" "$rc" "missing immutable image locator"

lock_mutant "$ROOT/bad-lock-container-no-slash.json" '
data["containers"] = [{
    "id": "probe",
    "image": "tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-no-slash.json" 2>&1); rc=$?
expect_fail "red: container image without registry/repo path fails" "$out" "$rc" "immutable\|registry/repo"

# --- MCP negatives: incomplete / cross-wired / unknown shapes ---
lock_mutant "$ROOT/bad-lock-mcp-version-only.json" '
data["mcp_packages"] = [{"id": "probe", "version": "1.2.3"}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-version-only.json" 2>&1); rc=$?
expect_fail "red: MCP version without package identity fails" "$out" "$rc" "version without package\|missing immutable MCP locator"

lock_mutant "$ROOT/bad-lock-mcp-ref-only.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "ref": "90c50d653d7fd978ec5d436b548eca8613dc2d26",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-ref-only.json" 2>&1); rc=$?
expect_fail "red: MCP ref without source fails" "$out" "$rc" "without source\|missing immutable MCP locator"

lock_mutant "$ROOT/bad-lock-mcp-source-only.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "source": "https://github.com/example/mcp.git",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-source-only.json" 2>&1); rc=$?
expect_fail "red: MCP source without commit fails" "$out" "$rc" "without full commit\|missing immutable MCP locator"

lock_mutant "$ROOT/bad-lock-mcp-digest-only.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-digest-only.json" 2>&1); rc=$?
expect_fail "red: MCP digest without artifact fails" "$out" "$rc" "digest without artifact\|missing immutable MCP locator"

lock_mutant "$ROOT/bad-lock-mcp-artifact-only.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "artifact": "example-mcp-1.0.0.tgz",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-artifact-only.json" 2>&1); rc=$?
expect_fail "red: MCP artifact without digest fails" "$out" "$rc" "artifact without digest\|missing immutable MCP locator"

lock_mutant "$ROOT/bad-lock-mcp-multi-shape.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "name": "probe",
    "package": "probe@1.0.0",
    "version": "1.0.0",
    "source": "https://github.com/example/mcp.git",
    "ref": "90c50d653d7fd978ec5d436b548eca8613dc2d26",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-multi-shape.json" 2>&1); rc=$?
expect_fail "red: MCP multiple conflicting locator shapes fails" "$out" "$rc" "multiple conflicting locator"

lock_mutant "$ROOT/bad-lock-mcp-unknown-key.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "pin": "probe@1.0.0",
    "locator": "https://github.com/example/mcp.git@90c50d653d7fd978ec5d436b548eca8613dc2d26",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-unknown-key.json" 2>&1); rc=$?
expect_fail "red: MCP unknown-key locator bypass fails" "$out" "$rc" "missing immutable MCP locator\|id/name-only"

lock_mutant "$ROOT/bad-lock-mcp-mutable-tag.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "name": "probe",
    "package": "probe@1.0.0",
    "version": "1.0.0",
    "tag": "v1.0.0",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-mutable-tag.json" 2>&1); rc=$?
expect_fail "red: MCP mutable tag field fails" "$out" "$rc" "mutable"

# --- Green: each supported locator shape ---
lock_mutant "$ROOT/ok-lock-container-image.json" '
data["containers"] = [{
    "id": "tool-image",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-image.json" 2>&1); rc=$?
expect_pass "green: container image@sha256 locator" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-container-artifact.json" '
data["containers"] = [{
    "id": "tool-image",
    "artifact": "registry/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-artifact.json" 2>&1); rc=$?
expect_pass "green: container artifact@sha256 locator" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-container-image-matching-digest.json" '
data["containers"] = [{
    "id": "tool-image",
    "image": "registry/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-image-matching-digest.json" 2>&1); rc=$?
expect_pass "green: container image@sha256 with matching digest object" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-mcp-package.json" '
data["mcp_packages"] = [{
    "id": "pkg-mcp",
    "name": "pkg-mcp",
    "package": "pkg-mcp@2.3.4",
    "version": "2.3.4",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-mcp-package.json" 2>&1); rc=$?
expect_pass "green: MCP package@version locator" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-mcp-package-eq.json" '
data["mcp_packages"] = [{
    "id": "pkg-mcp",
    "package": "pkg-mcp==2.3.4",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-mcp-package-eq.json" 2>&1); rc=$?
expect_pass "green: MCP package==version locator" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-mcp-git.json" '
data["mcp_packages"] = [{
    "id": "git-mcp",
    "source": "https://github.com/example/mcp.git",
    "ref": "90c50d653d7fd978ec5d436b548eca8613dc2d26",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-mcp-git.json" 2>&1); rc=$?
expect_pass "green: MCP source+full-commit locator" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-mcp-git-commit-key.json" '
data["mcp_packages"] = [{
    "id": "git-mcp",
    "repository": "github.com/example/mcp",
    "commit": "90c50d653d7fd978ec5d436b548eca8613dc2d26",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-mcp-git-commit-key.json" 2>&1); rc=$?
expect_pass "green: MCP repository+commit locator" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-mcp-artifact.json" '
data["mcp_packages"] = [{
    "id": "art-mcp",
    "artifact": "art-mcp-1.0.0.tgz",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/ok-lock-mcp-artifact.json" 2>&1); rc=$?
expect_pass "green: MCP artifact+sha256 locator" "$out" "$rc"

# Empty arrays remain valid (shipped lock shape)
lock_mutant "$ROOT/ok-lock-empty-arrays.json" '
data["containers"] = []
data["mcp_packages"] = []
'
out=$(check_lock_py "$ROOT/ok-lock-empty-arrays.json" 2>&1); rc=$?
expect_pass "green: empty containers and mcp_packages arrays valid" "$out" "$rc"

# ---------------------------------------------------------------------------
echo "red fixtures: cross-field identity consistency fail-opens (P3 repair)"
# ---------------------------------------------------------------------------

# Independent mutant 1: container image@sha256 + contradictory repository
lock_mutant "$ROOT/bad-lock-container-repo-conflict.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "repository": "ghcr.io/other/different",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-repo-conflict.json" 2>&1); rc=$?
expect_fail "red: container image@sha256 + conflicting repository fails" "$out" "$rc" "conflict\|repository"

# Independent mutant 2: MCP package@version + contradictory version field
lock_mutant "$ROOT/bad-lock-mcp-version-conflict.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "package": "probe@1.2.3",
    "version": "9.9.9",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-version-conflict.json" 2>&1); rc=$?
expect_fail "red: MCP package@1.2.3 + version 9.9.9 fails" "$out" "$rc" "conflict\|version"

# Independent mutant 3: MCP package@version + contradictory identity
lock_mutant "$ROOT/bad-lock-mcp-identity-conflict.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "package": "probe@1.2.3",
    "identity": "other@4.5.6",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-identity-conflict.json" 2>&1); rc=$?
expect_fail "red: MCP package@1.2.3 + identity other@4.5.6 fails" "$out" "$rc" "conflict\|identity"

# --- Broader container equal-vs-conflicting ---
lock_mutant "$ROOT/ok-lock-container-repo-equal.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "repository": "ghcr.io/org/tool",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-repo-equal.json" 2>&1); rc=$?
expect_pass "green: container image@sha256 + equal repository + equal digest" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-container-identity-equal.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "identity": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-identity-equal.json" 2>&1); rc=$?
expect_pass "green: container image@sha256 + equal identity locator" "$out" "$rc"

lock_mutant "$ROOT/bad-lock-container-digest-conflict2.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-digest-conflict2.json" 2>&1); rc=$?
expect_fail "red: container image@sha256 + conflicting digest string fails" "$out" "$rc" "conflict"

lock_mutant "$ROOT/bad-lock-container-identity-conflict.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "identity": "ghcr.io/other/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-identity-conflict.json" 2>&1); rc=$?
expect_fail "red: container image@sha256 + conflicting identity locator fails" "$out" "$rc" "conflict\|identity"

# Container ref must prove equality to canon image locator (not mere syntactic validity).
# Independent reviewer mutants: IMAGE_DIGEST ref and digest-only ref that disagree.
lock_mutant "$ROOT/ok-lock-container-ref-equal-image.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "ref": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-ref-equal-image.json" 2>&1); rc=$?
expect_pass "green: container image@sha256 + equal ref IMAGE_DIGEST" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-container-ref-equal-sha256.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "ref": "sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-ref-equal-sha256.json" 2>&1); rc=$?
expect_pass "green: container image@sha256 + equal ref sha256 digest" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-container-ref-equal-hex64.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "ref": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-ref-equal-hex64.json" 2>&1); rc=$?
expect_pass "green: container image@sha256 + equal ref bare hex64 digest" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-container-ref-equal-repo.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "ref": "ghcr.io/org/tool",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-ref-equal-repo.json" 2>&1); rc=$?
expect_pass "green: container image@sha256 + equal ref repository path" "$out" "$rc"

lock_mutant "$ROOT/bad-lock-container-ref-image-conflict.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "ref": "ghcr.io/other/tool@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-ref-image-conflict.json" 2>&1); rc=$?
expect_fail "red: container image@sha256 A + ref IMAGE_DIGEST B fails" "$out" "$rc" "conflict\|ref"

lock_mutant "$ROOT/bad-lock-container-ref-sha256-conflict.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "ref": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-ref-sha256-conflict.json" 2>&1); rc=$?
expect_fail "red: container image@sha256 A + ref sha256 B fails" "$out" "$rc" "conflict\|ref\|digest"

lock_mutant "$ROOT/bad-lock-container-ref-hex64-conflict.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "ref": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-ref-hex64-conflict.json" 2>&1); rc=$?
expect_fail "red: container image@sha256 A + ref bare hex64 B fails" "$out" "$rc" "conflict\|ref\|digest"

# Adjacent identity alias: digest-only identity must also prove equality (parity with ref).
lock_mutant "$ROOT/ok-lock-container-identity-equal-sha256.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "identity": "sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-identity-equal-sha256.json" 2>&1); rc=$?
expect_pass "green: container image@sha256 + equal identity sha256 digest" "$out" "$rc"

lock_mutant "$ROOT/bad-lock-container-identity-sha256-conflict.json" '
data["containers"] = [{
    "id": "probe",
    "image": "ghcr.io/org/tool@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "identity": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-identity-sha256-conflict.json" 2>&1); rc=$?
expect_fail "red: container image@sha256 A + identity sha256 B fails" "$out" "$rc" "conflict\|identity\|digest"

lock_mutant "$ROOT/bad-lock-container-repo-alt.json" '
data["containers"] = [{
    "id": "probe",
    "artifact": "registry/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "repo": "registry/other",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-repo-alt.json" 2>&1); rc=$?
expect_fail "red: container artifact@sha256 + conflicting repo fails" "$out" "$rc" "conflict\|repository"

# --- Broader MCP package equal-vs-conflicting ---
lock_mutant "$ROOT/ok-lock-mcp-package-redundant-equal.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "name": "probe",
    "package": "probe@1.2.3",
    "version": "1.2.3",
    "identity": "probe@1.2.3",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-mcp-package-redundant-equal.json" 2>&1); rc=$?
expect_pass "green: MCP package + equal version + equal identity + equal name" "$out" "$rc"

lock_mutant "$ROOT/bad-lock-mcp-name-conflict.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "name": "other",
    "package": "probe@1.2.3",
    "version": "1.2.3",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-name-conflict.json" 2>&1); rc=$?
expect_fail "red: MCP package@probe + conflicting name fails" "$out" "$rc" "conflict\|name"

lock_mutant "$ROOT/bad-lock-mcp-identity-version-conflict.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "package": "probe@1.2.3",
    "version": "1.2.3",
    "identity": "probe@9.9.9",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-identity-version-conflict.json" 2>&1); rc=$?
expect_fail "red: MCP package@1.2.3 + identity probe@9.9.9 fails" "$out" "$rc" "conflict"

# --- Broader MCP git/source equal-vs-conflicting ---
lock_mutant "$ROOT/ok-lock-mcp-git-minimal.json" '
data["mcp_packages"] = [{
    "id": "git-mcp",
    "source": "https://github.com/example/mcp.git",
    "ref": "90c50d653d7fd978ec5d436b548eca8613dc2d26",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-mcp-git-minimal.json" 2>&1); rc=$?
expect_pass "green: MCP git source+ref (no redundant aliases)" "$out" "$rc"

lock_mutant "$ROOT/bad-lock-mcp-git-dual-source.json" '
data["mcp_packages"] = [{
    "id": "git-mcp",
    "source": "https://github.com/example/mcp.git",
    "repository": "https://github.com/other/mcp.git",
    "ref": "90c50d653d7fd978ec5d436b548eca8613dc2d26",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-git-dual-source.json" 2>&1); rc=$?
expect_fail "red: MCP conflicting source vs repository fails" "$out" "$rc" "conflict\|source\|multiple"

lock_mutant "$ROOT/bad-lock-mcp-git-dual-source-equal.json" '
data["mcp_packages"] = [{
    "id": "git-mcp",
    "source": "https://github.com/example/mcp.git",
    "repository": "https://github.com/example/mcp.git",
    "ref": "90c50d653d7fd978ec5d436b548eca8613dc2d26",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-git-dual-source-equal.json" 2>&1); rc=$?
expect_fail "red: MCP duplicate equal source aliases fail closed" "$out" "$rc" "multiple\|alias"

lock_mutant "$ROOT/bad-lock-mcp-git-dual-commit.json" '
data["mcp_packages"] = [{
    "id": "git-mcp",
    "source": "https://github.com/example/mcp.git",
    "ref": "90c50d653d7fd978ec5d436b548eca8613dc2d26",
    "commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-git-dual-commit.json" 2>&1); rc=$?
expect_fail "red: MCP conflicting ref vs commit fails" "$out" "$rc" "conflict\|commit\|multiple"

# --- Broader MCP artifact equal-vs-conflicting ---
lock_mutant "$ROOT/ok-lock-mcp-artifact-equal-id.json" '
data["mcp_packages"] = [{
    "id": "art-mcp",
    "artifact": "art-mcp-1.0.0.tgz",
    "identity": "art-mcp-1.0.0.tgz",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/ok-lock-mcp-artifact-equal-id.json" 2>&1); rc=$?
expect_pass "green: MCP artifact + equal identity string" "$out" "$rc"

lock_mutant "$ROOT/bad-lock-mcp-artifact-dual.json" '
data["mcp_packages"] = [{
    "id": "art-mcp",
    "artifact": "art-mcp-1.0.0.tgz",
    "tarball": "other-1.0.0.tgz",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-artifact-dual.json" 2>&1); rc=$?
expect_fail "red: MCP conflicting artifact vs tarball fails" "$out" "$rc" "conflict\|artifact\|multiple"

lock_mutant "$ROOT/bad-lock-mcp-artifact-identity-conflict.json" '
data["mcp_packages"] = [{
    "id": "art-mcp",
    "artifact": "art-mcp-1.0.0.tgz",
    "identity": "other-artifact.tgz",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-artifact-identity-conflict.json" 2>&1); rc=$?
expect_fail "red: MCP artifact + conflicting identity fails" "$out" "$rc" "conflict\|identity"

# Cross-shape mixture still rejected (package fields + git)
lock_mutant "$ROOT/bad-lock-mcp-cross-shape-pkg-git.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "package": "probe@1.2.3",
    "version": "1.2.3",
    "source": "https://github.com/example/mcp.git",
    "ref": "90c50d653d7fd978ec5d436b548eca8613dc2d26",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-cross-shape-pkg-git.json" 2>&1); rc=$?
expect_fail "red: MCP package+git cross-shape mixture fails" "$out" "$rc" "multiple conflicting locator\|cross-shape"

# ---------------------------------------------------------------------------
echo "red fixtures: tools[] cross-field pin binding (Codex review repair)"
# ---------------------------------------------------------------------------
# Core tools[] must bind every redundant locator claim to one canonical pin.
# Independent field syntax is not enough — contradictions fail closed.

# Mutant: goose identity v9.9.9 with version still 1.45.0
lock_mutant "$ROOT/bad-lock-tool-goose-identity-conflict.json" '
for t in data["tools"]:
    if t.get("id") == "goose-cli":
        t["identity"] = "v9.9.9"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-goose-identity-conflict.json" 2>&1); rc=$?
expect_fail "red: goose identity v9.9.9 vs version 1.45.0 fails" "$out" "$rc" "conflict\|identity"

# Mutant: Goose source URL rewritten to v9.9.9, version still 1.45.0
lock_mutant "$ROOT/bad-lock-tool-goose-source-conflict.json" '
for t in data["tools"]:
    if t.get("id") == "goose-cli":
        t["source_url"] = str(t.get("source_url") or "").replace("v1.45.0", "v9.9.9")
'
out=$(check_lock_py "$ROOT/bad-lock-tool-goose-source-conflict.json" 2>&1); rc=$?
expect_fail "red: goose source_url v9.9.9 vs version 1.45.0 fails" "$out" "$rc" "conflict\|source_url"

# Mutant: gitleaks version 9.9.9 against unchanged identity/asset/digest/source
lock_mutant "$ROOT/bad-lock-tool-gitleaks-version-conflict.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["version"] = "9.9.9"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-gitleaks-version-conflict.json" 2>&1); rc=$?
expect_fail "red: gitleaks version 9.9.9 vs identity/asset/source fails" "$out" "$rc" "conflict"

# Mutant: gitleaks identity v9.9.9 against unchanged version/asset/digest/source
lock_mutant "$ROOT/bad-lock-tool-gitleaks-identity-conflict.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["identity"] = "v9.9.9"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-gitleaks-identity-conflict.json" 2>&1); rc=$?
expect_fail "red: gitleaks identity v9.9.9 vs version 8.30.1 fails" "$out" "$rc" "conflict\|identity"

# Mutant: semgrep package semgrep==9.9.9 against version 1.172.0
lock_mutant "$ROOT/bad-lock-tool-semgrep-package-conflict.json" '
for t in data["tools"]:
    if t.get("id") == "semgrep":
        t["package"] = "semgrep==9.9.9"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-semgrep-package-conflict.json" 2>&1); rc=$?
expect_fail "red: semgrep package==9.9.9 vs version 1.172.0 fails" "$out" "$rc" "conflict\|package"

# Mutant: semgrep asset filename containing 9.9.9 against version 1.172.0
lock_mutant "$ROOT/bad-lock-tool-semgrep-asset-conflict.json" '
for t in data["tools"]:
    if t.get("id") == "semgrep":
        t["asset"] = "semgrep-9.9.9.tar.gz"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-semgrep-asset-conflict.json" 2>&1); rc=$?
expect_fail "red: semgrep asset 9.9.9 vs version 1.172.0 fails" "$out" "$rc" "conflict\|asset"

# Mutant: socket package socket@9.9.9 against version 1.1.147
lock_mutant "$ROOT/bad-lock-tool-socket-package-conflict.json" '
for t in data["tools"]:
    if t.get("id") == "socket-cli":
        t["package"] = "socket@9.9.9"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-socket-package-conflict.json" 2>&1); rc=$?
expect_fail "red: socket package@9.9.9 vs version 1.1.147 fails" "$out" "$rc" "conflict\|package"

# Mutant: noncanonical leading-zero version 08.30.1
lock_mutant "$ROOT/bad-lock-tool-leading-zero-version.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["version"] = "08.30.1"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-leading-zero-version.json" 2>&1); rc=$?
expect_fail "red: leading-zero version 08.30.1 fails" "$out" "$rc" "semver"

# Matching green: redundant locator aliases that exact-agree with the pin
lock_mutant "$ROOT/ok-lock-tool-artifact-equal-asset.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["artifact"] = t["asset"]
'
out=$(check_lock_py "$ROOT/ok-lock-tool-artifact-equal-asset.json" 2>&1); rc=$?
expect_pass "green: gitleaks artifact equal to asset (matching pin)" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-tool-source-equal-url.json" '
for t in data["tools"]:
    if t.get("id") == "goose-cli":
        t["source"] = t["source_url"]
'
out=$(check_lock_py "$ROOT/ok-lock-tool-source-equal-url.json" 2>&1); rc=$?
expect_pass "green: goose source equal to source_url (matching pin)" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-tool-socket-integrity-equal.json" '
for t in data["tools"]:
    if t.get("id") == "socket-cli":
        t["integrity"] = t["digest"]["value"]
'
out=$(check_lock_py "$ROOT/ok-lock-tool-socket-integrity-equal.json" 2>&1); rc=$?
expect_pass "green: socket integrity equal digest.value" "$out" "$rc"

# Package-shaped identity is NOT an allowed alternate for core tools whose
# profile identity is the bare pin (semgrep → "1.172.0"). Reject even when
# version-equivalent to package/version fields.
lock_mutant "$ROOT/bad-lock-tool-semgrep-package-identity.json" '
for t in data["tools"]:
    if t.get("id") == "semgrep":
        t["identity"] = "semgrep@1.172.0"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-semgrep-package-identity.json" 2>&1); rc=$?
expect_fail "red: semgrep identity package@pin (not exact profile identity) fails" "$out" "$rc" "identity\|exact profile\|shorthand\|package"

lock_mutant "$ROOT/ok-lock-tool-download-url-equal.json" '
for t in data["tools"]:
    if t.get("id") == "trufflehog":
        t["download_url"] = t["source_url"]
'
out=$(check_lock_py "$ROOT/ok-lock-tool-download-url-equal.json" 2>&1); rc=$?
expect_pass "green: trufflehog download_url equal source_url" "$out" "$rc"

# Red: integrity contradicts digest
lock_mutant "$ROOT/bad-lock-tool-integrity-conflict.json" '
for t in data["tools"]:
    if t.get("id") == "socket-cli":
        t["integrity"] = "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
'
out=$(check_lock_py "$ROOT/bad-lock-tool-integrity-conflict.json" 2>&1); rc=$?
expect_fail "red: socket integrity vs digest.value conflict fails" "$out" "$rc" "conflict\|integrity"

# Red: package-shaped identity name disagrees with package field
lock_mutant "$ROOT/bad-lock-tool-package-name-conflict.json" '
for t in data["tools"]:
    if t.get("id") == "socket-cli":
        t["identity"] = "other@1.1.147"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-package-name-conflict.json" 2>&1); rc=$?
expect_fail "red: socket identity name vs package name fails" "$out" "$rc" "conflict\|identity\|package"

# ---------------------------------------------------------------------------
echo "red fixtures: top-level recipe / goose_recipe_schema binding"
# ---------------------------------------------------------------------------
# Independent review: on prior head both mutants returned rc=0 —
#   recipe → other.yaml
#   goose_recipe_schema → 9.9.9
# while the lock validator only required schema/version/tools. Fail closed:
# bind recipe to the canonical shipped reference and goose_recipe_schema to
# the recipe schema/version contract (derived from sibling recipe when present).

lock_mutant "$ROOT/bad-lock-recipe-other.json" '
data["recipe"] = "other.yaml"
'
out=$(check_lock_py "$ROOT/bad-lock-recipe-other.json" 2>&1); rc=$?
expect_fail "red: lock recipe other.yaml fails" "$out" "$rc" "recipe\|canonical\|other"

lock_mutant "$ROOT/bad-lock-goose-recipe-schema-999.json" '
data["goose_recipe_schema"] = "9.9.9"
'
out=$(check_lock_py "$ROOT/bad-lock-goose-recipe-schema-999.json" 2>&1); rc=$?
expect_fail "red: lock goose_recipe_schema 9.9.9 fails" "$out" "$rc" "goose_recipe_schema\|schema/version\|9\.9\.9"

# Adjacent top-level version claim: lock.version free-form exact 9.9.9 must fail
lock_mutant "$ROOT/bad-lock-doc-version-999.json" '
data["version"] = "9.9.9"
'
out=$(check_lock_py "$ROOT/bad-lock-doc-version-999.json" 2>&1); rc=$?
expect_fail "red: lock.version 9.9.9 fails schema v1 pin" "$out" "$rc" "lock.version\|1\.0\.0"

# Green: explicit equal re-bind of shipped top-level identity
lock_mutant "$ROOT/ok-lock-recipe-schema-equal.json" '
data["recipe"] = "red-team.yaml"
data["goose_recipe_schema"] = "1.0.0"
data["version"] = "1.0.0"
'
out=$(check_lock_py "$ROOT/ok-lock-recipe-schema-equal.json" 2>&1); rc=$?
expect_pass "green: lock recipe + goose_recipe_schema + version match shipped contract" "$out" "$rc"

# Green: shipped lock path (not a mutant) — reaffirm top-level binding end-to-end
out=$(check_lock_py "$TOOLCHAIN_LOCK" 2>&1); rc=$?
expect_pass "green: shipped lock top-level recipe/schema binding holds" "$out" "$rc"

# ---------------------------------------------------------------------------
echo "red fixtures: core tools[] origin/artifact identity + digest recipe bind"
# ---------------------------------------------------------------------------
# Independent review residual fail-opens (all returned rc=0 on prior head):
#   1. gitleaks source_url .../releases/latest/download/gitleaks_darwin_arm64.tar.gz
#   2. gitleaks asset gitleaks_latest_darwin_arm64.tar.gz
#   3. gitleaks versionless source_url https://example.com/download/tool.tar.gz
#   4. gitleaks same-version wrong-repo source alias
#   5. gitleaks same-version mismatched artifact malware_8.30.1_darwin_arm64.tar.gz
#   6. recipe_sha256 with no .yaml token pointing at /tmp/other
# Structural fix: canonical origin/asset/source profiles per supported core tool
# + require exactly one lock.recipe YAML path token in digest instructions.

# 1) floating /latest/ release download path (no semver token → prior fail-open)
lock_mutant "$ROOT/bad-lock-tool-gitleaks-source-latest.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["source_url"] = (
            "https://github.com/gitleaks/gitleaks/releases/latest/download/"
            "gitleaks_darwin_arm64.tar.gz"
        )
'
out=$(check_lock_py "$ROOT/bad-lock-tool-gitleaks-source-latest.json" 2>&1); rc=$?
expect_fail "red: gitleaks source_url releases/latest/download fails" "$out" "$rc" "source_url\|canonical\|origin"

# 2) asset with latest token (no semver → prior fail-open)
lock_mutant "$ROOT/bad-lock-tool-gitleaks-asset-latest.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["asset"] = "gitleaks_latest_darwin_arm64.tar.gz"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-gitleaks-asset-latest.json" 2>&1); rc=$?
expect_fail "red: gitleaks asset gitleaks_latest_darwin_arm64 fails" "$out" "$rc" "asset\|canonical"

# 3) versionless unrelated origin source_url
lock_mutant "$ROOT/bad-lock-tool-gitleaks-source-versionless.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["source_url"] = "https://example.com/download/tool.tar.gz"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-gitleaks-source-versionless.json" 2>&1); rc=$?
expect_fail "red: gitleaks versionless example.com source_url fails" "$out" "$rc" "source_url\|canonical\|origin"

# 4) same version, wrong repository origin
lock_mutant "$ROOT/bad-lock-tool-gitleaks-source-wrong-repo.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["source_url"] = (
            "https://github.com/other/project/releases/download/v8.30.1/other.tar.gz"
        )
'
out=$(check_lock_py "$ROOT/bad-lock-tool-gitleaks-source-wrong-repo.json" 2>&1); rc=$?
expect_fail "red: gitleaks same-version wrong-repo source_url fails" "$out" "$rc" "source_url\|canonical\|origin"

# 5) same version, mismatched artifact/tool name
lock_mutant "$ROOT/bad-lock-tool-gitleaks-asset-malware.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["asset"] = "malware_8.30.1_darwin_arm64.tar.gz"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-gitleaks-asset-malware.json" 2>&1); rc=$?
expect_fail "red: gitleaks same-version malware artifact name fails" "$out" "$rc" "asset\|canonical"

# 6) digest instruction with no .yaml token (points at /tmp/other)
lock_mutant "$ROOT/bad-lock-di-recipe-sha-nonyaml.json" '
data["digest_instructions"]["macOS"]["recipe_sha256"] = "shasum -a 256 /tmp/other"
'
out=$(check_lock_py "$ROOT/bad-lock-di-recipe-sha-nonyaml.json" 2>&1); rc=$?
expect_fail "red: recipe_sha256 /tmp/other without .yaml token fails" "$out" "$rc" "recipe\|yaml\|digest_instructions"

# Adjacent alias origin/name bypass (same structural hole as source_url/asset)
lock_mutant "$ROOT/bad-lock-tool-gitleaks-download-url-wrong-origin.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["download_url"] = (
            "https://github.com/other/project/releases/download/v8.30.1/"
            "gitleaks_8.30.1_darwin_arm64.tar.gz"
        )
'
out=$(check_lock_py "$ROOT/bad-lock-tool-gitleaks-download-url-wrong-origin.json" 2>&1); rc=$?
expect_fail "red: gitleaks download_url wrong-origin alias fails" "$out" "$rc" "download_url\|canonical\|origin"

lock_mutant "$ROOT/bad-lock-tool-goose-source-alias-latest.json" '
for t in data["tools"]:
    if t.get("id") == "goose-cli":
        t["source"] = (
            "https://github.com/aaif-goose/goose/releases/latest/download/"
            "goose-aarch64-apple-darwin.tar.gz"
        )
'
out=$(check_lock_py "$ROOT/bad-lock-tool-goose-source-alias-latest.json" 2>&1); rc=$?
expect_fail "red: goose source alias releases/latest fails" "$out" "$rc" "source\|canonical\|origin"

lock_mutant "$ROOT/bad-lock-tool-trufflehog-filename-mismatch.json" '
for t in data["tools"]:
    if t.get("id") == "trufflehog":
        t["filename"] = "othertool_3.96.0_darwin_arm64.tar.gz"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-trufflehog-filename-mismatch.json" 2>&1); rc=$?
expect_fail "red: trufflehog filename alias mismatched tool name fails" "$out" "$rc" "filename\|canonical\|asset"

# Matching green: reaffirm canonical origin/asset + digest recipe binding
lock_mutant "$ROOT/ok-lock-tool-gitleaks-canonical-origin.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["source_url"] = (
            "https://github.com/gitleaks/gitleaks/releases/download/"
            "v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz"
        )
        t["source_meta_url"] = (
            "https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1"
        )
        t["asset"] = "gitleaks_8.30.1_darwin_arm64.tar.gz"
        t["artifact"] = "gitleaks_8.30.1_darwin_arm64.tar.gz"
        t["source"] = t["source_url"]
'
out=$(check_lock_py "$ROOT/ok-lock-tool-gitleaks-canonical-origin.json" 2>&1); rc=$?
expect_pass "green: gitleaks canonical origin/asset + equal aliases" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-di-recipe-sha-canonical.json" '
# Reaffirm shipped digest instructions (canonical red-team.yaml path).
di = data["digest_instructions"]
di["macOS"]["recipe_sha256"] = di["macOS"]["recipe_sha256"]
di["portable"]["recipe_sha256"] = di["portable"]["recipe_sha256"]
'
out=$(check_lock_py "$ROOT/ok-lock-di-recipe-sha-canonical.json" 2>&1); rc=$?
expect_pass "green: digest_instructions recipe_sha256 matches lock.recipe" "$out" "$rc"

# Prior other.yaml recipe mutant remains red (cross-bind with di still holds)
lock_mutant "$ROOT/bad-lock-recipe-other-with-di.json" '
data["recipe"] = "other.yaml"
'
out=$(check_lock_py "$ROOT/bad-lock-recipe-other-with-di.json" 2>&1); rc=$?
expect_fail "red: lock.recipe other.yaml still fails under origin/di bind" "$out" "$rc" "recipe\|canonical\|other"

# ---------------------------------------------------------------------------
echo "red fixtures: closed-world exact tool/DI pins (comprehensive residual repair)"
# ---------------------------------------------------------------------------
# Independent 45-mutant review residual rc=0 fail-opens (12 probes):
#   1. Extra sixth structurally valid tool accepted
#   2. gitleaks name → malware accepted
#   3. required kind deleted accepted
#   4. gitleaks identity → malware@8.30.1 accepted (version-only compare)
#   5. gitleaks SHA256 → different well-formed 64-hex accepted
#   6. Socket SRI → different well-formed sha512 base64 accepted
#   7. repository → https://evil.example/gitleaks/gitleaks substring accept
#   8. ref → arbitrary full 40-hex accepted
#   9. gitleaks execution pin-only → offline-validate-only accepted
#  10. digest_instructions portable section deleted accepted
#  11. digest command path → /tmp/red-team.yaml basename-only accept
#  12. digest command dual /tmp + playbooks equal basenames accepted
# Structural fix: closed-world exact tool profiles + exact DI commands +
# reject unsupported tool aliases + exact tool id set.

# 1) sixth structurally valid tool (clone of gitleaks with new id)
lock_mutant "$ROOT/bad-lock-extra-sixth-tool.json" '
import copy
extra = copy.deepcopy(next(t for t in data["tools"] if t.get("id") == "gitleaks"))
extra["id"] = "extra-scanner"
data["tools"].append(extra)
'
out=$(check_lock_py "$ROOT/bad-lock-extra-sixth-tool.json" 2>&1); rc=$?
expect_fail "red: extra sixth tool id fails" "$out" "$rc" "extra tool\|unsupported extra\|exact set"

# 2) gitleaks name → malware
lock_mutant "$ROOT/bad-lock-gitleaks-name-malware.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["name"] = "malware"
'
out=$(check_lock_py "$ROOT/bad-lock-gitleaks-name-malware.json" 2>&1); rc=$?
expect_fail "red: gitleaks name malware fails" "$out" "$rc" "name\|canonical\|malware"

# 3) required kind deleted
lock_mutant "$ROOT/bad-lock-gitleaks-kind-deleted.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        del t["kind"]
'
out=$(check_lock_py "$ROOT/bad-lock-gitleaks-kind-deleted.json" 2>&1); rc=$?
expect_fail "red: gitleaks kind deleted fails" "$out" "$rc" "kind\|missing"

# 4) gitleaks identity → malware@8.30.1 (same version, wrong name)
lock_mutant "$ROOT/bad-lock-gitleaks-identity-malware.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["identity"] = "malware@8.30.1"
'
out=$(check_lock_py "$ROOT/bad-lock-gitleaks-identity-malware.json" 2>&1); rc=$?
expect_fail "red: gitleaks identity malware@8.30.1 fails" "$out" "$rc" "identity\|canonical\|malware"

# 5) gitleaks SHA256 → different well-formed 64-hex
lock_mutant "$ROOT/bad-lock-gitleaks-digest-wrong-hex.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["digest"]["value"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
'
out=$(check_lock_py "$ROOT/bad-lock-gitleaks-digest-wrong-hex.json" 2>&1); rc=$?
expect_fail "red: gitleaks well-formed but non-canonical SHA256 fails" "$out" "$rc" "digest.value\|shipped pin\|non-canonical"

# 6) Socket SRI → different well-formed sha512 base64 (64 decoded bytes)
lock_mutant "$ROOT/bad-lock-socket-sri-wrong.json" '
import base64
for t in data["tools"]:
    if t.get("id") == "socket-cli":
        # 64 zero bytes → valid sha512-integrity shape, wrong pin
        t["digest"]["value"] = "sha512-" + base64.b64encode(bytes(64)).decode("ascii")
'
out=$(check_lock_py "$ROOT/bad-lock-socket-sri-wrong.json" 2>&1); rc=$?
expect_fail "red: socket well-formed but non-canonical SRI fails" "$out" "$rc" "digest.value\|shipped pin\|non-canonical"

# 7) repository alias evil.example with substring gitleaks/gitleaks
lock_mutant "$ROOT/bad-lock-gitleaks-repository-evil.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["repository"] = "https://evil.example/gitleaks/gitleaks"
'
out=$(check_lock_py "$ROOT/bad-lock-gitleaks-repository-evil.json" 2>&1); rc=$?
expect_fail "red: gitleaks repository evil.example alias fails" "$out" "$rc" "unsupported tool alias\|repository"

# 8) ref alias arbitrary full 40-hex
lock_mutant "$ROOT/bad-lock-gitleaks-ref-hex40.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["ref"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
'
out=$(check_lock_py "$ROOT/bad-lock-gitleaks-ref-hex40.json" 2>&1); rc=$?
expect_fail "red: gitleaks ref 40-hex alias fails" "$out" "$rc" "unsupported tool alias\|ref"

# 9) gitleaks execution pin-only → offline-validate-only
lock_mutant "$ROOT/bad-lock-gitleaks-execution-offline.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["execution"] = "offline-validate-only"
'
out=$(check_lock_py "$ROOT/bad-lock-gitleaks-execution-offline.json" 2>&1); rc=$?
expect_fail "red: gitleaks execution offline-validate-only fails" "$out" "$rc" "execution must be exact\|pin-only"

# 10) digest_instructions portable section deleted
lock_mutant "$ROOT/bad-lock-di-portable-deleted.json" '
del data["digest_instructions"]["portable"]
'
out=$(check_lock_py "$ROOT/bad-lock-di-portable-deleted.json" 2>&1); rc=$?
expect_fail "red: digest_instructions portable deleted fails" "$out" "$rc" "portable\|missing"

# 11) digest command path → /tmp/red-team.yaml (basename-only prior fail-open)
lock_mutant "$ROOT/bad-lock-di-recipe-tmp-path.json" '
data["digest_instructions"]["macOS"]["recipe_sha256"] = "shasum -a 256 /tmp/red-team.yaml | awk '"'"'{print $1}'"'"'"
'
out=$(check_lock_py "$ROOT/bad-lock-di-recipe-tmp-path.json" 2>&1); rc=$?
expect_fail "red: recipe_sha256 /tmp/red-team.yaml absolute path fails" "$out" "$rc" "exact shipped command\|repository-relative\|got\|must equal"

# 12) dual operands /tmp/red-team.yaml + playbooks/recipes/red-team.yaml
lock_mutant "$ROOT/bad-lock-di-recipe-dual-path.json" '
data["digest_instructions"]["macOS"]["recipe_sha256"] = "shasum -a 256 /tmp/red-team.yaml playbooks/recipes/red-team.yaml | awk '"'"'{print $1}'"'"'"
'
out=$(check_lock_py "$ROOT/bad-lock-di-recipe-dual-path.json" 2>&1); rc=$?
expect_fail "red: recipe_sha256 dual /tmp + playbooks paths fails" "$out" "$rc" "exact shipped command\|exactly one\|got\|must equal"
# Adjacent closed-world sweeps (same class)
lock_mutant "$ROOT/bad-lock-toplevel-unknown-key.json" '
data["evil_extension"] = {"x": 1}
'
out=$(check_lock_py "$ROOT/bad-lock-toplevel-unknown-key.json" 2>&1); rc=$?
expect_fail "red: unknown top-level lock key fails" "$out" "$rc" "unsupported top-level\|evil_extension"

lock_mutant "$ROOT/bad-lock-tool-unknown-field.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["side_channel"] = "https://evil.example/payload"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-unknown-field.json" 2>&1); rc=$?
expect_fail "red: unknown tool field side_channel fails" "$out" "$rc" "unknown/extra tool field\|side_channel"

lock_mutant "$ROOT/bad-lock-goose-name-wrong.json" '
for t in data["tools"]:
    if t.get("id") == "goose-cli":
        t["name"] = "Not Goose"
'
out=$(check_lock_py "$ROOT/bad-lock-goose-name-wrong.json" 2>&1); rc=$?
expect_fail "red: goose-cli name Not Goose fails" "$out" "$rc" "name\|canonical"

lock_mutant "$ROOT/bad-lock-semgrep-kind-wrong.json" '
for t in data["tools"]:
    if t.get("id") == "semgrep":
        t["kind"] = "library"
'
out=$(check_lock_py "$ROOT/bad-lock-semgrep-kind-wrong.json" 2>&1); rc=$?
expect_fail "red: semgrep kind library fails" "$out" "$rc" "kind must be exact\|cli"

lock_mutant "$ROOT/bad-lock-trufflehog-digest-wrong.json" '
for t in data["tools"]:
    if t.get("id") == "trufflehog":
        t["digest"]["value"] = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
'
out=$(check_lock_py "$ROOT/bad-lock-trufflehog-digest-wrong.json" 2>&1); rc=$?
expect_fail "red: trufflehog well-formed non-canonical SHA256 fails" "$out" "$rc" "digest.value\|shipped pin\|non-canonical"

lock_mutant "$ROOT/bad-lock-di-unknown-platform.json" '
data["digest_instructions"]["windows"] = dict(data["digest_instructions"]["portable"])
'
out=$(check_lock_py "$ROOT/bad-lock-di-unknown-platform.json" 2>&1); rc=$?
expect_fail "red: digest_instructions unknown windows key fails" "$out" "$rc" "unsupported key\|windows"

lock_mutant "$ROOT/bad-lock-di-portable-recipe-tmp.json" '
data["digest_instructions"]["portable"]["recipe_sha256"] = "sha256sum /tmp/red-team.yaml | awk '"'"'{print $1}'"'"'"
'
out=$(check_lock_py "$ROOT/bad-lock-di-portable-recipe-tmp.json" 2>&1); rc=$?
expect_fail "red: portable recipe_sha256 /tmp path fails" "$out" "$rc" "exact shipped command\|repository-relative\|got\|must equal"

lock_mutant "$ROOT/bad-lock-tool-omit-required.json" '
data["tools"] = [t for t in data["tools"] if t.get("id") != "trufflehog"]
'
out=$(check_lock_py "$ROOT/bad-lock-tool-omit-required.json" 2>&1); rc=$?
expect_fail "red: omitting required trufflehog tool fails" "$out" "$rc" "required tool id missing\|trufflehog"

# Green: exact shipped closed-world profile reaffirmations
lock_mutant "$ROOT/ok-lock-closed-world-exact.json" '
# no-op rebind of exact shipped pins
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["name"] = "gitleaks"
        t["kind"] = "cli"
        t["identity"] = "v8.30.1"
        t["execution"] = "pin-only"
        t["digest"] = {
            "algorithm": "sha256",
            "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
        }
'
out=$(check_lock_py "$ROOT/ok-lock-closed-world-exact.json" 2>&1); rc=$?
expect_pass "green: gitleaks exact name/kind/identity/execution/digest" "$out" "$rc"

lock_mutant "$ROOT/ok-lock-di-exact-portable.json" '
# Reaffirm exact shipped DI commands (identity rebind, no path drift)
di = data["digest_instructions"]
di["portable"] = dict(di["portable"])
di["macOS"] = dict(di["macOS"])
'
out=$(check_lock_py "$ROOT/ok-lock-di-exact-portable.json" 2>&1); rc=$?
expect_pass "green: digest_instructions exact macOS+portable recipe commands" "$out" "$rc"

out=$(check_lock_py "$TOOLCHAIN_LOCK" 2>&1); rc=$?
expect_pass "green: shipped lock closed-world exact profile holds" "$out" "$rc"

# ---------------------------------------------------------------------------
echo "red fixtures: closed-schema bundled/container/MCP/identity residual (10 probes)"
# ---------------------------------------------------------------------------
# Fresh 29-probe closed-schema expansion found exactly 10 rc=0 fail-opens:
#   bundled_extensions allowed top-level but never structurally validated:
#     1. delete bundled_extensions
#     2. add an extra evil builtin
#     3. change bundled extension name to evil
#     4. change bundled_with to goose-cli@9.9.9
#     5. add unknown child key
#   container/MCP not closed when a valid canonical locator remains:
#     6. valid container locator + unknown evil_locator
#     7. valid MCP locator + unknown evil_locator
#   core exact identity still accepts shorthand variants:
#     8. gitleaks identity 8.30.1 instead of exact v8.30.1
#     9. semgrep identity v1.172.0 instead of exact 1.172.0
#    10. socket identity v1.1.147 instead of exact socket@1.1.147
# Plus one adjacency sweep over bundled/container/MCP unknown keys.

# 1) delete bundled_extensions
lock_mutant "$ROOT/bad-lock-bundled-ext-deleted.json" '
del data["bundled_extensions"]
'
out=$(check_lock_py "$ROOT/bad-lock-bundled-ext-deleted.json" 2>&1); rc=$?
expect_fail "red: deleting bundled_extensions fails" "$out" "$rc" "bundled_extensions\|missing required"

# 2) extra evil builtin
lock_mutant "$ROOT/bad-lock-bundled-ext-extra-evil.json" '
data["bundled_extensions"] = list(data.get("bundled_extensions") or []) + [{
    "id": "evil",
    "name": "evil",
    "type": "builtin",
    "bundled_with": "goose-cli@1.45.0",
    "notes": "unauthorized extra builtin",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-bundled-ext-extra-evil.json" 2>&1); rc=$?
expect_fail "red: extra evil bundled_extensions builtin fails" "$out" "$rc" "bundled_extensions\|exactly 1\|extra\|evil"

# 3) change bundled extension name to evil
lock_mutant "$ROOT/bad-lock-bundled-ext-name-evil.json" '
for be in data.get("bundled_extensions") or []:
    be["name"] = "evil"
'
out=$(check_lock_py "$ROOT/bad-lock-bundled-ext-name-evil.json" 2>&1); rc=$?
expect_fail "red: bundled_extensions name evil fails" "$out" "$rc" "bundled_extensions\|name\|developer\|evil"

# 4) change bundled_with to goose-cli@9.9.9
lock_mutant "$ROOT/bad-lock-bundled-ext-with-999.json" '
for be in data.get("bundled_extensions") or []:
    be["bundled_with"] = "goose-cli@9.9.9"
'
out=$(check_lock_py "$ROOT/bad-lock-bundled-ext-with-999.json" 2>&1); rc=$?
expect_fail "red: bundled_with goose-cli@9.9.9 fails" "$out" "$rc" "bundled_with\|goose-cli@1\.45\.0\|9\.9\.9"

# 5) unknown child key on bundled extension
lock_mutant "$ROOT/bad-lock-bundled-ext-unknown-key.json" '
for be in data.get("bundled_extensions") or []:
    be["evil_key"] = 1
'
out=$(check_lock_py "$ROOT/bad-lock-bundled-ext-unknown-key.json" 2>&1); rc=$?
expect_fail "red: bundled_extensions unknown child key fails" "$out" "$rc" "unknown/extra key\|evil_key\|bundled_extensions"

# 6) valid container locator + unknown evil_locator (adjacency fail-open)
lock_mutant "$ROOT/bad-lock-container-evil-locator.json" '
data["containers"] = [{
    "id": "probe",
    "image": "registry/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "evil_locator": "evil/repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-container-evil-locator.json" 2>&1); rc=$?
expect_fail "red: container valid locator + evil_locator fails" "$out" "$rc" "unknown/extra container key\|evil_locator"

# 7) valid MCP locator + unknown evil_locator (adjacency fail-open)
lock_mutant "$ROOT/bad-lock-mcp-evil-locator.json" '
data["mcp_packages"] = [{
    "id": "probe",
    "package": "probe@1.0.0",
    "version": "1.0.0",
    "evil_locator": "other@9.9.9",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-mcp-evil-locator.json" 2>&1); rc=$?
expect_fail "red: MCP valid locator + evil_locator fails" "$out" "$rc" "unknown/extra MCP key\|evil_locator"

# 8) gitleaks identity bare 8.30.1 (not exact v8.30.1)
lock_mutant "$ROOT/bad-lock-tool-gitleaks-identity-bare.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["identity"] = "8.30.1"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-gitleaks-identity-bare.json" 2>&1); rc=$?
expect_fail "red: gitleaks identity bare 8.30.1 (not v8.30.1) fails" "$out" "$rc" "identity\|exact profile\|v8\.30\.1\|shorthand"

# 9) semgrep identity v-prefixed (not exact 1.172.0)
lock_mutant "$ROOT/bad-lock-tool-semgrep-identity-vprefix.json" '
for t in data["tools"]:
    if t.get("id") == "semgrep":
        t["identity"] = "v1.172.0"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-semgrep-identity-vprefix.json" 2>&1); rc=$?
expect_fail "red: semgrep identity v1.172.0 (not 1.172.0) fails" "$out" "$rc" "identity\|exact profile\|1\.172\.0\|shorthand"

# 10) socket identity v-prefixed (not exact socket@1.1.147)
lock_mutant "$ROOT/bad-lock-tool-socket-identity-vprefix.json" '
for t in data["tools"]:
    if t.get("id") == "socket-cli":
        t["identity"] = "v1.1.147"
'
out=$(check_lock_py "$ROOT/bad-lock-tool-socket-identity-vprefix.json" 2>&1); rc=$?
expect_fail "red: socket identity v1.1.147 (not socket@1.1.147) fails" "$out" "$rc" "identity\|exact profile\|socket@1\.1\.147\|shorthand"

# Adjacency sweep: unknown keys on bundled + container + MCP in one lock
lock_mutant "$ROOT/bad-lock-unknown-key-adjacency.json" '
for be in data.get("bundled_extensions") or []:
    be["side_channel"] = True
data["containers"] = [{
    "id": "adj-c",
    "image": "registry/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "oci_ref": "bypass",
}]
data["mcp_packages"] = [{
    "id": "adj-m",
    "package": "probe@1.0.0",
    "locator": "bypass",
}]
'
out=$(check_lock_py "$ROOT/bad-lock-unknown-key-adjacency.json" 2>&1); rc=$?
expect_fail "red: bundled/container/MCP unknown-key adjacency fails" "$out" "$rc" "unknown/extra\|side_channel\|oci_ref\|locator"

# --- Matching exact green fixtures ---

# Green: exact shipped bundled_extensions (developer builtin + goose-cli@1.45.0)
lock_mutant "$ROOT/ok-lock-bundled-ext-exact.json" '
data["bundled_extensions"] = [{
    "id": "developer",
    "name": "developer",
    "type": "builtin",
    "bundled_with": "goose-cli@1.45.0",
    "notes": "Official Goose builtin bundled with the pinned CLI binary (shell + filesystem). No external package version required.",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-bundled-ext-exact.json" 2>&1); rc=$?
expect_pass "green: exact shipped bundled_extensions developer contract" "$out" "$rc"

# Green: container closed shape — only allowed keys + valid image locator
lock_mutant "$ROOT/ok-lock-container-closed-keys.json" '
data["containers"] = [{
    "id": "tool-image",
    "image": "ghcr.io/org/tool@sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    "repository": "ghcr.io/org/tool",
    "digest": {
        "algorithm": "sha256",
        "value": "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    },
}]
'
out=$(check_lock_py "$ROOT/ok-lock-container-closed-keys.json" 2>&1); rc=$?
expect_pass "green: container closed key set + image@sha256 + equal aliases" "$out" "$rc"

# Green: MCP closed package shape — only allowed keys
lock_mutant "$ROOT/ok-lock-mcp-closed-keys.json" '
data["mcp_packages"] = [{
    "id": "pkg-mcp",
    "name": "pkg-mcp",
    "package": "pkg-mcp@2.3.4",
    "version": "2.3.4",
    "identity": "pkg-mcp@2.3.4",
}]
'
out=$(check_lock_py "$ROOT/ok-lock-mcp-closed-keys.json" 2>&1); rc=$?
expect_pass "green: MCP closed key set + package@version locator" "$out" "$rc"

# Green: exact core identity strings byte-for-byte
lock_mutant "$ROOT/ok-lock-tool-exact-identities.json" '
for t in data["tools"]:
    if t.get("id") == "gitleaks":
        t["identity"] = "v8.30.1"
    if t.get("id") == "semgrep":
        t["identity"] = "1.172.0"
    if t.get("id") == "socket-cli":
        t["identity"] = "socket@1.1.147"
'
out=$(check_lock_py "$ROOT/ok-lock-tool-exact-identities.json" 2>&1); rc=$?
expect_pass "green: gitleaks/semgrep/socket exact profile identities" "$out" "$rc"

out=$(check_lock_py "$TOOLCHAIN_LOCK" 2>&1); rc=$?
expect_pass "green: shipped lock closed-schema residual holds" "$out" "$rc"

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
  # Law 8 / #95: optional external validate absent is NOT a pass. Offline
  # structural checks above remain the required gate; this line must not look
  # like a green validate in greps of "ok —" alone.
  echo "  skip — goose binary absent: official recipe validate NOT RUN (offline structural sensors remain the gate)"
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
# Tally line includes optional-validate disposition so run-all / greps cannot
# treat "exit 0 + N passed" as "goose validated" when status is NOT RUN (#95).
echo "goose-recipes.test.sh: $PASS passed, $FAIL failed, goose-validate: $GOOSE_VALIDATE_STATUS"
echo "goose recipe validate status: $GOOSE_VALIDATE_STATUS"
[[ "$FAIL" -eq 0 ]]
