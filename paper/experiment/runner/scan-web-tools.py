#!/usr/bin/env python3
"""Count ACTUAL web_search/web_fetch tool INVOCATIONS (type=tool_use), not
mentions of the tool name in a system prompt / tool listing."""
import json,sys
def scan(path):
    calls=[]
    for l in open(path,errors="replace"):
        l=l.strip()
        if not l: continue
        try: o=json.loads(l)
        except: continue
        def walk(x):
            if isinstance(x,dict):
                if x.get("type")=="tool_use" and x.get("name") in ("web_search","web_fetch","browser_search"):
                    calls.append((x.get("name"), json.dumps(x.get("input"))[:200]))
                for v in x.values(): walk(v)
            elif isinstance(x,list):
                for v in x: walk(v)
        walk(o)
    return calls
for p in sys.argv[1:]:
    c=scan(p)
    if c:
        print(f"{p}: {len(c)} invocation(s)")
        for n,i in c: print(f"    {n} {i}")
