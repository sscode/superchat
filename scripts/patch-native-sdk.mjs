import { readFile, writeFile } from "node:fs/promises";

const path = new URL("../node_modules/@native-sdk/cli/src/primitives/canvas/ui_markup.zig", import.meta.url);
const source = await readFile(path, "utf8");
const original =
  "pub fn canonicalizeComptime(comptime document: MarkupDocument) MarkupDocument {\n" +
  "    comptime {\n" +
  "        @setEvalBranchQuota(comptime_parse_quota_base +\n" +
  "            (documentByteSize(document) + 1) * comptime_canonicalize_quota_per_byte);";
const patched =
  "pub fn canonicalizeComptime(comptime document: MarkupDocument) MarkupDocument {\n" +
  "    comptime {\n" +
  "        // documentByteSize is recursive, so it needs headroom before it can\n" +
  "        // calculate the source-scaled canonicalization quota.\n" +
  "        @setEvalBranchQuota(comptime_parse_quota_base);\n" +
  "        const document_byte_size = documentByteSize(document);\n" +
  "        @setEvalBranchQuota(comptime_parse_quota_base +\n" +
  "            (document_byte_size + 1) * comptime_canonicalize_quota_per_byte);";

if (source.includes(patched)) process.exit(0);
if (!source.includes(original)) {
  throw new Error("Native SDK canonicalization layout changed; review and remove the Superchat quota patch.");
}
await writeFile(path, source.replace(original, patched));
