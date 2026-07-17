import { readFile, writeFile } from "node:fs/promises";

async function patchFile(path, original, patched, errorMessage) {
  const source = await readFile(path, "utf8");
  if (source.includes(patched)) return;
  if (!source.includes(original)) throw new Error(errorMessage);
  await writeFile(path, source.replace(original, patched));
}

const markupPath = new URL("../node_modules/@native-sdk/cli/src/primitives/canvas/ui_markup.zig", import.meta.url);
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

await patchFile(
  markupPath,
  original,
  patched,
  "Native SDK canonicalization layout changed; review and remove the Superchat quota patch.",
);

const flowPath = new URL("../node_modules/@native-sdk/cli/src/runtime/flow.zig", import.meta.url);
const shortcutOriginal = `                .shortcut => |shortcut| {
                    try dispatchCommand(self, app, .{
                        .name = shortcut.id,
                        .source = .shortcut,
                        .window_id = shortcut.window_id,
                    });
                    try dispatchEvent(self, app, .{ .shortcut = shortcut });`;
const shortcutPatched = `                .shortcut => |shortcut| {
                    // The host recognizes registered shortcuts before its GPU
                    // canvas receives the key and consumes the native event.
                    // Give a focused text entry first refusal here: replaying
                    // the chord through the ordinary canvas keyboard path
                    // preserves editing commands such as select-all, while
                    // every other app shortcut is structurally consumed by
                    // the editor instead of mutating workspace state.
                    const editor_consumed = try dispatchShortcutToFocusedTextEntry(self, app, shortcut);
                    if (!editor_consumed) {
                        try dispatchCommand(self, app, .{
                            .name = shortcut.id,
                            .source = .shortcut,
                            .window_id = shortcut.window_id,
                        });
                    }
                    try dispatchEvent(self, app, .{ .shortcut = shortcut });`;

await patchFile(
  flowPath,
  shortcutOriginal,
  shortcutPatched,
  "Native SDK shortcut dispatch changed; review the Superchat focused-editor shortcut patch.",
);

const helperOriginal = `        pub fn dispatchEvent(self: *Runtime, app: App, event_value: Event) anyerror!void {`;
const helperPatched = `        fn dispatchShortcutToFocusedTextEntry(self: *Runtime, app: App, shortcut: platform.ShortcutEvent) !bool {
            for (self.views[0..self.view_count]) |*view| {
                if (!view.open or view.window_id != shortcut.window_id or view.kind != .gpu_surface or !view.focused) continue;
                const focused_id = view.canvas_widget_focused_id;
                if (focused_id == 0) continue;
                const node = view.widgetLayoutTree().findById(focused_id) orelse continue;
                if (!canvas.isWidgetTextEntry(node.widget) or node.widget.state.disabled) continue;

                // Automation can dispatch a shortcut by command id without a
                // physical key. It should still respect editor focus, but
                // there is no editing chord to replay in that case.
                if (shortcut.key.len > 0) {
                    try GpuSurfaceEventMethods().dispatchGpuSurfaceInput(self, app, .{
                        .window_id = shortcut.window_id,
                        .label = view.label,
                        .kind = .key_down,
                        .key = shortcut.key,
                        .modifiers = shortcut.modifiers,
                    });
                }
                return true;
            }
            return false;
        }

        pub fn dispatchEvent(self: *Runtime, app: App, event_value: Event) anyerror!void {`;

await patchFile(
  flowPath,
  helperOriginal,
  helperPatched,
  "Native SDK runtime flow changed; review the Superchat focused-editor helper patch.",
);

const scrollRuntimePath = new URL(
  "../node_modules/@native-sdk/cli/src/runtime/canvas_widget_runtime.zig",
  import.meta.url,
);
const nativeScrollClampOriginal = `        // Native scroll drivers own clamping: the OS scroller constrains
        // its own contentOffset (including mid-rubber-band rebuilds, which
        // an engine clamp here would fight) and reports the settled offset
        // back through the driver event.
        if (node.widget.native_scroll) continue;

        const viewport = node.frame.inset(node.widget.layout.padding).normalized();`;
const nativeScrollClampPatched = `        // Superchat's scroll regions use the default pinned edge behavior.
        // Clamp source-driven jumps in the engine as well as in the native
        // driver so a jump-to-end sentinel never reaches descendant paint
        // geometry while AppKit is settling its content offset.

        const viewport = node.frame.inset(node.widget.layout.padding).normalized();`;

await patchFile(
  scrollRuntimePath,
  nativeScrollClampOriginal,
  nativeScrollClampPatched,
  "Native SDK scroll clamping changed; review the Superchat programmatic-scroll patch.",
);
