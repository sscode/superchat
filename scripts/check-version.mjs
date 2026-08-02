// SPDX-License-Identifier: AGPL-3.0-only

import { readFile } from "node:fs/promises";

const packageJson = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
const packageLock = JSON.parse(await readFile(new URL("../package-lock.json", import.meta.url), "utf8"));
const sources = {
  "app.zon": await readFile(new URL("../app.zon", import.meta.url), "utf8"),
  "build.zig": await readFile(new URL("../build.zig", import.meta.url), "utf8"),
  "build.zig.zon": await readFile(new URL("../build.zig.zon", import.meta.url), "utf8"),
  "src/mcp.zig": await readFile(new URL("../src/mcp.zig", import.meta.url), "utf8"),
};

const expected = packageJson.version;
const discovered = {
  "package.json": packageJson.version,
  "package-lock.json": packageLock.version,
  "package-lock.json root package": packageLock.packages?.[""]?.version,
  "app.zon": sources["app.zon"].match(/\.version\s*=\s*"([^"]+)"/)?.[1],
  "build.zig": sources["build.zig"].match(/addOption\(\[\]const u8,\s*"version",\s*"([^"]+)"\)/)?.[1],
  "build.zig.zon": sources["build.zig.zon"].match(/\.version\s*=\s*"([^"]+)"/)?.[1],
  "src/mcp.zig": sources["src/mcp.zig"].match(/clientInfo.*?version.*?([0-9]+\.[0-9]+\.[0-9]+)/)?.[1],
};

const mismatches = Object.entries(discovered).filter(([, value]) => value !== expected);
if (mismatches.length > 0) {
  for (const [name, value] of mismatches) {
    console.error(`${name}: expected ${expected}, found ${value ?? "no version"}`);
  }
  process.exitCode = 1;
} else if (packageJson.license !== "AGPL-3.0-only" || packageLock.packages?.[""]?.license !== "AGPL-3.0-only") {
  console.error("package metadata must use AGPL-3.0-only");
  process.exitCode = 1;
} else {
  console.log(`version metadata: ${expected}`);
}
