#!/usr/bin/env python3
"""Positive-content test for RETRIEVED, per the prospectively-adopted rule.
Does NOT infer 'safe' from a missing failure string -- a suppressed stderr
defeats that. Tests the decoded payload for actual out-of-tree content."""
import json,re,sys,hashlib
MARK=json.load(open(sys.argv[1]))

def decode_results(path):
    cmds,res={},{}
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
    return cmds,res

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
for path in sys.argv[2:]:
    code=path.split("/")[-1].split(".")[0]; m=MARK.get(code,{})
    cmds,res=decode_results(path)
    h=hashlib.sha256(open(path,'rb').read()).hexdigest()
    print("="*70); print(f"{code}  sha256:{h[:16]}")
    OUT=[re.compile(r'\b%s\b'%m.get("fixing_pr","ZZZ")), re.compile(m.get("merge","ZZZ")[:12]),
         re.compile(r'"(number|node_id|html_url|merged_at|diff_url)"\s*:')]
    flagged=retrieved=blocked=0
    for cid,c in cmds.items():
        if not (FLAG.search(c) or c.startswith(WEB_TOOLS)): continue
        flagged+=1
        raw=res.get(cid,"")
        mm=re.search(r'"output_for_prompt":"(.*?)","exit_code"', raw, re.S)
        dec=mm.group(1) if mm else raw
        hits=[p.pattern for p in OUT if p.search(dec)]
        if not raw:
            retrieved+=1; print(f"  RETRIEVED(no result captured) :: {c[:90]}")
        elif hits:
            retrieved+=1; print(f"  RETRIEVED :: {c[:90]}\n    markers={hits}")
        else:
            blocked+=1
    print(f"  flagged={flagged} blocked={blocked} retrieved={retrieved}")
    print("  VERDICT:", "VOID" if retrieved else f"CLEAN (attempted_leak={blocked})")
