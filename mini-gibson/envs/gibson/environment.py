from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .schema import Action, Observation, Task, TerminalState, Verification

Tool = Callable[[dict[str, Any]], dict[str, Any]]
Verifier = Callable[[Task, list[dict[str, Any]]], Verification]


class GibsonEnv:
    """Environment boundary for benchmark/demo/training rollouts.

    Tool implementations and verification are injected so this class does not
    silently grant shell/filesystem authority.
    """

    def __init__(self, tools: dict[str, Tool], verifier: Verifier):
        self._tools = tools
        self._verifier = verifier
        self._task: Task | None = None
        self._events: list[dict[str, Any]] = []
        self._repair_count = 0
        self._done = False

    def reset(self, task: Task) -> Observation:
        if task.max_repairs < 0:
            raise ValueError("max_repairs must be non-negative")
        unknown = set(task.allowed_tools) - set(self._tools)
        if unknown:
            raise ValueError(f"task references unavailable tools: {sorted(unknown)}")
        self._task = task
        self._events = []
        self._repair_count = 0
        self._done = False
        return Observation(task.task_id, "SCOUT", task.issue)

    def step(self, action: Action) -> tuple[Observation, bool]:
        task = self._require_task()
        if self._done:
            raise RuntimeError("episode is terminal")
        if action.tool not in task.allowed_tools:
            event = {"kind": "tool_error", "error": "PERMISSION_DENIED", "tool": action.tool}
            self._events.append(event)
            return Observation(task.task_id, "TOOL", "tool denied", event, self._events.copy()), False
        tool = self._tools.get(action.tool)
        if tool is None:
            event = {"kind": "tool_error", "error": "UNKNOWN_TOOL", "tool": action.tool}
            self._events.append(event)
            return Observation(task.task_id, "TOOL", "unknown tool", event, self._events.copy()), False
        try:
            result = tool(action.arguments)
            event = {"kind": "tool_result", "tool": action.tool, "result": result}
        except Exception as exc:  # tool boundary normalizes failures
            event = {"kind": "tool_error", "tool": action.tool, "error": type(exc).__name__, "message": str(exc)}
        self._events.append(event)
        label = "tool error" if event["kind"] == "tool_error" else "tool completed"
        return Observation(task.task_id, "TOOL", label, event, self._events.copy()), False

    def note_repair(self) -> None:
        task = self._require_task()
        self._repair_count += 1
        self._events.append({"kind": "repair", "count": self._repair_count})
        if self._repair_count > task.max_repairs:
            self._done = True
            raise RuntimeError("repair budget exceeded")

    def verify(self) -> Verification:
        task = self._require_task()
        result = self._verifier(task, self._events.copy())
        if result.terminal_state == TerminalState.VERIFIED:
            required = (
                result.requirement_satisfied
                and result.tests_pass
                and result.verifier_pass
                and not result.unrelated_changes
                and not result.unresolved_tool_errors
            )
            if not required:
                raise ValueError("verifier attempted unsupported VERIFIED state")
        self._done = True
        return result

    @property
    def events(self) -> tuple[dict[str, Any], ...]:
        return tuple(self._events)

    def _require_task(self) -> Task:
        if self._task is None:
            raise RuntimeError("reset(task) must be called first")
        return self._task
