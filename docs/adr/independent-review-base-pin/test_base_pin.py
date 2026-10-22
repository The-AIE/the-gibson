"""Unit check for the base-pin patch. Run: python3 -I test_base_pin.py <patched controller>."""
import importlib.util, hashlib, sys
spec = importlib.util.spec_from_file_location("ctl", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

A="a"*40; B="b"*40; H="c"*40; D="d"*40
def pull(base): return {"head":{"sha":H,"repo":{"full_name":"o/r"}},"base":{"sha":base,"ref":"main"},"state":"open","draft":False}
compare = {"complete":True,"commits":[{"sha":H}],"files":[{"filename":"src/x.ts","status":"modified"}],"diff":"--- a\n+++ b\n","status":"ahead"}
pinned = m._snapshot(pull(A), compare, ["routine"], [])
assert pinned["diff_sha256"] == hashlib.sha256(b"--- a\n+++ b\n").hexdigest(), "hash pinned"
assert pinned["base"] == A

class FakeGH:
    def __init__(self, resp): self.resp=resp; self.calls=[]
    def compare(self, repo, base, head):
        self.calls.append((base, head))
        if isinstance(self.resp, Exception): raise self.resp
        return self.resp

def fresh_with(base=B, **over):
    f = m._snapshot(pull(base), compare, ["routine"], []); f.update(over); return f

adv_ok = {"complete":True,"status":"ahead","files":[{"filename":"src/other.ts","status":"modified"}],"commits":[],"diff":"x"}
gh = FakeGH(adv_ok)
assert m._base_only_move(gh, "o/r", pinned, fresh_with()) is True, "base-only, disjoint -> accept"
assert gh.calls == [(A, B)], gh.calls
# overlapping path on main's advance -> refuse
adv_overlap = dict(adv_ok, files=[{"filename":"src/x.ts","status":"modified"}])
assert m._base_only_move(FakeGH(adv_overlap), "o/r", pinned, fresh_with()) is False
# rename whose previous_filename is a reviewed path -> refuse
adv_ren = dict(adv_ok, files=[{"filename":"src/y.ts","status":"renamed","previous_filename":"src/x.ts"}])
assert m._base_only_move(FakeGH(adv_ren), "o/r", pinned, fresh_with()) is False
# main force-pushed / diverged -> refuse
assert m._base_only_move(FakeGH(dict(adv_ok, status="diverged")), "o/r", pinned, fresh_with()) is False
# incomplete compare / unreadable -> refuse
assert m._base_only_move(FakeGH(dict(adv_ok, complete=False)), "o/r", pinned, fresh_with()) is False
assert m._base_only_move(FakeGH(m.IncompleteRead("x")), "o/r", pinned, fresh_with()) is False
# head moved too -> refuse without calling compare
gh2 = FakeGH(adv_ok)
assert m._base_only_move(gh2, "o/r", pinned, fresh_with(head=D)) is False and gh2.calls == []
# patch content changed (e.g. different diff text at same head is impossible but guard) -> refuse
assert m._base_only_move(FakeGH(adv_ok), "o/r", pinned, fresh_with(diff_sha256="0"*64)) is False
# labels changed -> refuse
assert m._base_only_move(FakeGH(adv_ok), "o/r", pinned, fresh_with(labels=["x"])) is False
# identical snapshot (base unchanged) is not a "move"
assert m._base_only_move(FakeGH(adv_ok), "o/r", pinned, dict(pinned)) is False
# interpret_compare carries status through only when complete
ic = m.interpret_compare({"commits":[{"sha":H,"commit":{"message":"m"},"author":{"login":"a"},"committer":{"login":"a"}}],"files":[{"filename":"f","status":"modified"}],"total_commits":1,"status":"ahead"}, "diff")
assert ic["complete"] and ic["status"] == "ahead"
print("ALL ASSERTIONS PASSED")
