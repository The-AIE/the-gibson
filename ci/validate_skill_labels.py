#!/usr/bin/env python3
"""Validate key/category/tags in every SKILL.md frontmatter against skill-ontology.json.

usage: validate_skill_labels.py --root DIR --namespace NS --ontology FILE --glob 'skills/*' [--glob ...]
Stdlib only. Exit 1 on any problem.
"""
import argparse, glob, json, os, re, sys

KEY = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*\.[a-z0-9]+(-[a-z0-9]+)*$")


def frontmatter(text):
    if text.startswith("﻿"):
        text = text[1:]
    m = re.match(r"---\r?\n(.*?)\r?\n---[ \t]*\r?(\n|$)", text, re.S)
    return m.group(1) if m else None


def scalar(fm, name, bad=None):
    found = re.findall(rf"^{name}:[ \t]*(.*)$", fm, re.M)
    if len(found) > 1 and bad:
        bad(f"duplicate '{name}' field")
    if not found:
        return None
    value = found[0].strip()
    if value and (value[0] in "\"'" or " #" in value) and bad:
        bad(f"'{name}' must be plain: no quotes or trailing comments")
    return value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--namespace", required=True)
    ap.add_argument("--ontology", required=True)
    ap.add_argument("--glob", action="append", required=True)
    a = ap.parse_args()
    onto = json.load(open(a.ontology))
    cats, tags = set(onto["categories"]), set(onto["tags"])
    problems, seen, count = [], {}, 0
    paths = sorted({p for g in a.glob for p in glob.glob(os.path.join(a.root, g, "SKILL.md"))})
    if True:
        for path in paths:
            count += 1
            rel = os.path.relpath(path, a.root)
            d = os.path.basename(os.path.dirname(path))
            text = open(path, encoding="utf-8").read()
            fm = frontmatter(text)
            def bad(msg):
                problems.append(f"{rel}: {msg}")
            if fm is None:
                bad("no frontmatter")
                continue
            if "\t" in fm:
                bad("tab in frontmatter (AK parser rejects it)")
            key = scalar(fm, "key", bad)
            if not key:
                bad("missing key")
            else:
                if not KEY.match(key):
                    bad(f"key '{key}' is not <ns>.<kebab-case>")
                if key != f"{a.namespace}.{d}":
                    bad(f"key '{key}' must equal '{a.namespace}.{d}'")
                if key in seen:
                    bad(f"duplicate key '{key}' (also {seen[key]})")
                seen[key] = rel
            cat = scalar(fm, "category", bad)
            if not cat:
                bad("missing category")
            elif cat not in cats:
                bad(f"unknown category '{cat}'")
            raw = scalar(fm, "tags", bad)
            if raw is None:
                bad("missing tags")
            elif not (raw.startswith("[") and raw.endswith("]")):
                bad("tags must be an inline list: tags: [a, b]")
            else:
                items = [t.strip() for t in raw[1:-1].split(",")] if raw[1:-1].strip() else []
                if not 1 <= len(items) <= 6:
                    bad(f"needs 1-6 tags, has {len(items)}")
                if len(set(items)) != len(items):
                    bad("duplicate tag")
                for t in items:
                    if t[:1] in "\"'":
                        bad(f"tag {t} must be unquoted")
                    elif t not in tags:
                        bad(f"unknown tag '{t}'")
    if count == 0:
        problems.append("no SKILL.md found; check --glob")
    for p in problems:
        print("FAIL", p)
    print(f"{count} skills checked, {len(problems)} problems")
    sys.exit(1 if problems else 0)


main()
