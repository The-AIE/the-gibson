#!/usr/bin/env node
/**
 * issue-loader.test.mjs — direct unit matrix for the fixed `gh` GraphQL
 * child wall-clock timeout and outcome-mapping contract (#294).
 *
 * Pure Node unit test: injects a fake synchronous process runner into the
 * exported `ghGraphql()` to assert (a) every call always uses the exact
 * fixed spawn options — `timeout: GH_GRAPHQL_TIMEOUT_MS` and
 * `killSignal: "SIGKILL"` — and (b) the exact public outcome mapping for
 * every runner result: successful JSON, ENOENT, another runner error,
 * nonzero exit, ETIMEDOUT, and malformed output after nominal success.
 *
 * Never spawns a real `gh` process, never touches the network, and never
 * calls the real `node:child_process.spawnSync` — the injected runner is a
 * plain function parameter (`ghGraphql`'s optional third argument), not an
 * environment variable, flag, or hidden test hook. Production call sites
 * never pass this argument, so they always get the real `spawnSync`.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { GH_GRAPHQL_TIMEOUT_MS, ghGraphql } from "./issue-loader.mjs";

const QUERY =
  "query($owner: String!, $name: String!, $after: String) { repository(owner: $owner, name: $name) { defaultBranchRef { target { oid } } } }";
const VARS = Object.freeze({ owner: "acme", name: "app", after: null });

const EXPECTED_SPAWN_OPTIONS = Object.freeze({
  encoding: "utf8",
  maxBuffer: 16 * 1024 * 1024,
  timeout: GH_GRAPHQL_TIMEOUT_MS,
  killSignal: "SIGKILL",
});

class ExitCalled extends Error {
  constructor(code) {
    super(`process.exit(${code}) called`);
    this.code = code;
  }
}

/**
 * Run `fn` with `process.exit`/`console.log` intercepted so a call into
 * `incomplete()` (which prints one line and calls `process.exit(3)`) can be
 * observed instead of tearing down the test process. Any exception other
 * than the synthetic ExitCalled propagates normally.
 */
function captureIncomplete(fn) {
  const originalExit = process.exit;
  const originalLog = console.log;
  const lines = [];
  let exitCode = null;
  let exited = false;
  process.exit = (code) => {
    exited = true;
    exitCode = code;
    throw new ExitCalled(code);
  };
  console.log = (...args) => {
    lines.push(args.map(String).join(" "));
  };
  try {
    fn();
  } catch (e) {
    if (!(e instanceof ExitCalled)) {
      process.exit = originalExit;
      console.log = originalLog;
      throw e;
    }
  } finally {
    process.exit = originalExit;
    console.log = originalLog;
  }
  return { exited, exitCode, lines };
}

function assertExactSpawnOptions(captured) {
  assert.equal(captured.cmd, "gh", "spawn command must be exactly 'gh'");
  assert.ok(Array.isArray(captured.args), "spawn args must be an array");
  assert.deepEqual(
    captured.opts,
    EXPECTED_SPAWN_OPTIONS,
    "spawn options must be exactly {encoding, maxBuffer, timeout, killSignal} with the fixed timeout and SIGKILL"
  );
}

describe("ghGraphql — fixed spawn options (#294)", () => {
  it("every call passes the exact timeout and SIGKILL options to the runner", () => {
    let captured = null;
    const spawnFn = (cmd, args, opts) => {
      captured = { cmd, args, opts };
      return {
        status: 0,
        stdout: JSON.stringify({ data: { ok: true } }),
        stderr: "",
        error: null,
        signal: null,
      };
    };
    ghGraphql(QUERY, VARS, spawnFn);
    assertExactSpawnOptions(captured);
    assert.equal(GH_GRAPHQL_TIMEOUT_MS, 30_000, "the fixed ceiling must be 30_000ms");
  });

  it("passes the fixed options through even on a hostile/malformed vars shape", () => {
    let captured = null;
    const spawnFn = (cmd, args, opts) => {
      captured = { cmd, args, opts };
      return { status: 0, stdout: "{}", stderr: "", error: null, signal: null };
    };
    ghGraphql(QUERY, { owner: "acme", name: "app", after: "cursor-1", label: "x" }, spawnFn);
    assertExactSpawnOptions(captured);
  });
});

describe("ghGraphql — outcome mapping (#294)", () => {
  it("successful JSON: returns the parsed payload and never exits", () => {
    const payload = { data: { repository: { defaultBranchRef: { target: { oid: "a".repeat(40) } } } } };
    let captured = null;
    const spawnFn = (cmd, args, opts) => {
      captured = { cmd, args, opts };
      return { status: 0, stdout: JSON.stringify(payload), stderr: "", error: null, signal: null };
    };
    const result = ghGraphql(QUERY, VARS, spawnFn);
    assert.deepEqual(result, payload);
    assertExactSpawnOptions(captured);
  });

  it("ENOENT: INCOMPLETE: API_FAILURE: GH_NOT_FOUND, exit 3", () => {
    const spawnFn = () => ({
      status: null,
      stdout: null,
      stderr: null,
      signal: null,
      error: Object.assign(new Error("spawnSync gh ENOENT"), { code: "ENOENT" }),
    });
    const { exited, exitCode, lines } = captureIncomplete(() => ghGraphql(QUERY, VARS, spawnFn));
    assert.equal(exited, true);
    assert.equal(exitCode, 3);
    assert.deepEqual(lines, ["INCOMPLETE: API_FAILURE: GH_NOT_FOUND"]);
  });

  it("another runner error (not ENOENT/ETIMEDOUT): INCOMPLETE: API_FAILURE: GH_EXIT, exit 3, no leak", () => {
    const spawnFn = () => ({
      status: null,
      stdout: "hostile-provider-stdout-should-not-leak",
      stderr: "hostile-provider-stderr-should-not-leak",
      signal: null,
      error: Object.assign(new Error("spawnSync gh EACCES"), { code: "EACCES" }),
    });
    const { exited, exitCode, lines } = captureIncomplete(() => ghGraphql(QUERY, VARS, spawnFn));
    assert.equal(exited, true);
    assert.equal(exitCode, 3);
    assert.deepEqual(lines, ["INCOMPLETE: API_FAILURE: GH_EXIT"]);
    assert.ok(!lines.join("\n").includes("hostile"));
  });

  it("runner error with no .code at all: still INCOMPLETE: API_FAILURE: GH_EXIT, exit 3", () => {
    const spawnFn = () => ({
      status: null,
      stdout: null,
      stderr: null,
      signal: null,
      error: new Error("generic spawn failure"),
    });
    const { exited, exitCode, lines } = captureIncomplete(() => ghGraphql(QUERY, VARS, spawnFn));
    assert.equal(exited, true);
    assert.equal(exitCode, 3);
    assert.deepEqual(lines, ["INCOMPLETE: API_FAILURE: GH_EXIT"]);
  });

  it("nonzero exit status (no runner error object): INCOMPLETE: API_FAILURE: GH_EXIT, exit 3, no leak", () => {
    const spawnFn = () => ({
      status: 1,
      stdout: "",
      stderr: "hostile-provider-stderr-should-not-leak",
      signal: null,
      error: null,
    });
    const { exited, exitCode, lines } = captureIncomplete(() => ghGraphql(QUERY, VARS, spawnFn));
    assert.equal(exited, true);
    assert.equal(exitCode, 3);
    assert.deepEqual(lines, ["INCOMPLETE: API_FAILURE: GH_EXIT"]);
    assert.ok(!lines.join("\n").includes("hostile"));
  });

  it("ETIMEDOUT: INCOMPLETE: API_TIMEOUT, exit 3 — ignores status/signal/stdout/stderr entirely", () => {
    const spawnFn = () => ({
      status: null,
      signal: "SIGKILL",
      stdout: "OK DAG critical-path capacity blocker-first HOSTILE_STDOUT_SENTINEL",
      stderr: "HOSTILE_STDERR_SENTINEL credential=super-secret-token /Users/host/path",
      error: Object.assign(new Error("spawnSync gh ETIMEDOUT"), { code: "ETIMEDOUT" }),
    });
    const { exited, exitCode, lines } = captureIncomplete(() => ghGraphql(QUERY, VARS, spawnFn));
    assert.equal(exited, true);
    assert.equal(exitCode, 3);
    assert.deepEqual(lines, ["INCOMPLETE: API_TIMEOUT"]);
    const joined = lines.join("\n");
    for (const sentinel of [
      "HOSTILE_STDOUT_SENTINEL",
      "HOSTILE_STDERR_SENTINEL",
      "credential",
      "/Users/host/path",
      "OK",
      "DAG",
      "critical-path",
      "capacity",
      "blocker-first",
    ]) {
      assert.ok(!joined.includes(sentinel), `must not leak: ${sentinel}`);
    }
  });

  it("ETIMEDOUT takes priority even when status/signal/stdout look like nominal success", () => {
    // Literal contract order: result.error?.code === "ETIMEDOUT" is checked
    // before status, signal, stdout, or stderr — a timed-out child must
    // never fall through into the JSON-shape/success branch.
    const spawnFn = () => ({
      status: 0,
      signal: null,
      stdout: JSON.stringify({ data: { ok: true } }),
      stderr: "",
      error: { code: "ETIMEDOUT" },
    });
    const { exited, exitCode, lines } = captureIncomplete(() => ghGraphql(QUERY, VARS, spawnFn));
    assert.equal(exited, true);
    assert.equal(exitCode, 3);
    assert.deepEqual(lines, ["INCOMPLETE: API_TIMEOUT"]);
  });

  it("malformed output after nominal success (status 0, invalid JSON): INCOMPLETE: INVALID_JSON, exit 3", () => {
    const spawnFn = () => ({
      status: 0,
      stdout: "{not valid json",
      stderr: "",
      signal: null,
      error: null,
    });
    const { exited, exitCode, lines } = captureIncomplete(() => ghGraphql(QUERY, VARS, spawnFn));
    assert.equal(exited, true);
    assert.equal(exitCode, 3);
    assert.deepEqual(lines, ["INCOMPLETE: INVALID_JSON"]);
  });
});
