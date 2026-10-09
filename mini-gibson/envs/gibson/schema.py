from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class TerminalState(str, Enum):
    VERIFIED = "VERIFIED"
    PARTIALLY_VERIFIED = "PARTIALLY_VERIFIED"
    FAILED = "FAILED"
    ABORTED = "ABORTED"


@dataclass(frozen=True)
class Task:
    task_id: str
    repo_path: str
    issue: str
    allowed_tools: tuple[str, ...]
    max_repairs: int = 3


@dataclass(frozen=True)
class Action:
    tool: str
    arguments: dict[str, Any]


@dataclass
class Observation:
    task_id: str
    phase: str
    message: str
    tool_result: dict[str, Any] | None = None
    evidence: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class Verification:
    terminal_state: TerminalState
    requirement_satisfied: bool
    tests_pass: bool
    regression_test_added: bool | None
    lint_pass: bool | None
    typecheck_pass: bool | None
    unrelated_changes: bool
    unresolved_tool_errors: bool
    verifier_pass: bool
    reward_components: dict[str, float] = field(default_factory=dict)

    @property
    def reward(self) -> float:
        return sum(self.reward_components.values())
