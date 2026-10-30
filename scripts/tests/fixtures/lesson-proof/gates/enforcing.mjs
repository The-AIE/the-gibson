import { readFileSync } from "node:fs";

const LESSON_PROOF_ENFORCE = true;

function readMarker(dir) {
  return readFileSync(`${dir}/marker`, "utf8").replace(/\s+/g, "");
}

let fixture = "";
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 1) {
  if (argv[i] === "--fixture") {
    fixture = argv[i + 1] || "";
    i += 1;
  } else {
    process.stderr.write("unknown arg\n");
    process.exit(2);
  }
}
if (!fixture) process.exit(2);

let marker = "";
try {
  marker = readMarker(fixture);
} catch {
  process.exit(2);
}
process.stdout.write("LESSON_PROOF_GATE_SAW_FIXTURE\n");
if (marker !== "bad" && marker !== "ok") process.exit(2);
if (LESSON_PROOF_ENFORCE === true && marker === "bad") process.exit(1);
process.exit(0);
