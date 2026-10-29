/**
 * eval-expect.mjs — the one definition of what a dataset `expect` means (#583).
 * Shared by eval-dataset-lint.mjs (shape) and eval-run.mjs (scoring) so the two
 * cannot drift. Pure library, import only.
 */

export const EXPECT_TYPES = ["contains", "not_contains", "regex", "exit_code"];

/**
 * @param {unknown} expect
 * @returns {string | null} a problem description, or null when valid
 */
export function validateExpect(expect) {
  if (!expect || typeof expect !== "object" || Array.isArray(expect)) {
    return "must be an object with a type";
  }
  const e = /** @type {{type?: unknown, value?: unknown, flags?: unknown}} */ (expect);
  if (typeof e.type !== "string" || !EXPECT_TYPES.includes(e.type)) {
    return `has unknown type ${JSON.stringify(e.type)}`;
  }
  if (e.type === "exit_code") {
    return Number.isInteger(e.value) ? null : "exit_code needs an integer value";
  }
  if (typeof e.value !== "string" || e.value === "") return `${e.type} needs a non-empty string value`;
  if (e.type === "regex") {
    if (e.flags !== undefined && (typeof e.flags !== "string" || !/^[ims]*$/.test(e.flags))) {
      return "regex flags may only contain i, m, s";
    }
    try {
      new RegExp(e.value, typeof e.flags === "string" ? e.flags : "");
    } catch {
      return "regex value does not compile";
    }
  }
  return null;
}

/**
 * Score one case. A malformed expect is a FAIL, never a pass.
 * @param {unknown} expect
 * @param {{ stdout: string, exitCode: number | null }} got
 * @returns {{ pass: boolean, reason: string }}
 */
export function checkExpect(expect, got) {
  const bad = validateExpect(expect);
  if (bad) return { pass: false, reason: `invalid expect: ${bad}` };
  const e = /** @type {{type: string, value: string | number, flags?: string}} */ (expect);
  switch (e.type) {
    case "contains":
      return got.stdout.includes(String(e.value))
        ? { pass: true, reason: "contains matched" }
        : { pass: false, reason: `output does not contain ${JSON.stringify(e.value)}` };
    case "not_contains":
      return got.stdout.includes(String(e.value))
        ? { pass: false, reason: `output contains forbidden ${JSON.stringify(e.value)}` }
        : { pass: true, reason: "forbidden text absent" };
    case "regex":
      return new RegExp(String(e.value), e.flags || "").test(got.stdout)
        ? { pass: true, reason: "regex matched" }
        : { pass: false, reason: `output does not match /${e.value}/` };
    case "exit_code":
      return got.exitCode === e.value
        ? { pass: true, reason: `exit code ${e.value}` }
        : { pass: false, reason: `exit code ${got.exitCode}, wanted ${e.value}` };
    default:
      return { pass: false, reason: "unreachable expect type" };
  }
}
