#!/usr/bin/env node
/**
 * claim-provenance.test.mjs — pure classifier sensors for #273.
 * Injects captured evidence only. Does not call GitHub.
 */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { describe, it } from "node:test";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  AUTHORITY,
  CLAIM_SCHEMA_V2,
  REASON,
  SCHEMA,
  bindLiveSnapshot,
  classifyClaimProvenance,
  commitLoginsFromPayload,
  introducedShas,
  parseExactGitHubPrUrl,
  parseReservationTrailers,
  parseV2BodyMarkers,
  projectClaimBody,
  snapshotFromPr,
} from "./claim-provenance.mjs";

{
  const entry = process.argv[1];
  let isMain = false;
  if (entry) {
    try {
      isMain = realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url));
    } catch {
      try {
        isMain = pathToFileURL(resolve(entry)).href === import.meta.url;
      } catch {
        isMain = false;
      }
    }
  }
  if (isMain) {
    const unknown = process.argv.slice(2);
    if (unknown.length) {
      console.error(
        `claim-provenance.test: unknown flag: ${unknown.join(" ")}\nusage: node --test scripts/claim-provenance.test.mjs`
      );
      process.exit(2);
    }
  }
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");
const BRANCH_POINT = "4773eb580c408f15aacd3715c2bdbbc6a348402b";

const SHA = {
  base: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1",
  res: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1",
  impl1: "ccccccccccccccccccccccccccccccccccccccc1",
  impl2: "ddddddddddddddddddddddddddddddddddddddd1",
  other: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee1",
};
const TREE = {
  empty: "0123456789abcdef0123456789abcdef01234567",
  dirty: "89abcdef0123456789abcdef0123456789abcdef",
};
const BOT = {
  name: "aie-agent-lanes-grok[bot]",
  email: "317307306+aie-agent-lanes-grok[bot]@users.noreply.github.com",
  login: "aie-agent-lanes-grok[bot]",
};
const OWNER = {
  name: "Mark Hinkle",
  email: "mrhinkle@peripety.com",
  login: "mrhinkle",
};

function reservationMessage({
  claimId = "issue-42-demo",
  issue = "42",
  branch = "feat/42-demo",
  author = BOT,
} = {}) {
  return [
    `chore: reserve issue #${issue} for ${claimId}`,
    "",
    "Gibson-Reservation: v1",
    `Gibson-Claim-ID: ${claimId}`,
    `Gibson-Issue: #${issue}`,
    `Gibson-Branch: ${branch}`,
    `Signed-off-by: ${author.name} <${author.email}>`,
  ].join("\n");
}

function v2Body({
  claimId = "issue-42-demo",
  issue = "42",
  scope = "scripts/claim.sh",
  base = SHA.base,
  res = SHA.res,
} = {}) {
  return [
    "## Active work",
    "",
    `- Claim schema: ${CLAIM_SCHEMA_V2}`,
    `- Active-work claim: ${claimId}`,
    "- Isolation: dedicated worktree",
    `- Issue: #${issue}`,
    `- Claim scope: ${scope}`,
    "- Session: tester@box",
    `- Original branch point: ${base}`,
    `- Reservation commit: ${res}`,
  ].join("\n");
}

function commit({
  sha,
  parents = [SHA.base],
  tree = TREE.empty,
  parentTree = TREE.empty,
  author = BOT,
  committer = author,
  message = reservationMessage(),
  readable = true,
} = {}) {
  return {
    sha,
    parents,
    tree,
    parentTree,
    author: { ...author },
    committer: { ...committer },
    message,
    readable,
  };
}

function implMessage(subject, author = BOT) {
  return `${subject}\n\nSigned-off-by: ${author.name} <${author.email}>`;
}

function baseEvidence(extra = {}) {
  const body = extra.body ?? v2Body();
  const commits = extra.commits ?? [
    commit({ sha: SHA.res, parentTree: TREE.empty }),
  ];
  const introducedOrder = extra.introducedOrder ?? [SHA.res];
  const expectedHead =
    extra.expectedHead ?? introducedOrder[introducedOrder.length - 1];
  const defaultSnap = liveSnap({ head: expectedHead, body });
  return {
    repository: "acme/app",
    pr: 99,
    expectedHead,
    expectedClaimId: "issue-42-demo",
    expectedIssue: "42",
    expectedBranch: "feat/42-demo",
    base: "main",
    isCrossRepository: false,
    baseRepository: "acme/app",
    truncated: false,
    unreadable: false,
    commits,
    introducedOrder,
    parentTree: TREE.empty,
    ...extra,
    before: extra.before ?? defaultSnap,
    after: extra.after ?? { ...defaultSnap },
    commits,
    introducedOrder,
  };
}

function assertVerified(result, sha = SHA.res) {
  assert.equal(result.schema, SCHEMA);
  assert.equal(result.authority, AUTHORITY);
  assert.equal(result.reservation?.sha, sha);
  assert.equal(result.reservation?.verified, true);
  assert.equal(result.reservation?.author.login, BOT.login);
  assert.equal(result.reservation?.dco.email, BOT.email);
  assert.equal("READY" in result, false);
  assert.equal("APPROVE" in result, false);
  assert.equal("verdict" in result, false);
}

function gitShow(revPath) {
  return execFileSync("git", ["-C", ROOT, "show", revPath], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function gitC(dir, args, env = {}) {
  return execFileSync("git", ["-C", dir, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: env.GIT_AUTHOR_NAME || BOT.name,
      GIT_AUTHOR_EMAIL: env.GIT_AUTHOR_EMAIL || BOT.email,
      GIT_COMMITTER_NAME: env.GIT_COMMITTER_NAME || env.GIT_AUTHOR_NAME || BOT.name,
      GIT_COMMITTER_EMAIL: env.GIT_COMMITTER_EMAIL || env.GIT_AUTHOR_EMAIL || BOT.email,
    },
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function makeTempRepo() {
  const dir = mkdtempSync(join(tmpdir(), "gibson-prov-"));
  gitC(dir, ["init", "-q"]);
  gitC(dir, ["config", "user.name", BOT.name]);
  gitC(dir, ["config", "user.email", BOT.email]);
  gitC(dir, ["checkout", "-q", "-B", "main"]);
  writeFileSync(join(dir, "README"), "init\n");
  gitC(dir, ["add", "README"]);
  gitC(dir, ["commit", "-qm", "init"]);
  return dir;
}

function liveSnap(extra = {}) {
  const body = extra.body ?? v2Body();
  const head = extra.head ?? SHA.res;
  return {
    head,
    body,
    number: extra.number ?? 99,
    branch: extra.branch ?? "feat/42-demo",
    base: extra.base ?? "main",
    baseOid: extra.baseOid ?? SHA.base,
    isCrossRepository: extra.isCrossRepository ?? false,
    baseRepository: extra.baseRepository ?? "acme/app",
    state: extra.state ?? "OPEN",
  };
}

describe("red-before-green / branch-point claim.sh", () => {
  it("emits no v1 trailers or v2 body markers at 4773eb5", () => {
    const src = gitShow(`${BRANCH_POINT}:scripts/claim.sh`);
    assert.equal(src.includes("Gibson-Reservation"), false);
    assert.equal(src.includes("Gibson-Claim-ID"), false);
    assert.equal(src.includes("Gibson-Issue"), false);
    assert.equal(src.includes("Gibson-Branch"), false);
    assert.equal(src.includes("Claim schema: gibson.claim/v2"), false);
    assert.equal(src.includes("Original branch point:"), false);
    assert.equal(src.includes("Reservation commit:"), false);
    assert.match(src, /commit --allow-empty -s -q -m "chore: reserve issue/);
  });

  it("classifies a v1-less reservation as ordinary introduced provenance", () => {
    const body = [
      "## Active work",
      "",
      "- Active-work claim: issue-273-reservation-provenance-grok",
      "- Isolation: dedicated worktree",
      "- Issue: #273",
      "- Claim scope: scripts/claim.sh",
      "- Session: tester",
      `- Original branch point: \`${BRANCH_POINT}\``,
      "- Reservation head: `1c2a47aabae2ac5b187dcddd407d22a13ca9bce9`",
    ].join("\n");
    const sha = "1c2a47aabae2ac5b187dcddd407d22a13ca9bce9";
    const snap = liveSnap({
      head: sha,
      body,
      number: 289,
      branch: "feat/273-reservation-provenance-grok",
      baseOid: BRANCH_POINT,
      baseRepository: "The-AIE/the-gibson",
      state: "OPEN",
    });
    const result = classifyClaimProvenance({
      repository: "The-AIE/the-gibson",
      pr: 289,
      expectedHead: sha,
      expectedClaimId: "issue-273-reservation-provenance-grok",
      expectedIssue: "273",
      expectedBranch: "feat/273-reservation-provenance-grok",
      base: "main",
      isCrossRepository: false,
      baseRepository: "The-AIE/the-gibson",
      before: snap,
      after: { ...snap },
      commits: [
        commit({
          sha,
          parents: [BRANCH_POINT],
          tree: "463105455154c694ff7e9d08b7ebf47a96297caa",
          parentTree: "463105455154c694ff7e9d08b7ebf47a96297caa",
          message:
            "chore: reserve issue #273 for issue-273-reservation-provenance-grok\n\nSigned-off-by: aie-agent-lanes-grok[bot] <317307306+aie-agent-lanes-grok[bot]@users.noreply.github.com>",
        }),
      ],
      introducedOrder: [sha],
    });
    assert.equal(result.reservation, null);
    assert.equal(result.implementation.length, 1);
    assert.ok(result.implementation[0].reasons.includes(REASON.ORDINARY_INTRODUCED));
    assert.ok(
      result.reasons.includes(REASON.MISSING_V2_SCHEMA) ||
        result.reasons.includes(REASON.MISSING_MARKER)
    );
  });
});

describe("positive classification", () => {
  it("reservation-only PR verifies exactly one reservation", () => {
    const result = classifyClaimProvenance(baseEvidence());
    assertVerified(result);
    assert.equal(result.implementation.length, 0);
    assert.equal(result.unverified.length, 0);
  });

  it("reservation plus one bot implementation keeps the implementation ordinary", () => {
    const evidence = baseEvidence({
      expectedHead: SHA.impl1,
      commits: [
        commit({ sha: SHA.res }),
        commit({
          sha: SHA.impl1,
          parents: [SHA.res],
          tree: TREE.dirty,
          parentTree: TREE.empty,
          message: implMessage("feat(#42): implement"),
        }),
      ],
      introducedOrder: [SHA.res, SHA.impl1],
    });
    const result = classifyClaimProvenance(evidence);
    assertVerified(result);
    assert.equal(result.implementation.length, 1);
    assert.equal(result.implementation[0].sha, SHA.impl1);
    assert.ok(result.implementation[0].reasons.includes(REASON.ORDINARY_INTRODUCED));
    assert.equal(result.implementation[0].author.login, BOT.login);
  });

  it("reservation plus two same-vendor implementation/fix commits", () => {
    const evidence = baseEvidence({
      expectedHead: SHA.impl2,
      commits: [
        commit({ sha: SHA.res }),
        commit({
          sha: SHA.impl1,
          parents: [SHA.res],
          tree: TREE.dirty,
          parentTree: TREE.empty,
          message: implMessage("feat(#42): implement"),
        }),
        commit({
          sha: SHA.impl2,
          parents: [SHA.impl1],
          tree: TREE.dirty,
          parentTree: TREE.dirty,
          message: implMessage("fix(#42): review fix"),
        }),
      ],
      introducedOrder: [SHA.res, SHA.impl1, SHA.impl2],
    });
    const result = classifyClaimProvenance(evidence);
    assertVerified(result);
    assert.equal(result.implementation.length, 2);
    assert.equal(result.implementation[0].sha, SHA.impl1);
    assert.equal(result.implementation[1].sha, SHA.impl2);
    assert.equal(result.implementation[1].author.login, BOT.login);
  });

  it("later nonempty owner commit stays ordinary and does not launder", () => {
    const evidence = baseEvidence({
      expectedHead: SHA.impl1,
      commits: [
        commit({ sha: SHA.res }),
        commit({
          sha: SHA.impl1,
          parents: [SHA.res],
          tree: TREE.dirty,
          parentTree: TREE.empty,
          author: OWNER,
          message: implMessage("feat(#42): owner patch", OWNER),
        }),
      ],
      introducedOrder: [SHA.res, SHA.impl1],
    });
    const result = classifyClaimProvenance(evidence);
    assertVerified(result);
    assert.equal(result.implementation[0].author.login, OWNER.login);
    assert.ok(result.implementation[0].reasons.includes(REASON.ORDINARY_INTRODUCED));
    assert.equal("vendor" in result, false);
    assert.equal("independentReview" in result, false);
  });
});

describe("adversarial body markers", () => {
  function mutateBody(mutator) {
    const body = mutator(v2Body());
    return classifyClaimProvenance(baseEvidence({ body }));
  }

  it("missing Claim schema", () => {
    const result = mutateBody((b) => b.replace("- Claim schema: gibson.claim/v2\n", ""));
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.MISSING_MARKER));
    assert.ok(result.reasons.includes(REASON.MISSING_V2_SCHEMA));
  });

  it("duplicate Active-work claim", () => {
    const result = mutateBody(
      (b) => b.replace(
        "- Active-work claim: issue-42-demo\n",
        "- Active-work claim: issue-42-demo\n- Active-work claim: issue-42-demo\n"
      )
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.DUPLICATE_MARKER));
  });

  it("reordered Issue and Claim scope", () => {
    const body = [
      "## Active work",
      `- Claim schema: ${CLAIM_SCHEMA_V2}`,
      "- Active-work claim: issue-42-demo",
      "- Claim scope: scripts/claim.sh",
      "- Issue: #42",
      `- Original branch point: ${SHA.base}`,
      `- Reservation commit: ${SHA.res}`,
    ].join("\n");
    const result = classifyClaimProvenance(baseEvidence({ body }));
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.REORDERED_MARKER));
  });

  it("conflicting Issue vs claim id", () => {
    const result = mutateBody((b) => b.replace("- Issue: #42", "- Issue: #99"));
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.CONFLICTING_MARKER));
  });

  it("malformed reservation SHA with backticks", () => {
    const result = mutateBody((b) =>
      b.replace(`- Reservation commit: ${SHA.res}`, `- Reservation commit: \`${SHA.res}\``)
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.MALFORMED_MARKER));
  });
});

describe("adversarial trailers", () => {
  it("missing Gibson-Reservation trailer", () => {
    const message = reservationMessage().replace("Gibson-Reservation: v1\n", "");
    const result = classifyClaimProvenance(
      baseEvidence({ commits: [commit({ sha: SHA.res, message })] })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.MISSING_TRAILER) ||
        result.unverified[0]?.reasons.includes(REASON.MISSING_TRAILER)
    );
  });

  it("duplicate Gibson-Claim-ID", () => {
    const message = reservationMessage().replace(
      "Gibson-Claim-ID: issue-42-demo\n",
      "Gibson-Claim-ID: issue-42-demo\nGibson-Claim-ID: issue-42-demo\n"
    );
    const result = classifyClaimProvenance(
      baseEvidence({ commits: [commit({ sha: SHA.res, message })] })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.DUPLICATE_TRAILER) ||
        result.unverified[0]?.reasons.includes(REASON.DUPLICATE_TRAILER)
    );
  });

  it("reordered trailers", () => {
    const message = [
      "chore: reserve issue #42 for issue-42-demo",
      "",
      "Gibson-Claim-ID: issue-42-demo",
      "Gibson-Reservation: v1",
      "Gibson-Issue: #42",
      "Gibson-Branch: feat/42-demo",
      `Signed-off-by: ${BOT.name} <${BOT.email}>`,
    ].join("\n");
    const parsed = parseReservationTrailers(message);
    assert.ok(parsed.reasons.includes(REASON.REORDERED_TRAILER));
    const result = classifyClaimProvenance(
      baseEvidence({ commits: [commit({ sha: SHA.res, message })] })
    );
    assert.equal(result.reservation, null);
  });

  it("conflicting trailer claim id (copied reservation)", () => {
    const message = reservationMessage({ claimId: "issue-99-other", issue: "99" });
    const result = classifyClaimProvenance(
      baseEvidence({ commits: [commit({ sha: SHA.res, message })] })
    );
    assert.equal(result.reservation, null);
    const bag = new Set([
      ...result.reasons,
      ...(result.unverified[0]?.reasons || []),
    ]);
    assert.ok(bag.has(REASON.COPIED_RESERVATION) || bag.has(REASON.CONFLICTING_TRAILER));
  });

  it("DCO mismatch vs author", () => {
    const message = reservationMessage().replace(
      `Signed-off-by: ${BOT.name} <${BOT.email}>`,
      `Signed-off-by: ${OWNER.name} <${OWNER.email}>`
    );
    const result = classifyClaimProvenance(
      baseEvidence({ commits: [commit({ sha: SHA.res, message })] })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.DCO_MISMATCH) ||
        result.unverified[0]?.reasons.includes(REASON.DCO_MISMATCH)
    );
  });

  it("forged subject with valid trailers", () => {
    const message = reservationMessage().replace(
      "chore: reserve issue #42 for issue-42-demo",
      "feat: sneak implementation in as reservation"
    );
    const result = classifyClaimProvenance(
      baseEvidence({ commits: [commit({ sha: SHA.res, message })] })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.FORGED_MESSAGE) ||
        result.unverified[0]?.reasons.includes(REASON.FORGED_MESSAGE)
    );
  });
});

describe("adversarial git object shape", () => {
  it("nonempty reservation tree", () => {
    const result = classifyClaimProvenance(
      baseEvidence({
        commits: [commit({ sha: SHA.res, tree: TREE.dirty, parentTree: TREE.empty })],
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.NONEMPTY_TREE) ||
        result.unverified[0]?.reasons.includes(REASON.NONEMPTY_TREE)
    );
  });

  it("wrong parent", () => {
    const result = classifyClaimProvenance(
      baseEvidence({
        commits: [commit({ sha: SHA.res, parents: [SHA.other] })],
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.WRONG_PARENT) ||
        result.unverified[0]?.reasons.includes(REASON.WRONG_PARENT)
    );
  });

  it("multiple parents", () => {
    const result = classifyClaimProvenance(
      baseEvidence({
        commits: [commit({ sha: SHA.res, parents: [SHA.base, SHA.other] })],
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.MULTIPLE_PARENTS) ||
        result.unverified[0]?.reasons.includes(REASON.MULTIPLE_PARENTS)
    );
  });

  it("rebased reservation (parent is not original branch point)", () => {
    const result = classifyClaimProvenance(
      baseEvidence({
        commits: [commit({ sha: SHA.res, parents: [SHA.impl1] })],
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.REBASED_RESERVATION) ||
        result.unverified[0]?.reasons.includes(REASON.REBASED_RESERVATION)
    );
  });

  it("body SHA is not first introduced", () => {
    const result = classifyClaimProvenance(
      baseEvidence({
        expectedHead: SHA.res,
        commits: [
          commit({
            sha: SHA.impl1,
            parents: [SHA.base],
            tree: TREE.dirty,
            message: implMessage("feat: first"),
          }),
          commit({ sha: SHA.res, parents: [SHA.impl1] }),
        ],
        introducedOrder: [SHA.impl1, SHA.res],
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.NOT_FIRST_INTRODUCED) ||
        result.unverified[0]?.reasons.includes(REASON.NOT_FIRST_INTRODUCED)
    );
  });

  it("copied reservation on another claim/issue/branch/PR binding", () => {
    const result = classifyClaimProvenance(
      baseEvidence({
        expectedClaimId: "issue-7-other",
        expectedIssue: "7",
        expectedBranch: "feat/7-other",
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.BINDING_MISMATCH) ||
        result.reasons.includes(REASON.COPIED_RESERVATION) ||
        result.reasons.includes(REASON.CONFLICTING_MARKER)
    );
  });
});

describe("adversarial identity and live reads", () => {
  it("author/committer/login ambiguity", () => {
    const result = classifyClaimProvenance(
      baseEvidence({
        commits: [
          commit({
            sha: SHA.res,
            author: { name: BOT.name, email: BOT.email, login: null },
          }),
        ],
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.LOGIN_AMBIGUITY) ||
        result.unverified[0]?.reasons.includes(REASON.LOGIN_AMBIGUITY)
    );
  });

  it("fork PR", () => {
    const result = classifyClaimProvenance(
      baseEvidence({ isCrossRepository: true, baseRepository: "other/fork" })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.FORK_PR));
  });

  it("truncated API result", () => {
    const result = classifyClaimProvenance(baseEvidence({ truncated: true }));
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.TRUNCATED_API));
  });

  it("unstable head reads", () => {
    const body = v2Body();
    const result = classifyClaimProvenance(
      baseEvidence({
        before: liveSnap({ head: SHA.res, body }),
        after: liveSnap({ head: SHA.impl1, body }),
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.UNSTABLE_HEAD));
    assert.equal(result.stable, false);
  });

  it("unstable body projection", () => {
    const before = v2Body();
    const after = v2Body({ res: SHA.impl1 });
    const result = classifyClaimProvenance(
      baseEvidence({
        before: liveSnap({ head: SHA.res, body: before }),
        after: liveSnap({ head: SHA.res, body: after }),
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.UNSTABLE_BODY));
  });

  it("unreadable object", () => {
    const result = classifyClaimProvenance(
      baseEvidence({
        commits: [commit({ sha: SHA.res, readable: false })],
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.UNREADABLE_OBJECT));
  });
});

describe("historical negative controls (captured)", () => {
  const HIST = [
    {
      pr: 267,
      head: "d9989c10967393a5b1c8ce50afa9424a8274e582",
      claimId: "issue-260-portable-suite-timeout",
      issue: "260",
      branch: "feat/260-portable-suite-timeout",
      body: `## Active work

- Active-work claim: issue-260-portable-suite-timeout
- Isolation: dedicated worktree
- Issue: #260
- Claim scope: scripts/tests/run-all.sh scripts/tests/wall-timeout.test.sh scripts/README.md
- Session: codex-gibson-260
- Claimed: 2026-08-31T00:51:14Z
`,
      commits: [
        {
          sha: "8667321a3063b76fe06d4ba98a27d6430cf6a135",
          parents: ["fde8246169cfb6d2af1ed93276eb5b350c3f94eb"],
          tree: "dfd20745356b73506cb253eb8f4f72912b4264ec",
          author: OWNER,
          committer: OWNER,
          message:
            "chore: reserve issue #260 for issue-260-portable-suite-timeout\n\nSigned-off-by: Mark Hinkle <mrhinkle@peripety.com>",
          readable: true,
        },
        {
          sha: "d9989c10967393a5b1c8ce50afa9424a8274e582",
          parents: ["8667321a3063b76fe06d4ba98a27d6430cf6a135"],
          tree: "280d8bd46711fa29b3d262a1246e7071ae9b0c6a",
          author: BOT,
          committer: BOT,
          message:
            "fix(#260): enforce portable per-suite timeout\n\nSigned-off-by: aie-agent-lanes-grok[bot] <317307306+aie-agent-lanes-grok[bot]@users.noreply.github.com>",
          readable: true,
        },
      ],
      introducedOrder: [
        "8667321a3063b76fe06d4ba98a27d6430cf6a135",
        "d9989c10967393a5b1c8ce50afa9424a8274e582",
      ],
    },
    {
      pr: 272,
      head: "675984f77d54b2a46843d8076298473f66b87efc",
      claimId: "issue-256-sensor-health-current-main",
      issue: "256",
      branch: "feat/256-sensor-health-current-main",
      body: `## Active work

- Active-work claim: issue-256-sensor-health-current-main
- Isolation: dedicated worktree
- Issue: #256
- Claim scope: scripts/sensor-health.mjs
- Session: codex-gibson-256
- Claimed: 2026-08-31T02:46:52Z
`,
      commits: [
        {
          sha: "675984f77d54b2a46843d8076298473f66b87efc",
          parents: ["9964485708e43682015d7a918ac0a3fff5d48f05"],
          tree: "280d8bd46711fa29b3d262a1246e7071ae9b0c6a",
          author: OWNER,
          committer: OWNER,
          message:
            "chore: reserve issue #256 for issue-256-sensor-health-current-main\n\nSigned-off-by: Mark Hinkle <mrhinkle@peripety.com>",
          readable: true,
        },
      ],
      introducedOrder: ["675984f77d54b2a46843d8076298473f66b87efc"],
    },
    {
      pr: 270,
      head: "313127a2e8c53da6890d0ab400c42813a8d14591",
      claimId: "issue-260-portable-suite-timeout-bot",
      issue: "260",
      branch: "feat/260-portable-suite-timeout-bot",
      body: `## Active work

- Active-work claim: issue-260-portable-suite-timeout-bot
- Isolation: dedicated worktree
- Issue: #260
- Claim scope: scripts/tests/run-all.sh scripts/tests/wall-timeout.test.sh
- Session: codex-gibson-260
`,
      commits: [
        {
          sha: "313127a2e8c53da6890d0ab400c42813a8d14591",
          parents: ["fde8246169cfb6d2af1ed93276eb5b350c3f94eb"],
          tree: "280d8bd46711fa29b3d262a1246e7071ae9b0c6a",
          author: BOT,
          committer: BOT,
          message:
            "fix(#260): enforce portable per-suite timeout\n\nSigned-off-by: aie-agent-lanes-grok[bot] <317307306+aie-agent-lanes-grok[bot]@users.noreply.github.com>",
          readable: true,
        },
      ],
      introducedOrder: ["313127a2e8c53da6890d0ab400c42813a8d14591"],
    },
    {
      pr: 283,
      head: "f779354d4a9798cbdab1ef10cfa0ad6fa9f54270",
      claimId: "issue-271-release-claim-dry-run-target-grok",
      issue: "271",
      branch: "feat/271-release-claim-dry-run-target-grok",
      body: `## Active work

- Active-work claim: issue-271-release-claim-dry-run-target-grok
- Isolation: dedicated worktree
- Issue: #271
- Claim scope: scripts/release-claim.sh scripts/tests/release-claim.test.sh
- Original branch-point baseline: \`ea1dff3212054443347b36bb586e584422ab32bc\`
- Exact head: \`f779354d4a9798cbdab1ef10cfa0ad6fa9f54270\`
`,
      commits: [
        {
          sha: "f779354d4a9798cbdab1ef10cfa0ad6fa9f54270",
          parents: ["7b0111855554199300bbae6aad4537aec5801fc2"],
          tree: "463105455154c694ff7e9d08b7ebf47a96297caa",
          author: BOT,
          committer: BOT,
          message:
            "fix: resolve canonical path and fixture evidence\n\nSigned-off-by: aie-agent-lanes-grok[bot] <317307306+aie-agent-lanes-grok[bot]@users.noreply.github.com>",
          readable: true,
        },
      ],
      introducedOrder: ["f779354d4a9798cbdab1ef10cfa0ad6fa9f54270"],
    },
  ];

  for (const h of HIST) {
    it(`PR #${h.pr} at ${h.head} yields zero verified reservations`, () => {
      const snap = liveSnap({
        head: h.head,
        body: h.body,
        number: h.pr,
        branch: h.branch,
        baseOid: h.commits[0].parents[0],
        baseRepository: "The-AIE/the-gibson",
        state: "MERGED",
      });
      const result = classifyClaimProvenance({
        repository: "The-AIE/the-gibson",
        pr: h.pr,
        expectedHead: h.head,
        expectedClaimId: h.claimId,
        expectedIssue: h.issue,
        expectedBranch: h.branch,
        base: "main",
        isCrossRepository: false,
        baseRepository: "The-AIE/the-gibson",
        before: snap,
        after: { ...snap },
        commits: h.commits,
        introducedOrder: h.introducedOrder,
      });
      assert.equal(result.reservation, null);
      assert.equal(result.schema, SCHEMA);
      assert.equal(result.authority, AUTHORITY);
      assert.ok(result.implementation.length >= 1);
      assert.ok(
        result.reasons.includes(REASON.MISSING_V2_SCHEMA) ||
          result.reasons.includes(REASON.MISSING_MARKER)
      );
    });
  }
});

describe("authority boundary", () => {
  it("never emits READY/APPROVE/merge/release/vendor keys", () => {
    const result = classifyClaimProvenance(baseEvidence());
    const keys = Object.keys(result);
    for (const banned of [
      "READY",
      "APPROVE",
      "verdict",
      "merge",
      "release",
      "vendor",
      "independentReview",
      "reviewerIndependence",
    ]) {
      assert.equal(keys.includes(banned), false, banned);
    }
    const text = JSON.stringify(result);
    assert.equal(result.authority, "report-only");
    assert.doesNotMatch(text, /"READY"/);
    assert.doesNotMatch(text, /"APPROVE"/);
  });

  it("projectClaimBody ignores Isolation/Session drift", () => {
    const a = v2Body();
    const b = v2Body() + "\n- Session: other";
    assert.equal(projectClaimBody(a), projectClaimBody(b));
  });

  it("parseV2BodyMarkers requires exact schema token", () => {
    const parsed = parseV2BodyMarkers(v2Body());
    assert.equal(parsed.complete, true);
    assert.equal(parsed.values.schema, CLAIM_SCHEMA_V2);
  });
});

describe("exact-diff · live identity binding", () => {
  it("mismatched live PR number is rejected", () => {
    const snap = liveSnap({ number: 100 });
    const result = classifyClaimProvenance(
      baseEvidence({ before: snap, after: snap, pr: 99 })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.BINDING_MISMATCH));
  });

  it("mismatched live head branch is rejected", () => {
    const snap = liveSnap({ branch: "feat/copied-other" });
    const result = classifyClaimProvenance(
      baseEvidence({
        before: snap,
        after: snap,
        expectedBranch: "feat/42-demo",
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.BINDING_MISMATCH));
    assert.equal(result.branch, "feat/copied-other");
  });

  it("mismatched live base ref is rejected", () => {
    const snap = liveSnap({ base: "develop" });
    const result = classifyClaimProvenance(
      baseEvidence({ before: snap, after: snap, base: "main" })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.BINDING_MISMATCH));
  });

  it("mismatched live base repository is rejected", () => {
    const snap = liveSnap({ baseRepository: "other/fork" });
    const result = classifyClaimProvenance(
      baseEvidence({
        before: snap,
        after: snap,
        repository: "acme/app",
        baseRepository: "other/fork",
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.BINDING_MISMATCH));
  });

  it("mismatched live cross-repository flag is rejected", () => {
    const snap = liveSnap({ isCrossRepository: true });
    const result = classifyClaimProvenance(
      baseEvidence({
        before: snap,
        after: snap,
        isCrossRepository: true,
        baseRepository: "acme/app",
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.FORK_PR));
  });

  it("drifting live base OID is rejected", () => {
    const before = liveSnap({ baseOid: SHA.base });
    const after = liveSnap({ baseOid: SHA.other });
    const result = classifyClaimProvenance(baseEvidence({ before, after }));
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.UNSTABLE_IDENTITY));
    assert.equal(result.stable, false);
  });

  it("drifting live state is rejected", () => {
    const before = liveSnap({ state: "OPEN" });
    const after = liveSnap({ state: "CLOSED" });
    const result = classifyClaimProvenance(baseEvidence({ before, after }));
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.UNSTABLE_IDENTITY));
  });

  it("copied reservation on another PR is rejected by live PR/base/branch binding", () => {
    const snap = liveSnap({
      number: 100,
      branch: "feat/7-other",
      baseOid: SHA.other,
    });
    const result = classifyClaimProvenance(
      baseEvidence({
        pr: 99,
        expectedClaimId: "issue-42-demo",
        expectedIssue: "42",
        expectedBranch: "feat/42-demo",
        before: snap,
        after: snap,
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.BINDING_MISMATCH));
    assert.equal(result.branch, "feat/7-other");
  });

  it("snapshotFromPr binds baseRefOid and does not invent the caller branch", () => {
    const snap = snapshotFromPr({
      number: 7,
      url: "https://github.com/acme/app/pull/7",
      body: v2Body(),
      headRefOid: SHA.res,
      headRefName: "feat/live",
      isCrossRepository: false,
      baseRefName: "main",
      baseRefOid: SHA.base,
      state: "OPEN",
    });
    assert.equal(snap.branch, "feat/live");
    assert.equal(snap.baseOid, SHA.base);
    assert.equal(snap.number, 7);
    assert.equal(snap.baseRepository, "acme/app");
    const bound = bindLiveSnapshot(snap, {
      pr: 7,
      branch: "feat/live",
      base: "main",
      repo: "acme/app",
    });
    assert.equal(bound.ok, true);
  });

  it("snapshotFromPr derives base repository from the exact PR URL", () => {
    const snap = snapshotFromPr({
      number: 267,
      url: "https://github.com/The-AIE/the-gibson/pull/267",
      body: v2Body(),
      headRefOid: SHA.res,
      headRefName: "feat/260-portable-suite-timeout",
      isCrossRepository: false,
      baseRefName: "main",
      baseRefOid: SHA.base,
      state: "CLOSED",
    });
    assert.equal(snap.baseRepository, "The-AIE/the-gibson");
    const bound = bindLiveSnapshot(snap, {
      pr: 267,
      branch: "feat/260-portable-suite-timeout",
      base: "main",
      repo: "The-AIE/the-gibson",
    });
    assert.equal(bound.ok, true);
  });
});

describe("exact-diff · production PR URL identity", () => {
  function viewJson(extra = {}) {
    return {
      number: 99,
      url: "https://github.com/acme/app/pull/99",
      body: v2Body(),
      headRefOid: SHA.res,
      headRefName: "feat/42-demo",
      isCrossRepository: false,
      baseRefName: "main",
      baseRefOid: SHA.base,
      state: "OPEN",
      ...extra,
    };
  }

  function assertIncomplete(snap, expectedPr = 99) {
    assert.equal(snap.baseRepository, null);
    const bound = bindLiveSnapshot(snap, {
      pr: expectedPr,
      branch: "feat/42-demo",
      base: "main",
      repo: "acme/app",
    });
    assert.equal(bound.ok, false);
    assert.ok(bound.reasons.includes(REASON.BINDING_MISMATCH));
    const result = classifyClaimProvenance(
      baseEvidence({
        before: snap,
        after: { ...snap },
        pr: expectedPr,
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.BINDING_MISMATCH));
  }

  it("parseExactGitHubPrUrl returns canonical owner/repo and the positive PR number", () => {
    assert.deepEqual(parseExactGitHubPrUrl("https://github.com/acme/app/pull/99"), {
      repo: "acme/app",
      number: 99,
    });
    assert.deepEqual(
      parseExactGitHubPrUrl("https://github.com/The-AIE/the-gibson/pull/267"),
      { repo: "The-AIE/the-gibson", number: 267 }
    );
  });

  it("happy exact URL remains green and ignores unsupported baseRepository", () => {
    const snap = snapshotFromPr(
      viewJson({
        baseRepository: { nameWithOwner: "evil/fork" },
      })
    );
    assert.equal(snap.baseRepository, "acme/app");
    const bound = bindLiveSnapshot(snap, {
      pr: 99,
      branch: "feat/42-demo",
      base: "main",
      repo: "acme/app",
    });
    assert.equal(bound.ok, true);
  });

  it("does not fall back to unsupported baseRepository when URL evidence exists", () => {
    const snap = snapshotFromPr(
      viewJson({
        url: "https://github.com/acme/app/pull/99.evil",
        baseRepository: { nameWithOwner: "acme/app" },
      })
    );
    assertIncomplete(snap);
  });

  it("does not take repository identity from unsupported baseRepository when URL is absent", () => {
    const json = viewJson();
    delete json.url;
    json.baseRepository = { nameWithOwner: "acme/app" };
    const snap = snapshotFromPr(json);
    assertIncomplete(snap);
  });

  it("mismatched URL and JSON PR numbers cannot verify", () => {
    const snap = snapshotFromPr(
      viewJson({
        number: 99,
        url: "https://github.com/acme/app/pull/100",
        baseRepository: { nameWithOwner: "acme/app" },
      })
    );
    assertIncomplete(snap, 99);
  });

  it("PR URL .evil suffix cannot verify", () => {
    assert.equal(parseExactGitHubPrUrl("https://github.com/acme/app/pull/99.evil"), null);
    assertIncomplete(
      snapshotFromPr(
        viewJson({
          url: "https://github.com/acme/app/pull/99.evil",
          baseRepository: "acme/app",
        })
      )
    );
  });

  it("PR URL extra path cannot verify", () => {
    assert.equal(
      parseExactGitHubPrUrl("https://github.com/acme/app/pull/99/files"),
      null
    );
    assertIncomplete(
      snapshotFromPr(viewJson({ url: "https://github.com/acme/app/pull/99/files" }))
    );
  });

  it("PR URL query cannot verify", () => {
    assert.equal(
      parseExactGitHubPrUrl("https://github.com/acme/app/pull/99?foo=1"),
      null
    );
    assertIncomplete(
      snapshotFromPr(viewJson({ url: "https://github.com/acme/app/pull/99?foo=1" }))
    );
  });

  it("PR URL fragment cannot verify", () => {
    assert.equal(
      parseExactGitHubPrUrl("https://github.com/acme/app/pull/99#discussion"),
      null
    );
    assertIncomplete(
      snapshotFromPr(
        viewJson({ url: "https://github.com/acme/app/pull/99#discussion" })
      )
    );
  });

  it("nonpositive PR URL number cannot verify", () => {
    assert.equal(parseExactGitHubPrUrl("https://github.com/acme/app/pull/0"), null);
    assert.equal(parseExactGitHubPrUrl("https://github.com/acme/app/pull/-1"), null);
    assertIncomplete(
      snapshotFromPr(viewJson({ number: 99, url: "https://github.com/acme/app/pull/0" }))
    );
  });

  it("lookalike GitHub host cannot verify", () => {
    assert.equal(
      parseExactGitHubPrUrl("https://github.com.evil/acme/app/pull/99"),
      null
    );
    assertIncomplete(
      snapshotFromPr(
        viewJson({ url: "https://github.com.evil/acme/app/pull/99" })
      )
    );
  });

  it("alternate scheme, credentials, and port cannot parse", () => {
    assert.equal(parseExactGitHubPrUrl("http://github.com/acme/app/pull/99"), null);
    assert.equal(
      parseExactGitHubPrUrl("https://user:pass@github.com/acme/app/pull/99"),
      null
    );
    assert.equal(
      parseExactGitHubPrUrl("https://github.com:443/acme/app/pull/99"),
      null
    );
  });
});

describe("exact-diff · globally gated candidates keep reasons", () => {
  it("a globally gated fork candidate always has a nonempty reason list", () => {
    const result = classifyClaimProvenance(
      baseEvidence({ isCrossRepository: true, baseRepository: "other/fork" })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.unverified.length >= 1);
    assert.ok(result.unverified[0].reasons.length >= 1);
    assert.ok(result.unverified[0].reasons.includes(REASON.FORK_PR));
  });

  it("a globally gated unstable-head candidate always has a nonempty reason list", () => {
    const body = v2Body();
    const result = classifyClaimProvenance(
      baseEvidence({
        before: liveSnap({ head: SHA.res, body }),
        after: liveSnap({ head: SHA.impl1, body }),
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.unverified.length >= 1);
    assert.ok(result.unverified[0].reasons.length >= 1);
    assert.ok(result.unverified[0].reasons.includes(REASON.UNSTABLE_HEAD));
  });

  it("a globally gated malformed-marker candidate always has a nonempty reason list", () => {
    const body = v2Body().replace(
      `- Reservation commit: ${SHA.res}`,
      `- Reservation commit: \`${SHA.res}\``
    );
    const result = classifyClaimProvenance(baseEvidence({ body }));
    assert.equal(result.reservation, null);
    assert.ok(result.unverified.length >= 1);
    assert.ok(result.unverified[0].reasons.length >= 1);
    assert.ok(result.unverified[0].reasons.includes(REASON.MALFORMED_MARKER));
  });
});

describe("exact-diff · introduced range is live-base authoritative", () => {
  it("forged body original branch point cannot expand the injected introduced range", () => {
    const result = classifyClaimProvenance(
      baseEvidence({
        body: v2Body({ base: SHA.other }),
        commits: [commit({ sha: SHA.res, parents: [SHA.base] })],
        introducedOrder: [SHA.res],
      })
    );
    assert.equal(
      result.implementation.some((c) => c.sha === SHA.other),
      false
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.WRONG_PARENT) ||
        result.unverified[0]?.reasons.includes(REASON.WRONG_PARENT)
    );
  });

  it("a reservation already absent from the live introduced set is not verified", () => {
    const result = classifyClaimProvenance(
      baseEvidence({
        expectedHead: SHA.impl1,
        commits: [
          commit({
            sha: SHA.impl1,
            parents: [SHA.res],
            tree: TREE.dirty,
            message: implMessage("feat(#42): implement"),
          }),
        ],
        introducedOrder: [SHA.impl1],
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.unverified.some((u) => u.sha === SHA.res));
    const bag = new Set([
      ...result.reasons,
      ...(result.unverified.find((u) => u.sha === SHA.res)?.reasons || []),
    ]);
    assert.ok(bag.has(REASON.RESERVATION_NOT_IN_HISTORY));
  });

  it("introducedShas omits commits already on the live base", () => {
    const dir = makeTempRepo();
    try {
      const extra = gitC(dir, ["rev-parse", "HEAD"]);
      writeFileSync(join(dir, "extra.txt"), "already on base\n");
      gitC(dir, ["add", "extra.txt"]);
      gitC(dir, ["commit", "-qm", "extra on main"]);
      const base = gitC(dir, ["rev-parse", "HEAD"]);
      gitC(dir, ["commit", "--allow-empty", "-qm", "reservation"]);
      const head = gitC(dir, ["rev-parse", "HEAD"]);
      const order = introducedShas(dir, base, head);
      assert.equal(order.includes(extra), false);
      assert.deepEqual(order, [head]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("introducedShas enumerates a nonempty second-parent-side commit", () => {
    const dir = makeTempRepo();
    try {
      const base = gitC(dir, ["rev-parse", "HEAD"]);
      gitC(dir, ["commit", "--allow-empty", "-qm", "reservation"]);
      const reservation = gitC(dir, ["rev-parse", "HEAD"]);
      gitC(dir, ["checkout", "-q", "-b", "side", base]);
      writeFileSync(join(dir, "side.txt"), "merge-side work\n");
      gitC(dir, ["add", "side.txt"]);
      gitC(
        dir,
        ["commit", "-qm", "side implementation"],
        { GIT_AUTHOR_NAME: OWNER.name, GIT_AUTHOR_EMAIL: OWNER.email }
      );
      const side = gitC(dir, ["rev-parse", "HEAD"]);
      gitC(dir, ["checkout", "-q", "main"]);
      gitC(dir, ["merge", "--no-ff", "-m", "merge side", "side"]);
      const head = gitC(dir, ["rev-parse", "HEAD"]);
      const order = introducedShas(dir, base, head);
      assert.ok(order.includes(reservation));
      assert.ok(order.includes(side), `missing side commit in ${order.join(",")}`);
      assert.ok(order.includes(head));
      const result = classifyClaimProvenance(
        baseEvidence({
          body: v2Body({ base, res: reservation }),
          expectedHead: head,
          commits: [
            commit({ sha: reservation, parents: [base] }),
            commit({
              sha: side,
              parents: [base],
              tree: TREE.dirty,
              author: OWNER,
              message: implMessage("side implementation", OWNER),
            }),
            commit({
              sha: head,
              parents: [reservation, side],
              tree: TREE.dirty,
              message: implMessage("merge side"),
            }),
          ],
          introducedOrder: order,
        })
      );
      const sideRec = result.implementation.find((c) => c.sha === side);
      assert.ok(sideRec);
      assert.equal(sideRec.author.name, OWNER.name);
      assert.equal(sideRec.author.email, OWNER.email);
      assert.equal(sideRec.author.login, OWNER.login);
      assert.ok(sideRec.reasons.includes(REASON.ORDINARY_INTRODUCED));
      assert.equal(result.reservation?.sha, reservation);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("exact-diff · commit REST sha binding", () => {
  it("a commit REST response whose sha differs from the requested SHA is rejected", () => {
    assert.throws(
      () =>
        commitLoginsFromPayload(
          {
            sha: SHA.other,
            author: { login: BOT.login },
            committer: { login: BOT.login },
          },
          SHA.res
        ),
      (err) => err && err.code === REASON.BINDING_MISMATCH
    );
  });

  it("a commit REST response missing sha is rejected", () => {
    assert.throws(
      () =>
        commitLoginsFromPayload(
          { author: { login: BOT.login }, committer: { login: BOT.login } },
          SHA.res
        ),
      (err) => err && err.code === REASON.UNREADABLE_OBJECT
    );
  });
});

describe("exact-diff · complete live identity is mandatory", () => {
  function bindingOrUnreadable(result) {
    const bag = new Set([
      ...result.reasons,
      ...(result.unverified[0]?.reasons || []),
    ]);
    return (
      bag.has(REASON.BINDING_MISMATCH) || bag.has(REASON.UNREADABLE_OBJECT)
    );
  }

  it("head/body-only evidence never verifies", () => {
    const body = v2Body();
    const result = classifyClaimProvenance(
      baseEvidence({
        before: { head: SHA.res, body },
        after: { head: SHA.res, body },
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(bindingOrUnreadable(result));
  });

  const IDENTITY_MUTATIONS = [
    { field: "number", kind: "delete", value: undefined },
    { field: "number", kind: "malform", value: "x" },
    { field: "branch", kind: "delete", value: undefined },
    { field: "branch", kind: "malform", value: "" },
    { field: "head", kind: "delete", value: undefined },
    { field: "head", kind: "malform", value: "not-a-sha" },
    { field: "base", kind: "delete", value: undefined },
    { field: "base", kind: "malform", value: "" },
    { field: "baseOid", kind: "delete", value: undefined },
    { field: "baseOid", kind: "malform", value: "zzzz" },
    { field: "baseRepository", kind: "delete", value: undefined },
    { field: "baseRepository", kind: "malform", value: "" },
    { field: "isCrossRepository", kind: "delete", value: undefined },
    { field: "isCrossRepository", kind: "malform", value: "false" },
    { field: "state", kind: "delete", value: undefined },
    { field: "state", kind: "malform", value: "OPENING" },
  ];

  for (const m of IDENTITY_MUTATIONS) {
    it(`${m.kind} live identity field ${m.field} yields reservation:null`, () => {
      const snap = liveSnap();
      if (m.kind === "delete") delete snap[m.field];
      else snap[m.field] = m.value;
      const result = classifyClaimProvenance(
        baseEvidence({ before: snap, after: { ...snap } })
      );
      assert.equal(result.reservation, null);
      assert.ok(bindingOrUnreadable(result));
      assert.ok(
        result.reasons.length > 0 ||
          (result.unverified[0]?.reasons || []).length > 0
      );
    });
  }
});

describe("exact-diff · original parent tree is not substituted", () => {
  it("unreadable original parent with coinciding live-base tree never verifies", () => {
    const snap = liveSnap({ baseOid: SHA.base });
    const result = classifyClaimProvenance(
      baseEvidence({
        body: v2Body({ base: SHA.other }),
        parentTree: TREE.empty,
        before: snap,
        after: { ...snap },
        commits: [
          commit({
            sha: SHA.res,
            parents: [SHA.other],
            tree: TREE.empty,
            parentTree: null,
          }),
        ],
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.UNREADABLE_OBJECT) ||
        result.unverified[0]?.reasons.includes(REASON.UNREADABLE_OBJECT)
    );
  });
});

describe("exact-diff · writer OPEN predicate vs report-only terminal state", () => {
  it("stable CLOSED report-only evidence may still verify", () => {
    const snap = liveSnap({ state: "CLOSED" });
    const result = classifyClaimProvenance(
      baseEvidence({ before: snap, after: { ...snap } })
    );
    assertVerified(result);
  });

  it("stable MERGED report-only evidence may still verify", () => {
    const snap = liveSnap({ state: "MERGED" });
    const result = classifyClaimProvenance(
      baseEvidence({ before: snap, after: { ...snap } })
    );
    assertVerified(result);
  });

  it("writer predicate refuses a stable CLOSED snapshot", () => {
    const snap = liveSnap({ state: "CLOSED" });
    const result = classifyClaimProvenance(
      baseEvidence({
        requireOpen: true,
        before: snap,
        after: { ...snap },
      })
    );
    assert.equal(result.reservation, null);
    assert.ok(result.reasons.includes(REASON.BINDING_MISMATCH));
  });

  it("invalid PR state is not a valid identity", () => {
    const snap = liveSnap({ state: "OPENING" });
    const result = classifyClaimProvenance(
      baseEvidence({ before: snap, after: { ...snap } })
    );
    assert.equal(result.reservation, null);
    assert.ok(
      result.reasons.includes(REASON.BINDING_MISMATCH) ||
        result.reasons.includes(REASON.UNREADABLE_OBJECT)
    );
  });
});
