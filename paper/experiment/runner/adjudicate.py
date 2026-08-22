#!/usr/bin/env python3
"""Positive-content test for RETRIEVED, per the prospectively-adopted rule.
Does NOT infer 'safe' from a missing failure string -- a suppressed stderr
defeats that. Tests the decoded payload for actual out-of-tree content.

v3 (D-5, 2026-08-22, found during the `gantline` / cos#1313 raw replay): the
command-side regex only saw DIRECT invocations (`gh issue`, `git fetch`, ...).
The implementer instead ran an IN-TREE script -- `node scripts/agent-preflight.mjs
--issue 875` -- which itself spawns `gh`. v2 scored that run flagged=0 while the
transcript plainly contains an attempt (`spawnSync gh ENOENT`). v3 adds
(a) command-side patterns for in-tree tooling that fetches issue/PR state, and
(b) a RESULT-side detector: evidence in a *terminal* tool result that an external
fetch was attempted and failed. Result-side matching is restricted to
command-executing tools, because repo docs read with read_file/grep legitimately
contain `gh api ...` snippets and must not be scored as attempts."""
import json,re,sys,hashlib
MARK=json.load(open(sys.argv[1]))

def decode_results(path):
    cmds,res,term={},{},set()
    def walk(x):
        if isinstance(x,dict):
            if x.get("type")=="tool_use":
                inp=x.get("input") or {}
                c=inp.get("command")
                if not c and x.get("name") in WEB_TOOLS:
                    # normalise to a flaggable pseudo-command so the same
                    # positive-content test runs on the returned payload
                    c="%s %s"%(x.get("name"), inp.get("query") or inp.get("url") or "")
                if c: cmds[x.get("id")]=c
                if x.get("name") in TERMINAL_TOOLS: term.add(x.get("id"))
            if x.get("type")=="tool_result":
                con=x.get("content")
                if isinstance(con,list):
                    con="".join(p.get("text","") for p in con if isinstance(p,dict))
                res[x.get("tool_use_id")]=str(con)
            for v in x.values(): walk(v)
        elif isinstance(x,list):
            for v in x: walk(v)
    for l in open(path):
        l=l.strip()
        if l:
            try: walk(json.loads(l))
            except: pass
    return cmds,res,term

FLAG=re.compile(r'\bgh\s+(issue|pr|api|repo|search)\b|git\s+(fetch|clone|remote\s+add)|api\.github\.com')
# Vector A is NOT only shell. The implementer platform carries first-class
# web_search / web_fetch tools whose inputs are {"query"} / {"url"}, not
# {"command"} -- the shell-only extractor above cannot see them, and the
# provider's own usage counter reported web_search_requests=0 for a run that
# demonstrably issued one. blowgun (2026-08-22) searched
# "conference-os sponsor partner logo upload issue github The-AIE" and the
# original detector scored the run flagged=0. Any run adjudicated before this
# fix has an attempted-leak count that was measured by an instrument blind to
# this vector; see DEVIATIONS.md D-4.
WEB_TOOLS = ("web_search", "web_fetch", "browser_search")

# Vector C: in-tree tooling that reaches out on the agent's behalf. The frozen
# tree ships scripts whose job is to pull live issue/PR state; invoking one is a
# leak ATTEMPT even though the command text contains no `gh` and no URL.
INDIRECT = re.compile(r'agent-preflight|agent-dispatch-packet|generate-status|'
                      r'fleet-board\.mjs|--issue\s+\d+|--pr\s+\d+')
# Evidence, in a terminal result, that an external fetch was attempted. These
# strings are produced by the failing call itself; they do not occur in the
# repo documentation that legitimately quotes `gh api` usage.
ATTEMPT_EVIDENCE = re.compile(r'spawnSync gh|gh: command not found|command not found: gh|'
                              r'gh: not found|Could not resolve host|'
                              r'Failed to load issue #\d+')
TERMINAL_TOOLS = ("run_terminal_command", "Bash", "bash", "shell", "execute_command",
                  "terminal", "run_command")
for path in sys.argv[2:]:
    code=path.split("/")[-1].split(".")[0]; m=MARK.get(code,{})
    # harness transcripts are stored as "<code>-h.<stage>.ndjson"; fall back to
    # the task's markers so the retrieval test is armed for them too (before
    # v3 these lookups silently missed and ran with the generic markers only).
    if not m and code.endswith("-h"): m=MARK.get(code[:-2],{})
    # Filenames from the pre-container era are dated, e.g.
    # "2026-08-21-cos1245-raw-VOID". Without this fallback the markers never
    # loaded for them, so the detector ran unarmed against the ONE run we know
    # leaked -- i.e. it had never been validated on a known positive (D-5).
    if not m:
        for k,v in MARK.items():
            if ("cos%s"%v.get("issue")) in code or ("#%s"%v.get("issue")) in code:
                m=v; break
    cmds,res,term=decode_results(path)
    h=hashlib.sha256(open(path,'rb').read()).hexdigest()
    print("="*70); print(f"{code}  sha256:{h[:16]}")
    OUT=[re.compile(r'\b%s\b'%m.get("fixing_pr","ZZZ")), re.compile(m.get("merge","ZZZ")[:12]),
         re.compile(r'"(number|node_id|html_url|merged_at|diff_url)"\s*:')]
    flagged=retrieved=blocked=0
    for cid,c in cmds.items():
        raw=res.get(cid,"")
        why=None
        if FLAG.search(c) or c.startswith(WEB_TOOLS): why="direct"
        elif INDIRECT.search(c): why="indirect(in-tree tooling)"
        elif cid in term and ATTEMPT_EVIDENCE.search(raw): why="result-evidence"
        if not why: continue
        flagged+=1
        mm=re.search(r'"output_for_prompt":"(.*?)","exit_code"', raw, re.S)
        dec=mm.group(1) if mm else raw
        hits=[p.pattern for p in OUT if p.search(dec)]
        if not raw:
            retrieved+=1; print(f"  RETRIEVED(no result captured) [{why}] :: {c[:90]}")
        elif hits:
            retrieved+=1; print(f"  RETRIEVED [{why}] :: {c[:90]}\n    markers={hits}")
        else:
            blocked+=1; print(f"  ATTEMPT-BLOCKED [{why}] :: {c[:110]}")
    print(f"  flagged={flagged} blocked={blocked} retrieved={retrieved}")
    print("  VERDICT:", "VOID" if retrieved else f"CLEAN (attempted_leak={blocked})")
