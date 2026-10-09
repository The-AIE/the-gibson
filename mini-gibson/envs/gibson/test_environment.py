from .environment import GibsonEnv
from .reward import evidence_reward
from .schema import Action, Task, TerminalState, Verification


def fake_read(args):
    return {"path": args["path"], "content": "ok"}


def good_verifier(task, events):
    v = Verification(
        terminal_state=TerminalState.VERIFIED,
        requirement_satisfied=True,
        tests_pass=True,
        regression_test_added=True,
        lint_pass=True,
        typecheck_pass=True,
        unrelated_changes=False,
        unresolved_tool_errors=False,
        verifier_pass=True,
    )
    v.reward_components = evidence_reward(v)
    return v


def test_verified_episode():
    env = GibsonEnv({"read_file": fake_read}, good_verifier)
    obs = env.reset(Task("smoke", ".", "inspect", ("read_file",)))
    assert obs.phase == "SCOUT"
    obs, done = env.step(Action("read_file", {"path": "README.md"}))
    assert not done
    assert obs.tool_result["kind"] == "tool_result"
    result = env.verify()
    assert result.terminal_state == TerminalState.VERIFIED
    assert result.reward > 0


def test_denied_tool_is_evidence():
    env = GibsonEnv({"read_file": fake_read}, good_verifier)
    env.reset(Task("smoke", ".", "inspect", ("read_file",)))
    obs, _ = env.step(Action("write_file", {"path": "x"}))
    assert obs.tool_result["error"] == "PERMISSION_DENIED"
