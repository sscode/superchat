// SPDX-License-Identifier: AGPL-3.0-only

import { spawnSync } from "node:child_process";

const [base, head] = process.argv.slice(2);
if (!base || !head) {
  console.error("usage: node scripts/check-dco.mjs <base-sha> <head-sha>");
  process.exit(2);
}

const result = spawnSync(
  "git",
  ["log", "--format=%H%x1f%B%x1e", `${base}..${head}`],
  { encoding: "utf8" },
);
if (result.status !== 0) {
  process.stderr.write(result.stderr);
  process.exit(result.status ?? 1);
}

const commits = result.stdout
  .split("\x1e")
  .map((record) => record.trim())
  .filter(Boolean)
  .map((record) => {
    const separator = record.indexOf("\x1f");
    return {
      sha: record.slice(0, separator),
      message: record.slice(separator + 1),
    };
  });

const signoff = /^Signed-off-by:\s+.+\s+<[^<>\s]+@[^<>\s]+>\s*$/im;
const unsigned = commits.filter((commit) => !signoff.test(commit.message));

if (unsigned.length > 0) {
  console.error("Every pull-request commit must include a DCO sign-off:");
  for (const commit of unsigned) console.error(`- ${commit.sha}`);
  console.error("Amend each commit with `git commit --amend -s` and rebase as needed.");
  process.exit(1);
}

console.log(`DCO sign-off: ${commits.length} commit(s) checked`);
