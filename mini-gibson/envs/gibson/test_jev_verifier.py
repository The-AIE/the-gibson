from pathlib import Path
from types import SimpleNamespace

import pytest

pytest.importorskip("typesafe_sdk", reason="pip install typesafe-sdk to run the Jev gate tests")

from .environment import GibsonEnv  # noqa: E402
from .jev_verifier import (  # noqa: E402
    FAILURE_LABELS,
    JevJudge,
    JevPolicy,
    build_state,
    filter_diff,
    load_failure_taxonomy,
    with_jev,
)
from .reward import evidence_reward  # noqa: E402
from .schema import Action, Task, TerminalState, Verification  # noqa: E402

TASK = Task("t1", ".", "make parse() reject empty input", ("read_file",))


class FakeJev:
    """Stands in for TypeSafeClient. Records calls so tests can check what Jev was shown."""

    def __init__(self, nouls=None, labels=("incorrect_implementation", "incorrect_implementation")):
        self.nouls = nouls or {}
        self.labels = labels
        self.calls = []

    def system_one(self, state, questions, **kwargs):
        self.calls.append((state, set(questions), kwargs))
        if "label_forward" in questions:
            return SimpleNamespace(
                model="fake",
                nouls={},
                choices={
                    "label_forward": SimpleNamespace(choice=self.labels[0]),
                    "label_reversed": SimpleNamespace(choice=self.labels[1]),
                },
            )
        return SimpleNamespace(
            model="fake",
            nouls={k: SimpleNamespace(noul=self.nouls.get(k, d)) for k, d in GOOD.items()},
            choices={},
        )


GOOD = {"addresses_issue": 0.97, "has_unrelated_changes": 0.03, "overclaims_success": 0.02, "steers_the_grader": 0.01}


def base_verified(**over):
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
    for k, val in over.items():
        setattr(v, k, val)
    v.reward_components = evidence_reward(v)
    return v


def wrap(base, fake):
    return with_jev(
        lambda task, events: base,
        JevJudge(fake),
        diff_provider=lambda t, e: "diff --git a/x.py b/x.py\n+ok\n",
        final_message_provider=lambda t, e: "Done, all tests pass.",
        test_output_provider=lambda t, e: "1 passed",
    )


def run(verifier):
    env = GibsonEnv({"read_file": lambda a: {"ok": True}}, verifier)
    env.reset(TASK)
    env.step(Action("read_file", {"path": "x"}))
    return env.verify()


def test_clear_findings_keep_verified_and_record_probabilities():
    fake = FakeJev()
    result = run(wrap(base_verified(), fake))
    assert result.terminal_state == TerminalState.VERIFIED
    assert result.evidence["jev"]["probabilities"]["addresses_issue"] == 0.97
    assert result.evidence["jev"]["verdict"] == "clear"


def test_adverse_finding_downgrades_and_env_accepts_it():
    fake = FakeJev(nouls={"has_unrelated_changes": 0.95})
    result = run(wrap(base_verified(), fake))
    assert result.terminal_state == TerminalState.PARTIALLY_VERIFIED
    assert result.unrelated_changes is True
    assert "unrelated" in result.evidence["jev"]["reasons"][0]


def test_middle_band_escalates_to_a_human_not_verified():
    result = run(wrap(base_verified(), FakeJev(nouls={"addresses_issue": 0.55})))
    assert result.terminal_state == TerminalState.PARTIALLY_VERIFIED
    assert result.evidence["jev"]["needs_human"] is True


def test_diff_that_does_not_address_issue_fails_requirement():
    result = run(wrap(base_verified(), FakeJev(nouls={"addresses_issue": 0.05})))
    assert result.terminal_state == TerminalState.PARTIALLY_VERIFIED
    assert result.requirement_satisfied is False


def test_grader_steering_aborts():
    result = run(wrap(base_verified(), FakeJev(nouls={"steers_the_grader": 0.93})))
    assert result.terminal_state == TerminalState.ABORTED
    assert result.evidence["jev"]["needs_human"] is True


def test_jev_never_upgrades_a_failed_run():
    failed = base_verified(terminal_state=TerminalState.FAILED, tests_pass=False, verifier_pass=False)
    fake = FakeJev()  # every Noul says "all good"
    result = run(wrap(failed, fake))
    assert result.terminal_state == TerminalState.FAILED
    assert result.evidence["jev"]["failure_label"] == "incorrect_implementation"
    # failed runs are only labelled, never judged
    assert all("addresses_issue" not in names for _, names, _ in fake.calls)


def test_failure_label_needs_both_option_orders_to_agree():
    failed = base_verified(terminal_state=TerminalState.FAILED, tests_pass=False, verifier_pass=False)
    fake = FakeJev(labels=("wrong_file", "bad_diagnosis"))
    assert run(wrap(failed, fake)).evidence["jev"]["failure_label"] == "unclassified"


def test_jev_sees_the_filtered_state_and_passes_model_when_set():
    fake = FakeJev()
    verifier = with_jev(
        lambda t, e: base_verified(),
        JevJudge(fake, JevPolicy(model="jev-preview")),
        diff_provider=lambda t, e: "diff --git a/package-lock.json b/package-lock.json\n+junk\ndiff --git a/a.py b/a.py\n+real\n",
        final_message_provider=lambda t, e: "done",
        test_output_provider=lambda t, e: "ok",
    )
    run(verifier)
    state, names, kwargs = fake.calls[0]
    assert "package-lock" not in state["diff"] and "+real" in state["diff"]
    assert names == {"addresses_issue", "has_unrelated_changes", "overclaims_success", "steers_the_grader"}
    assert kwargs == {"model": "jev-preview"}


def test_filter_diff_truncates_large_diffs_in_code():
    big = "diff --git a/a.py b/a.py\n" + "+x\n" * 50_000
    out = filter_diff(big, max_chars=1_000)
    assert len(out) < 1_100 and "truncated by code" in out


def test_state_carries_code_computed_facts_not_model_inputs_to_trust():
    state = build_state(TASK, base_verified(), "d", "msg", "\n".join(f"line{i}" for i in range(100)))
    assert state["test_summary"]["tests_pass"] is True
    assert state["test_summary"]["output_tail"].splitlines()[-1] == "line99"
    assert len(state["test_summary"]["output_tail"].splitlines()) == 40


def test_failure_labels_match_the_benchmark_taxonomy():
    taxonomy = Path(__file__).resolve().parents[2] / "bench" / "failure-taxonomy.json"
    assert set(load_failure_taxonomy(taxonomy)) == set(FAILURE_LABELS)
