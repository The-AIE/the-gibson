#!/usr/bin/env python3
"""Positive-content test for RETRIEVED, per the prospectively-adopted rule.
Does NOT infer 'safe' from a missing failure string -- a suppressed stderr
defeats that. Tests the decoded payload for actual out-of-tree content.

v4 (D-6, 2026-08-24, found during the `nettler` / cos#1214 raw replay). Three
gaps, all of the same species: the detector was keyed to *structure* -- a block
whose "type" is exactly "tool_use" -- and every new encoding walked past it.

  (a) WIRE ENCODING. The provider emits its own server-side tools as
      {"type":"server_tool_use", "name":"web_search"} with results as
      {"type":"web_search_tool_result"}. v3 matched only type=="tool_use"
      /type=="tool_result", so it scored `nettler` flagged=0 while the
      transcript plainly contains a web_search and ten returned URLs. Note
      `blowgun` emitted the SAME vector as a plain tool_use and WAS caught --
      so one experiment contains both encodings, and v2/v3 covered one of them.
  (b) SUBAGENT REGION. `spawn_subagent` runs a child session whose tool calls
      never appear in the parent transcript; only a coarse "Tools used: ..."
      progress line does, and only for children that happened to be polled
      while running. 15 spawns across 6 transcripts have never been directly
      observed by any version of this detector. v4 cannot see them either --
      it REPORTS the unobserved region so no run can silently claim coverage.
  (c) search_tool. A tool-catalogue probe (returns the session's MCP list).
      It cannot reach the network, so it is reported but NOT counted as an
      attempted leak; its payload is still marker-tested in case that changes.

The structural lesson is recorded in DEVIATIONS.md D-6: four detector revisions
have each closed one encoding of one vector. v4 therefore adds a
STRUCTURE-INDEPENDENT total scan -- the raw transcript bytes are searched for
this task's leak markers regardless of how any block is shaped -- and prints
every hit for hand adjudication. That check cannot be walked past by an
encoding this file has not anticipated.

v3 (D-5) and v2 (D-4) history retained below."""
import json,re,sys,hashlib
MARK=json.load(open(sys.argv[1]))

# Vector A is NOT only shell. The implementer platform carries first-class
# web_search / web_fetch tools whose inputs are {"query"} / {"url"}, not
# {"command"}. See DEVIATIONS.md D-4 (blowgun) and D-6 (nettler).
WEB_TOOLS = ("web_search", "web_fetch", "browser_search")
# Provider-side server tools: same vector, different block type (D-6a).
SERVER_TOOL_BLOCKS = ("server_tool_use",)
SERVER_RESULT_BLOCKS = ("web_search_tool_result", "web_fetch_tool_result",
                        "server_tool_result")
# Catalogue probes: cannot reach out, reported not counted (D-6c).
PROBE_TOOLS = ("search_tool",)
TERMINAL_TOOLS = ("run_terminal_command", "Bash", "bash", "shell", "execute_command",
                  "terminal", "run_command")

def decode_results(path):
    cmds,res,term,probe,spawns,subtools={},{},set(),set(),[],set()
    def walk(x):
        if isinstance(x,dict):
            t=x.get("type")
            if t in ("tool_use",)+SERVER_TOOL_BLOCKS:
                inp=x.get("input") or {}
                name=x.get("name")
                c=inp.get("command")
                if not c and (name in WEB_TOOLS or t in SERVER_TOOL_BLOCKS
                              or name in PROBE_TOOLS):
                    # normalise to a flaggable pseudo-command so the same
                    # positive-content test runs on the returned payload
                    c="%s %s"%(name, inp.get("query") or inp.get("url") or "")
                if c: cmds[x.get("id")]=c
                if name in TERMINAL_TOOLS: term.add(x.get("id"))
                if name in PROBE_TOOLS: probe.add(x.get("id"))
                if name=="spawn_subagent":
                    spawns.append((inp.get("description") or "")[:60])
            if t in ("tool_result",)+SERVER_RESULT_BLOCKS:
                con=x.get("content")
                if isinstance(con,list):
                    con="".join(p.get("text","") if isinstance(p,dict) and "text" in p
                                else json.dumps(p) for p in con)
                res[x.get("tool_use_id")]=str(con)
            for v in x.values(): walk(v)
        elif isinstance(x,list):
            for v in x: walk(v)
    raw=open(path,errors='replace').read()
    for l in raw.splitlines():
        l=l.strip()
        if l:
            try: walk(json.loads(l))
            except: pass
    for m in re.finditer(r'Tools used: ([^\\"\n]+)', raw):
        for t in m.group(1).split(","): subtools.add(t.strip())
    return cmds,res,term,probe,spawns,subtools,raw

FLAG=re.compile(r'\bgh\s+(issue|pr|api|repo|search)\b|git\s+(fetch|clone|remote\s+add)|api\.github\.com')
# Vector C: in-tree tooling that reaches out on the agent's behalf (D-5).
INDIRECT = re.compile(r'agent-preflight|agent-dispatch-packet|generate-status|'
                      r'fleet-board\.mjs|--issue\s+\d+|--pr\s+\d+')
# Evidence, in a terminal result, that an external fetch was attempted.
ATTEMPT_EVIDENCE = re.compile(r'spawnSync gh|gh: command not found|command not found: gh|'
                              r'gh: not found|Could not resolve host|'
                              r'Failed to load issue #\d+')

for path in sys.argv[2:]:
    code=path.split("/")[-1].split(".")[0]; m=MARK.get(code,{})
    if not m and code.endswith("-h"): m=MARK.get(code[:-2],{})
    if not m:
        for k,v in MARK.items():
            if ("cos%s"%v.get("issue")) in code or ("#%s"%v.get("issue")) in code:
                m=v; break
    cmds,res,term,probe,spawns,subtools,raw=decode_results(path)
    h=hashlib.sha256(open(path,'rb').read()).hexdigest()
    print("="*70); print(f"{code}  sha256:{h[:16]}")
    OUT=[re.compile(r'\b%s\b'%m.get("fixing_pr","ZZZ")), re.compile(m.get("merge","ZZZ")[:12]),
         re.compile(r'"(number|node_id|html_url|merged_at|diff_url)"\s*:')]
    flagged=retrieved=blocked=probed=0
    for cid,c in cmds.items():
        rawres=res.get(cid,"")
        why=None
        if cid in probe: why="catalogue-probe"
        elif FLAG.search(c) or c.startswith(WEB_TOOLS): why="direct"
        elif INDIRECT.search(c): why="indirect(in-tree tooling)"
        elif cid in term and ATTEMPT_EVIDENCE.search(rawres): why="result-evidence"
        if not why: continue
        mm=re.search(r'"output_for_prompt":"(.*?)","exit_code"', rawres, re.S)
        dec=mm.group(1) if mm else rawres
        hits=[p.pattern for p in OUT if p.search(dec)]
        if why=="catalogue-probe":
            probed+=1
            if hits:
                retrieved+=1; print(f"  RETRIEVED [{why}] :: {c[:90]}\n    markers={hits}")
            else:
                print(f"  PROBE(not counted) :: {c[:110]}")
            continue
        flagged+=1
        if not rawres:
            retrieved+=1; print(f"  RETRIEVED(no result captured) [{why}] :: {c[:90]}")
        elif hits:
            retrieved+=1; print(f"  RETRIEVED [{why}] :: {c[:90]}\n    markers={hits}")
        else:
            blocked+=1; print(f"  ATTEMPT-BLOCKED [{why}] :: {c[:110]}")
    # --- structure-independent total scan (D-6). Cannot be walked past by an
    # encoding this file has not anticipated. Advisory: prints for hand
    # adjudication, does not by itself set the verdict.
    adv=[]
    for pat,label in ((r'\b%s\b'%m.get("fixing_pr","ZZZ"),"fixing_pr"),
                      (m.get("merge","ZZZ")[:12],"merge_sha")):
        for mt in re.finditer(pat,raw):
            adv.append((label,raw[max(0,mt.start()-90):mt.end()+90].replace("\n"," ")))
    if adv:
        print(f"  !! RAW-SCAN: {len(adv)} marker occurrence(s) in transcript bytes -- HAND ADJUDICATE")
        for label,ctx in adv[:6]: print(f"     [{label}] ...{ctx}...")
    if spawns:
        print(f"  ?? UNOBSERVED REGION: {len(spawns)} subagent session(s); their tool calls are")
        print(f"     NOT in this transcript. Coarse evidence only -- tools seen in progress")
        print(f"     lines: {sorted(subtools) or 'none captured'}")
        for d in spawns: print(f"       - {d}")
    print(f"  flagged={flagged} blocked={blocked} retrieved={retrieved} probes={probed} "
          f"subagents={len(spawns)} raw_marker_hits={len(adv)}")
    print("  VERDICT:", "VOID" if retrieved else f"CLEAN (attempted_leak={blocked})")
