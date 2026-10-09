from __future__ import annotations

from .schema import Verification


def evidence_reward(v: Verification) -> dict[str, float]:
    """Initial transparent reward decomposition.

    Weights are experimental and MUST be versioned/frozen before comparative
    RL claims. Benchmark task-resolution remains the primary metric.
    """
    return {
        "requirement": 10.0 if v.requirement_satisfied else -10.0,
        "tests": 4.0 if v.tests_pass else -5.0,
        "regression": 2.0 if v.regression_test_added is True else 0.0,
        "lint": 1.0 if v.lint_pass is True else 0.0,
        "typecheck": 1.0 if v.typecheck_pass is True else 0.0,
        "scope": -3.0 if v.unrelated_changes else 1.0,
        "tool_errors": -3.0 if v.unresolved_tool_errors else 1.0,
        "verifier": 3.0 if v.verifier_pass else -5.0,
    }
