#!/usr/bin/env bash
# tooling-readiness.test.sh — executable adoption, control and freshness witnesses.
# Run through run-all.sh or the fleet's isolated Gibson gate helper.
set -euo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
node --input-type=module - "$SCRIPT_DIR/../gibson-verify.mjs" "$SCRIPT_DIR/../gate.sh" <<'NODE'
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, chmodSync, existsSync, copyFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
const [verify, gate] = process.argv.slice(2);
const root = mkdtempSync(join(tmpdir(), 'tooling-readiness-'));
let passed = 0;
function run(command, args, cwd) {
  const r = spawnSync(command, args, { cwd, encoding: 'utf8', timeout: 20000 });
  return { code: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}
function git(repo, ...args) {
  const r = run('git', ['-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', ...args], repo);
  assert.equal(r.code, 0, r.stderr); return r.stdout.trim();
}
function put(repo, p, text) { mkdirSync(join(repo, p, '..'), { recursive: true }); writeFileSync(join(repo, p), text); }
function commit(repo) { git(repo, 'add', '.'); git(repo, '-c', 'user.name=Tooling fixture', '-c', 'user.email=tooling@localhost', 'commit', '-qm', 'fixture'); }
function fixture(name) {
  const repo = join(root, name); mkdirSync(repo);
  git(repo, 'init', '-q', '-b', 'main'); put(repo, 'seed.txt', 'base\n'); commit(repo);
  git(repo, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  put(repo, '.gitignore', '.gibson-receipts/\n.gibson-baseline.json\n');
  put(repo, 'gate', '#!/bin/sh\nprintf "product gate ran\\n"\n'); chmodSync(join(repo, 'gate'), 0o755);
  put(repo, 'src/app.js', 'const value = 1;\n');
  put(repo, '.agents/tooling-controls/valid.js', 'const value = 1;\n');
  put(repo, '.agents/tooling-controls/invalid.js', 'const = ;\n');
  const profile = {
    command: [process.execPath, '--check', '{file}'],
    version: { command: [process.execPath, '--version'], expected: process.version },
    config: ['seed.txt'], sources: ['src/', '.agents/gate.json'],
    controls: { positive: '.agents/tooling-controls/valid.js', negative: '.agents/tooling-controls/invalid.js', exit: 1, diagnostic: 'SyntaxError' },
  };
  const config = {
    generate: '', typecheck: '', lint: '', test: './gate', build: '',
    tooling: { schema: 'gibson.tooling/v1', mode: 'required', profiles: {
      javascript: structuredClone(profile), formatting: structuredClone(profile),
      python: { not_applicable: 'No Python' }, shell: { not_applicable: 'No shell files' }, actions: { not_applicable: 'No workflows' },
    } },
  };
  save(repo, config); commit(repo); return { repo, config };
}
function save(repo, config) { put(repo, '.agents/gate.json', JSON.stringify(config, null, 2) + '\n'); }
function gv(repo, sub, ...args) {
  const r = run(process.execPath, [verify, sub, '--repo', repo, ...args], repo);
  return { ...r, json: r.stdout ? JSON.parse(r.stdout) : null };
}
function receipt(repo) { return JSON.parse(readFileSync(join(repo, '.gibson-receipts', git(repo, 'rev-parse', 'HEAD') + '.json'))); }
function test(name, fn) { fn(); passed++; console.log(`  ok — ${name}`); }
try {
  test('ordinary doctor rejects proof-only flags instead of silently ignoring them', () => {
    const { repo } = fixture('ordinary-doctor-proof');
    const result = gv(repo, 'doctor', '--gate', 'gate', '--require-proof');
    assert.equal(result.code, 2);
    assert.match(result.stderr, /--require-proof requires --tooling-only/);
  });
  test('legacy audit permits missing profiles, adoption rejects them without running product gate', () => {
    const { repo, config } = fixture('legacy'); delete config.tooling; save(repo, config); commit(repo);
    assert.equal(gv(repo, 'doctor', '--tooling-only').code, 0);
    assert.equal(gv(repo, 'prove', '--gate', 'gate').code, 0);
    const denied = gv(repo, 'prove', '--gate', 'gate', '--adoption');
    assert.equal(denied.code, 1); assert.equal(denied.json.steps.find(s => s.name === 'gate').ok, false);
  });
  test('static readiness never claims proof; actual syntax controls and product gate produce an adoption receipt', () => {
    const { repo } = fixture('positive');
    const doctor = gv(repo, 'doctor', '--tooling-only'); assert.equal(doctor.code, 0, doctor.stdout + doctor.stderr); assert.equal(doctor.json.proof.verified, false);
    assert.equal(gv(repo, 'doctor', '--tooling-only', '--require-proof').code, 1);
    const direct = run('bash', [gate, '--no-baseline-ok'], repo); assert.equal(direct.code, 1); assert.match(direct.stderr, /required tooling readiness failed/);
    assert.equal(gv(repo, 'prove', '--gate', 'gate', '--adoption').code, 0);
    const proof = receipt(repo); assert.equal(proof.verified, true); assert.equal(proof.tooling.controls.length, 2);
    assert.ok(proof.tooling.controls.every(c => c.positive.exit === 0 && c.negative.exit === 1 && c.negative.matched));
    assert.equal(gv(repo, 'doctor', '--tooling-only', '--require-proof').code, 0);
    assert.equal(run('bash', [gate, '--no-baseline-ok'], repo).code, 0);
  });
  test('omitted applicable surface, false N/A, unknown profile and empty source scope fail', () => {
    for (const change of [c => delete c.tooling.profiles.javascript, c => c.tooling.profiles.javascript = { not_applicable: 'wishful' }, c => c.tooling.profiles.unknown = {}, c => c.tooling.profiles.javascript.sources = ['absent/']]) {
      const { repo, config } = fixture(`missing-${Math.random()}`); change(config); save(repo, config); commit(repo);
      assert.equal(gv(repo, 'prove', '--gate', 'gate', '--adoption').code, 1);
    }
  });
  test('no-op success, wrong diagnostic, unavailable tool and wrong version cannot prove readiness', () => {
    for (const change of [p => p.command = ['/usr/bin/true', '{file}'], p => p.controls.diagnostic = 'F821', p => p.version.command = ['missing-tooling-executable'], p => p.version.expected = 'wrong-version']) {
      const { repo, config } = fixture(`negative-${Math.random()}`); change(config.tooling.profiles.javascript); save(repo, config); commit(repo);
      assert.equal(gv(repo, 'prove', '--gate', 'gate', '--adoption').code, 1);
    }
  });
  test('product-only commits reuse controls but require a new current-head product gate', () => {
    const { repo } = fixture('freshness'); assert.equal(gv(repo, 'prove', '--gate', 'gate').code, 0);
    const old = git(repo, 'rev-parse', 'HEAD'); put(repo, 'src/app.js', 'const value = 2;\n'); commit(repo);
    assert.equal(gv(repo, 'doctor', '--tooling-only', '--require-proof').code, 0);
    assert.equal(gv(repo, 'report', '--agent', 'fixture', '--dry-run').code, 1);
    assert.equal(gv(repo, 'prove', '--gate', 'gate').code, 0); assert.equal(receipt(repo).tooling.reused_from, old);
    assert.ok(receipt(repo).steps.find(s => s.name === 'gate').ok);
    put(repo, 'src/app.js', 'const value = 3;\n'); commit(repo);
    assert.equal(gv(repo, 'doctor', '--tooling-only', '--require-proof', '--adoption').code, 1);
    assert.equal(gv(repo, 'prove', '--gate', 'gate', '--adoption').code, 0); assert.equal(receipt(repo).tooling.reused_from, undefined);
  });
  test('changed config, control, dependency lock or tracked command entrypoint invalidates proof', () => {
    for (const input of ['seed.txt', '.agents/tooling-controls/valid.js', 'package-lock.json', 'checker']) {
      const { repo, config } = fixture(`input-${Math.random()}`);
      put(repo, 'package-lock.json', '{}\n'); config.tooling.profiles.formatting.sources.push('package-lock.json');
      put(repo, 'checker', '#!/bin/sh\nexec "' + process.execPath + '" --check "$1"\n'); chmodSync(join(repo, 'checker'), 0o755);
      config.tooling.profiles.javascript.command = ['./checker', '{file}']; save(repo, config); commit(repo);
      assert.equal(gv(repo, 'prove', '--gate', 'gate').code, 0);
      put(repo, input, readFileSync(join(repo, input), 'utf8') + '\n'); commit(repo);
      assert.equal(gv(repo, 'doctor', '--tooling-only', '--require-proof').code, 1);
    }
  });
  test('trusted required contract cannot disappear or downgrade on a branch', () => {
    for (const change of [c => delete c.tooling, c => c.tooling.mode = 'audit']) {
      const { repo, config } = fixture(`downgrade-${Math.random()}`); git(repo, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
      change(config); save(repo, config); commit(repo);
      assert.equal(gv(repo, 'doctor', '--tooling-only', '--require-proof').code, 1);
      assert.equal(run('bash', [gate, '--no-baseline-ok'], repo).code, 1);
    }
  });
  test('malformed/missing control evidence is not a cache hit', () => {
    const { repo } = fixture('forged'); assert.equal(gv(repo, 'prove', '--gate', 'gate').code, 0);
    const r = receipt(repo); r.tooling.controls = []; put(repo, `.gibson-receipts/${r.head}.json`, JSON.stringify(r));
    assert.equal(gv(repo, 'doctor', '--tooling-only', '--require-proof').code, 1);
    assert.ok(existsSync(join(repo, '.gibson-receipts', `${r.head}.gate.log`)));
  });
  test('non-main adoption forwards its policy base into the built-in gate', () => {
    const { repo } = fixture('non-main'); git(repo, 'update-ref', 'refs/remotes/origin/develop', 'origin/main'); git(repo, 'update-ref', '-d', 'refs/remotes/origin/main');
    const result = gv(repo, 'prove', '--base', 'origin/develop', '--adoption', '--gate-arg', '--no-baseline-ok');
    assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.equal(run('bash', [gate, '--no-baseline-ok', '--tooling-base', 'origin/develop'], repo).code, 0);
  });
  test('a base-tip opt-in also covers branches forked before that opt-in', () => {
    const { repo, config } = fixture('late-opt-in');
    const required = git(repo, 'rev-parse', 'HEAD'); const old = git(repo, 'rev-parse', 'origin/main');
    git(repo, 'checkout', '-qb', 'old-branch', old);
    put(repo, '.agents/gate.json', JSON.stringify({ generate: '', typecheck: '', lint: '', test: '', build: '' })); commit(repo);
    git(repo, 'update-ref', 'refs/remotes/origin/main', required);
    assert.equal(gv(repo, 'doctor', '--tooling-only', '--require-proof').code, 1);
    assert.equal(run('bash', [gate, '--no-baseline-ok'], repo).code, 1);
    assert.equal(config.tooling.mode, 'required');
  });
  test('check is nonpublishing and preserves a prior prove receipt byte-for-byte', () => {
    const { repo } = fixture('nonpublishing');
    const path = join(repo, '.gibson-receipts', `${git(repo, 'rev-parse', 'HEAD')}.json`);
    assert.equal(gv(repo, 'check', '--gate-arg', '--no-baseline-ok').code, 0);
    assert.equal(existsSync(path), false);
    assert.equal(gv(repo, 'prove', '--gate', 'gate').code, 0);
    const bytes = readFileSync(path, 'utf8');
    assert.equal(gv(repo, 'check', '--gate-arg', '--no-baseline-ok').code, 0);
    assert.equal(readFileSync(path, 'utf8'), bytes);
    assert.equal(gv(repo, 'report', '--agent', 'fixture', '--dry-run').code, 0);
  });
  test('losing the tracked checker execute bit invalidates existing proof', () => {
    const { repo, config } = fixture('execute-bit');
    put(repo, 'checker', '#!/bin/sh\nexec "' + process.execPath + '" --check "$1"\n'); chmodSync(join(repo, 'checker'), 0o755);
    config.tooling.profiles.javascript.command = ['./checker', '{file}']; save(repo, config); commit(repo);
    assert.equal(gv(repo, 'prove', '--gate', 'gate').code, 0);
    chmodSync(join(repo, 'checker'), 0o644);
    assert.equal(gv(repo, 'doctor', '--tooling-only', '--require-proof').code, 1);
  });
  test('verifier and helper implementation changes each invalidate prior proof', () => {
    const { repo } = fixture('verifier-code'); assert.equal(gv(repo, 'prove', '--gate', 'gate').code, 0);
    for (const changed of ['gibson-verify.mjs', 'lib/tooling-readiness.mjs']) {
      const copy = join(root, `verifier-${Math.random()}`); mkdirSync(join(copy, 'lib'), { recursive: true });
      for (const name of ['gibson-verify.mjs', 'lib/tooling-readiness.mjs', 'lib/args.mjs']) copyFileSync(join(dirname(verify), name), join(copy, name));
      const args = [join(copy, 'gibson-verify.mjs'), 'doctor', '--repo', repo, '--tooling-only', '--require-proof'];
      assert.equal(run(process.execPath, args, repo).code, 0);
      writeFileSync(join(copy, changed), readFileSync(join(copy, changed), 'utf8') + '\n// changed proof implementation\n');
      assert.equal(run(process.execPath, args, repo).code, 1);
    }
  });
  test('version/control commands cannot rewrite trusted baseline before the gate', () => {
    for (const phase of ['version', 'control']) {
      const { repo, config } = fixture(`baseline-${phase}`);
      put(repo, 'mutator', '#!/bin/sh\nif [ -f .gibson-receipts/armed ]; then printf \'{"changed":true}\\n\' > .gibson-baseline.json; fi\nif [ "$1" = --version ]; then printf \'fixture v1\\n\'; else exec "' + process.execPath + '" --check "$1"; fi\n'); chmodSync(join(repo, 'mutator'), 0o755);
      if (phase === 'version') config.tooling.profiles.javascript.version = { command: ['./mutator', '--version'], expected: 'fixture v1' };
      else config.tooling.profiles.javascript.command = ['./mutator', '{file}'];
      save(repo, config); commit(repo); put(repo, '.gibson-baseline.json', '{}\n');
      assert.equal(gv(repo, 'prove', '--gate', 'gate').code, 0);
      put(repo, '.gibson-receipts/armed', 'yes');
      if (phase === 'version') {
        const direct = run('bash', [gate], repo); assert.equal(direct.code, 1); assert.match(direct.stderr, /baseline authority drift/);
        put(repo, '.gibson-baseline.json', '{}\n');
      }
      const proof = gv(repo, 'prove', '--gate', 'gate', '--refresh-tooling');
      assert.equal(proof.code, 1); assert.equal(proof.json.steps.find(s => s.name === 'tooling-baseline-stable').ok, false);
      assert.equal(receipt(repo).tooling.verified, false);
    }
  });
  test('tooling cannot repair, stage or commit product files and verify the captured head', () => {
    for (const phase of ['version', 'control', 'index', 'commit', 'empty-commit']) {
      const { repo, config } = fixture(`product-${phase}`);
      put(repo, 'src/app.js', phase === 'empty-commit' ? 'const value = 1;\n' : 'const = ;\n');
      let mutation = phase === 'empty-commit' ? '' : 'printf "const value = 2;\\n" > src/app.js\n';
      if (phase === 'index') mutation += 'git add src/app.js\nprintf "const = ;\\n" > src/app.js\n';
      if (phase === 'commit' || phase === 'empty-commit') mutation += 'git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name="Tooling fixture" -c user.email=tooling@localhost commit --allow-empty -qam repair >/dev/null\n';
      put(repo, 'mutator', '#!/bin/sh\nif [ ! -f .gibson-receipts/repaired ]; then\n' + mutation + 'touch .gibson-receipts/repaired\nfi\nif [ "$1" = --version ]; then printf "fixture v1\\n"; else exec "' + process.execPath + '" --check "$1"; fi\n');
      chmodSync(join(repo, 'mutator'), 0o755);
      if (phase === 'control') config.tooling.profiles.javascript.command = ['./mutator', '{file}'];
      else config.tooling.profiles.javascript.version = { command: ['./mutator', '--version'], expected: 'fixture v1' };
      if (phase !== 'index') put(repo, 'gate', '#!/bin/sh\n"' + process.execPath + '" --check src/app.js\n');
      save(repo, config); commit(repo);
      const originalHead = git(repo, 'rev-parse', 'HEAD');
      const result = gv(repo, 'prove', '--gate', 'gate');
      assert.equal(result.code, 1, result.stdout + result.stderr);
      assert.equal(result.json.head, originalHead);
      assert.equal(result.json.steps.find(s => s.name === 'tooling-head-stable').ok, false);
      assert.equal(result.json.steps.find(s => s.name === 'gate').ok, false);
      const proof = JSON.parse(readFileSync(join(repo, '.gibson-receipts', `${originalHead}.json`)));
      assert.equal(proof.verified, false); assert.equal(proof.tooling.verified, false);
      if (phase === 'commit' || phase === 'empty-commit') assert.notEqual(git(repo, 'rev-parse', 'HEAD'), originalHead);
      if (phase === 'index') assert.equal(git(repo, 'diff', originalHead, '--', 'src/app.js'), '');
    }
  });
  test('whitespace-only tracked paths cannot hide worktree or index mutations', () => {
    for (const phase of ['worktree', 'index']) {
      const { repo, config } = fixture(`whitespace-${phase}`);
      put(repo, ' ', 'broken\n');
      const extra = phase === 'index' ? 'git add -- " "\nprintf "broken\\n" > " "\n' : '';
      put(repo, 'mutator', '#!/bin/sh\nprintf "fixed\\n" > " "\n' + extra + 'printf "fixture v1\\n"\n');
      chmodSync(join(repo, 'mutator'), 0o755);
      config.tooling.profiles.javascript.version = { command: ['./mutator'], expected: 'fixture v1' };
      if (phase === 'worktree') put(repo, 'gate', '#!/bin/sh\ntest "$(cat " ")" = fixed\n');
      save(repo, config); commit(repo);
      const result = gv(repo, 'prove', '--gate', 'gate');
      assert.equal(result.code, 1, result.stdout + result.stderr);
      assert.equal(result.json.steps.find(s => s.name === 'tooling-head-stable').ok, false);
      assert.equal(receipt(repo).verified, false); assert.equal(receipt(repo).tooling.verified, false);
    }
  });
  test('gate and final version observation cannot change product files after the initial checks', () => {
    for (const phase of ['gate', 'final-version']) {
      const { repo, config } = fixture(`late-product-${phase}`);
      if (phase === 'gate') put(repo, 'gate', '#!/bin/sh\nprintf "const value = 2;\\n" > src/app.js\nprintf "product gate ran\\n"\n');
      else {
        put(repo, 'mutator', '#!/bin/sh\ncount=$(cat .gibson-receipts/version-count 2>/dev/null || printf 0)\ncount=$((count + 1))\nprintf "%s\\n" "$count" > .gibson-receipts/version-count\nif [ "$count" -eq 3 ]; then printf "const value = 2;\\n" > src/app.js; fi\nprintf "fixture v1\\n"\n');
        chmodSync(join(repo, 'mutator'), 0o755);
        config.tooling.profiles.javascript.version = { command: ['./mutator'], expected: 'fixture v1' };
      }
      save(repo, config); commit(repo);
      const result = gv(repo, 'prove', '--gate', 'gate');
      assert.equal(result.code, 1, result.stdout + result.stderr);
      assert.equal(result.json.steps.find(s => s.name === 'tooling-head-stable').ok, true);
      assert.equal(result.json.steps.find(s => s.name === 'gate').ok, true);
      assert.equal(result.json.steps.find(s => s.name === 'gate-head-stable').ok, false);
      assert.equal(receipt(repo).verified, false); assert.equal(receipt(repo).tooling.verified, false);
    }
  });
  console.log(`tooling-readiness.test.sh: ${passed} passed, 0 failed`);
  console.log(`GIBSON_TEST_METRICS total=${passed} skipped=0 todo=0`);
} finally { rmSync(root, { recursive: true, force: true }); }
NODE
