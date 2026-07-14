const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const persistence = @import("persistence.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;
const AppMarkup = canvas.MarkupView(main.Model, main.Msg);

fn buildTree(arena: std.mem.Allocator, model: *const main.Model) !main.AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = main.AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn buildCompiledTree(arena: std.mem.Allocator, model: *const main.Model) !main.AppUi.Tree {
    comptime {
        @setEvalBranchQuota(1_000_000);
        _ = main.CompiledAppView.document;
    }
    var ui = main.AppUi.init(arena);
    return ui.finalize(main.CompiledAppView.build(&ui, model));
}

fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

fn activeThread(model: *main.Model) *main.Thread {
    for (model.threads[0..model.thread_count]) |*thread| {
        if (thread.id == model.active_thread_id) return thread;
    }
    unreachable;
}

fn threadWithId(model: *main.Model, thread_id: u32) *main.Thread {
    for (model.threads[0..model.thread_count]) |*thread| {
        if (thread.id == thread_id) return thread;
    }
    unreachable;
}

fn projectWithId(model: *main.Model, project_id: u32) *main.Project {
    for (model.projects[0..model.project_count]) |*project| {
        if (project.id == project_id) return project;
    }
    unreachable;
}

fn streamLine(model: *main.Model, fx: *main.Effects, key: u64, line: []const u8) void {
    main.update(model, .{ .stream_line = .{ .key = key, .line = line } }, fx);
}

fn removeTestDatabase(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};
    var buffer: [256]u8 = undefined;
    for ([_][]const u8{ "-wal", "-shm", ".backup-v1", ".backup-v2", ".backup-v3", ".backup-v4", ".backup-v5" }) |suffix| {
        const sidecar = std.fmt.bufPrint(&buffer, "{s}{s}", .{ path, suffix }) catch continue;
        std.Io.Dir.deleteFileAbsolute(testing.io, sidecar) catch {};
    }
}

test "schema migrations create a recoverable pre-migration backup" {
    const path = "/tmp/superchat-migration-backup.sqlite3";
    removeTestDatabase(path);
    defer removeTestDatabase(path);
    {
        var database = try main.workspace_storage.Database.open(path);
        try database.setSchemaVersionForTest(1);
        database.close();
    }
    {
        var migrated = try main.workspace_storage.Database.open(path);
        defer migrated.close();
        try testing.expectEqual(@as(i64, 6), try migrated.schemaVersion());
    }
    var backup = try std.Io.Dir.openFileAbsolute(testing.io, path ++ ".backup-v1", .{});
    backup.close(testing.io);
}

test "send creates a typed OpenRouter fetch and preserves the user turn" {
    var model = main.initialModel("test-key");
    activeThread(&model).draft_buffer.set("Hello from Native SDK");

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .send, &fx);

    const thread = activeThread(&model);
    try testing.expect(thread.sending);
    try testing.expectEqual(@as(usize, 1), thread.message_count);
    try testing.expectEqualStrings("Hello from Native SDK", thread.messages[0].content());
    try testing.expect(thread.draft_buffer.isEmpty());

    const request = fx.pendingFetchAt(0) orelse return error.TestExpectedFetch;
    try testing.expectEqual(std.http.Method.POST, request.method);
    try testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", request.url);
    try testing.expectEqual(native_sdk.FetchResponseMode.stream, request.response);
    try testing.expect(std.mem.indexOf(u8, request.body, "\"model\":\"openrouter/auto\"") != null);
    try testing.expect(std.mem.indexOf(u8, request.body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, request.body, "Hello from Native SDK") != null);
    try testing.expect(std.mem.indexOf(u8, request.body, "test-key") == null);
}

test "dropped images become removable multimodal OpenRouter attachments" {
    var model = main.initialModel("test-key");
    defer model.deinit();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const paths = [_][]const u8{"/tmp/example.png"};
    main.update(&model, .{ .files_dropped = .{ .paths = &paths } }, &fx);
    const read = fx.pendingFileAt(0) orelse return error.TestExpectedFileRead;
    try testing.expectEqual(native_sdk.EffectFileOp.read, read.op);
    try testing.expectEqualStrings(paths[0], read.path);

    const png = "small-png-payload";
    main.update(&model, .{ .attachment_file_result = .{ .key = read.key, .bytes = png } }, &fx);
    const thread = activeThread(&model);
    try testing.expectEqual(@as(usize, 1), thread.draft_attachment_count);
    try testing.expectEqualStrings("example.png", thread.draft_attachments[0].name());
    try testing.expectEqualStrings(png, thread.draft_attachments[0].bytes);

    thread.draft_buffer.set("What is in this image?");
    main.update(&model, .send, &fx);
    try testing.expectEqual(@as(usize, 1), thread.messages[0].attachment_count);
    try testing.expectEqual(@as(usize, 0), thread.draft_attachment_count);

    var write: ?main.Effects.FileRequest = null;
    for (0..fx.pendingFileCount()) |index| {
        const candidate = fx.pendingFileAt(index) orelse continue;
        if (candidate.op == .write) write = candidate;
    }
    const request_file = write orelse return error.TestExpectedFileWrite;
    try testing.expect(std.mem.indexOf(u8, request_file.bytes, "\"type\":\"image_url\"") != null);
    try testing.expect(std.mem.indexOf(u8, request_file.bytes, "data:image/png;base64,") != null);
    try testing.expect(std.mem.indexOf(u8, request_file.bytes, "c21hbGwtcG5nLXBheWxvYWQ=") != null);
    try testing.expect(std.mem.indexOf(u8, request_file.bytes, "test-key") == null);
}

test "attachment metadata survives a SQLite restart without storing file contents" {
    const path = "/tmp/superchat-attachments.sqlite3";
    removeTestDatabase(path);
    defer removeTestDatabase(path);

    var model = main.initialModel("");
    defer model.deinit();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    const paths = [_][]const u8{"/tmp/notes.md"};
    main.update(&model, .{ .files_dropped = .{ .paths = &paths } }, &fx);
    const read = fx.pendingFileAt(0) orelse return error.TestExpectedFileRead;
    main.update(&model, .{ .attachment_file_result = .{ .key = read.key, .bytes = "# Local notes" } }, &fx);

    {
        var database = try main.workspace_storage.Database.open(path);
        defer database.close();
        try database.save(&model);
    }

    var restored = main.initialModel("");
    defer restored.deinit();
    {
        var database = try main.workspace_storage.Database.open(path);
        defer database.close();
        try testing.expect(try database.load(&restored));
    }
    const thread = activeThread(&restored);
    try testing.expectEqual(@as(usize, 1), thread.draft_attachment_count);
    try testing.expectEqualStrings("notes.md", thread.draft_attachments[0].name());
    try testing.expectEqualStrings(paths[0], thread.draft_attachments[0].path());
    try testing.expectEqual(@as(usize, 0), thread.draft_attachments[0].bytes.len);
}

test "Return sends while Command Return inserts a new line" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    activeThread(&model).draft_buffer.set("Send this now");
    main.update(&model, .{ .draft_edit = .{ .insert_text = "\n" } }, &fx);
    try testing.expectEqual(@as(usize, 1), activeThread(&model).message_count);
    try testing.expectEqualStrings("Send this now", activeThread(&model).messages[0].content());
    try testing.expect(activeThread(&model).draft_buffer.isEmpty());
    try testing.expect(fx.pendingFetchAt(0) != null);

    main.update(&model, .new_thread, &fx);
    activeThread(&model).draft_buffer.set("Keep writing");
    main.update(&model, .composer_newline, &fx);
    try testing.expectEqualStrings("Keep writing\n", activeThread(&model).draft());
    try testing.expectEqual(@as(usize, 0), activeThread(&model).message_count);

    main.update(&model, .{ .draft_edit = .{ .insert_text = "pasted\nlines" } }, &fx);
    try testing.expectEqualStrings("Keep writing\npasted\nlines", activeThread(&model).draft());
    try testing.expectEqual(@as(usize, 0), activeThread(&model).message_count);
}

test "a completion appends assistant text and records the routed model" {
    var model = main.initialModel("test-key");
    activeThread(&model).draft_buffer.set("Hello");

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .send, &fx);

    streamLine(&model, &fx, 1001, ": OPENROUTER PROCESSING");
    streamLine(&model, &fx, 1001, "event: message");
    streamLine(&model, &fx, 1001, "id: response-1");
    streamLine(&model, &fx, 1001, "data: {\"model\":\"anthropic/claude-sonnet-4.6\",\"choices\":[{\"delta\":{\"content\":\"Hi \"}}]}");
    try testing.expectEqual(@as(usize, 1), activeThread(&model).message_count);
    try testing.expectEqualStrings("Hi ", activeThread(&model).stream_pending_storage[0..activeThread(&model).stream_pending_len]);
    try testing.expect(activeThread(&model).sending);
    streamLine(&model, &fx, 1001, "data: {\"choices\":[{\"delta\":{\"content\":\"there!\"}}]}");
    streamLine(&model, &fx, 1001, "data: [DONE]");
    main.update(&model, .{ .response = .{
        .key = 1001,
        .status = 200,
    } }, &fx);

    const thread = activeThread(&model);
    try testing.expect(!thread.sending);
    try testing.expectEqual(@as(usize, 2), thread.message_count);
    try testing.expectEqualStrings("Hi there!", thread.messages[1].content());
    try testing.expectEqualStrings("anthropic/claude-sonnet-4.6", thread.active_model_storage[0..thread.active_model_len]);
}

test "an in-flight response keeps its provider identity stable" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    activeThread(&model).draft_buffer.set("Keep this request on its original model");
    main.update(&model, .send, &fx);
    main.update(&model, .{ .select_model = .codex_subscription }, &fx);

    try testing.expectEqual(main.ModelChoice.auto, activeThread(&model).model_choice);
    try testing.expectEqualStrings("Wait for the current response before changing models", activeThread(&model).status_storage[0..activeThread(&model).status_len]);
}

test "the empty and populated views build and lay out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel("");
    var tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByKind(tree.root, .textarea) != null);
    try testing.expect(findByKind(tree.root, .status_bar) != null);

    var nodes: [240]canvas.WidgetLayoutNode = undefined;
    const empty_layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, main.window_width, main.window_height), &nodes);
    try testing.expect(empty_layout.nodes.len > 0);
    const minimum_layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, main.window_min_width, main.window_min_height), &nodes);
    try testing.expect(minimum_layout.nodes.len > 0);

    try testing.expect(model.appendMessage(.user, "Does the populated thread render?"));
    try testing.expect(model.appendMessage(.assistant, "Yes — with **Markdown** too."));
    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByKind(tree.root, .bubble) != null);
}

test "the release-compiled view builds and lays out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = main.initialModel("");
    const tree = try buildCompiledTree(arena_state.allocator(), &model);
    try testing.expect(findByKind(tree.root, .textarea) != null);
    var nodes: [240]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, main.window_width, main.window_height), &nodes);
    try testing.expect(layout.nodes.len > 0);
}

test "missing credentials disable send" {
    var model = main.initialModel("");
    activeThread(&model).draft_buffer.set("This should not leave the app");
    try testing.expect(!model.canSend());

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .send, &fx);
    try testing.expectEqual(@as(usize, 0), activeThread(&model).message_count);
    try testing.expect(fx.pendingFetchAt(0) == null);
}

test "CLI models cannot send until their provider is connected" {
    var model = main.initialModel("");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .{ .select_model = .codex_subscription }, &fx);
    activeThread(&model).draft_buffer.set("Wait for sign-in");
    try testing.expect(!model.canSend());
    main.update(&model, .send, &fx);
    try testing.expect(fx.pendingSpawnAt(0) == null);
    try testing.expectEqual(@as(usize, 0), activeThread(&model).message_count);
    try testing.expectEqualStrings("Connect Codex in Settings before sending", activeThread(&model).status_storage[0..activeThread(&model).status_len]);
}

test "Codex subscription threads run through the signed-in CLI without an API key" {
    var model = main.initialModel("");
    model.codex_connection = .connected;
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .{ .select_model = .codex_subscription }, &fx);
    activeThread(&model).draft_buffer.set("Answer from my ChatGPT account");
    try testing.expect(model.canSend());
    main.update(&model, .send, &fx);

    const request = fx.pendingSpawnAt(0) orelse return error.TestExpectedSpawn;
    try testing.expectEqualStrings("/bin/zsh", request.argv[0]);
    try testing.expect(std.mem.indexOf(u8, request.argv[2], "ChatGPT.app") != null);
    try testing.expectEqualStrings("exec", request.argv[4]);
    try testing.expect(std.mem.indexOf(u8, request.stdin, "Answer from my ChatGPT account") != null);
    try testing.expect(std.mem.indexOf(u8, request.stdin, "API key") == null);

    main.update(&model, .{ .harness_line = .{
        .key = request.key,
        .line = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Codex answer\"}}",
    } }, &fx);
    main.update(&model, .{ .harness_exit = .{ .key = request.key, .code = 0 } }, &fx);
    try testing.expectEqual(@as(usize, 2), activeThread(&model).message_count);
    try testing.expectEqualStrings("Codex answer", activeThread(&model).messages[1].content());
    try testing.expect(!activeThread(&model).sending);
    try testing.expectEqual(main.ConnectionState.connected, model.codex_connection);
}

test "Claude subscription threads stream text deltas through Claude Code" {
    var model = main.initialModelWithMode("", true);
    model.claude_connection = .connected;
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .{ .select_model = .claude_subscription }, &fx);
    activeThread(&model).draft_buffer.set("Answer from Claude");
    main.update(&model, .send, &fx);
    const request = fx.pendingSpawnAt(0) orelse return error.TestExpectedSpawn;
    try testing.expect(std.mem.indexOf(u8, request.argv[2], "--output-format stream-json") != null);
    try testing.expect(std.mem.indexOf(u8, request.argv[2], "--tools \"\"") != null);

    main.update(&model, .{ .harness_line = .{
        .key = request.key,
        .line = "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Claude answer\"}}}",
    } }, &fx);
    main.update(&model, .{ .harness_exit = .{ .key = request.key, .code = 0 } }, &fx);
    try testing.expectEqualStrings("Claude answer", activeThread(&model).messages[1].content());
}

test "Claude subscription routing stays disabled outside development builds" {
    var model = main.initialModel("");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .select_claude_subscription, &fx);
    try testing.expectEqual(main.ModelChoice.auto, activeThread(&model).model_choice);
    try testing.expect(model.claudeSubscriptionDisabled());
}

test "subscription connection buttons use provider-owned browser login" {
    var model = main.initialModel("");
    model.onboarding_open = true;
    model.codex_connection = .disconnected;
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .connect_codex, &fx);
    const request = fx.pendingSpawnAt(0) orelse return error.TestExpectedSpawn;
    try testing.expectEqualStrings("login", request.argv[4]);
    try testing.expectEqual(main.ConnectionState.connecting, model.codex_connection);
    main.update(&model, .{ .connection_exit = .{ .key = request.key, .code = 0 } }, &fx);
    try testing.expectEqual(main.ConnectionState.connected, model.codex_connection);
    try testing.expect(!model.onboarding_open);
    try testing.expectEqual(main.CredentialAction.complete_onboarding, model.credential_action);
}

test "provider login completion configures the chat that started it" {
    var model = main.initialModel("");
    model.codex_connection = .disconnected;
    const originating_thread_id = model.active_thread_id;
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .connect_codex, &fx);
    const request = fx.pendingSpawnAt(0) orelse return error.TestExpectedSpawn;
    try testing.expectEqual(originating_thread_id, model.codex_login_thread_id);

    main.update(&model, .new_thread, &fx);
    const navigated_thread_id = model.active_thread_id;
    try testing.expect(navigated_thread_id != originating_thread_id);
    main.update(&model, .connect_codex, &fx);
    try testing.expect(fx.pendingSpawnAt(1) == null);

    main.update(&model, .{ .connection_exit = .{ .key = request.key, .code = 0 } }, &fx);
    try testing.expectEqual(main.ModelChoice.codex_subscription, threadWithId(&model, originating_thread_id).model_choice);
    try testing.expectEqual(main.ModelChoice.auto, threadWithId(&model, navigated_thread_id).model_choice);
    try testing.expectEqual(navigated_thread_id, model.active_thread_id);
    try testing.expectEqual(@as(u32, 0), model.codex_login_thread_id);
}

test "API key can be entered and replaced inside settings without rendering the secret" {
    var model = main.initialModel("");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .open_settings, &fx);
    try testing.expect(model.settings_open);
    main.update(&model, .{ .api_key_edit = .{ .insert_text = "sk-or-v1-in-app" } }, &fx);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const masked = model.apiKeyField(arena_state.allocator());
    try testing.expectEqual(model.api_key_buffer.text().len, masked.len);
    try testing.expect(std.mem.indexOf(u8, masked, "sk-or") == null);
    for (masked) |byte| try testing.expectEqual(@as(u8, '*'), byte);

    main.update(&model, .save_settings, &fx);
    try testing.expect(model.settings_open and model.missingKey());
    const validation = fx.pendingFetchAt(0) orelse return error.TestExpectedFetch;
    main.update(&model, .{ .response = .{ .key = validation.key, .status = 200 } }, &fx);
    try testing.expect(!model.settings_open);
    try testing.expect(!model.missingKey());
    try testing.expect(model.api_key_buffer.isEmpty());
    for (model.api_key_buffer.storage) |byte| try testing.expectEqual(@as(u8, 0), byte);

    activeThread(&model).draft_buffer.set("Use the in-app credential");
    main.update(&model, .send, &fx);
    const request = fx.pendingFetchAt(1) orelse return error.TestExpectedFetch;
    try testing.expect(std.mem.indexOf(u8, request.body, "sk-or-v1-in-app") == null);
}

test "model selector applies quick picks and custom slugs" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    const first_thread = model.active_thread_id;

    main.update(&model, .{ .select_model = .gpt }, &fx);
    try testing.expectEqual(main.ModelChoice.gpt, activeThread(&model).model_choice);
    try testing.expectEqualStrings("openai/gpt-5.5", model.modelName());
    try testing.expectEqualStrings("GPT-5.5", model.selectedModelLabel());

    main.update(&model, .{ .select_model = .custom }, &fx);
    try testing.expect(model.settings_open);
    activeThread(&model).model_buffer.set("mistralai/custom-model");
    main.update(&model, .save_settings, &fx);
    try testing.expectEqual(main.ModelChoice.custom, activeThread(&model).model_choice);
    try testing.expectEqualStrings("mistralai/custom-model", model.selectedModelLabel());

    main.update(&model, .new_thread, &fx);
    try testing.expectEqual(main.ModelChoice.auto, activeThread(&model).model_choice);
    main.update(&model, .{ .select_thread = first_thread }, &fx);
    try testing.expectEqual(main.ModelChoice.custom, activeThread(&model).model_choice);
    try testing.expectEqualStrings("mistralai/custom-model", model.selectedModelLabel());
}

test "model picker searches OpenRouter catalog and keeps favorites" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .{ .model_search_edit = .{ .insert_text = "claude" } }, &fx);
    main.update(&model, .{ .model_search = .{ .key = 1 } }, &fx);
    const request = fx.pendingFetchAt(0) orelse return error.TestExpectedFetch;
    try testing.expect(std.mem.indexOf(u8, request.url, "/api/v1/models") != null);
    main.update(&model, .{ .response = .{
        .key = request.key,
        .status = 200,
        .body = "{\"data\":[{\"id\":\"anthropic/claude-test\",\"name\":\"Claude Test\"}]}",
    } }, &fx);
    try testing.expectEqual(@as(usize, 1), model.model_catalog_count);
    try testing.expectEqualStrings("anthropic/claude-test", model.model_catalog[0].slug());
    main.update(&model, .{ .toggle_model_favorite = 0 }, &fx);
    try testing.expect(model.model_catalog[0].favorite);
    main.update(&model, .{ .select_catalog_model = 0 }, &fx);
    try testing.expectEqualStrings("anthropic/claude-test", activeThread(&model).modelName());
}

test "quick model slots map Command Shift 1 through 9 to current OpenRouter slugs" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();

    for (main.quick_model_commands, main.Model.quickModels) |command, option| {
        model.model_picker_open = true;
        const message = main.onCommand(command) orelse return error.TestExpectedShortcut;
        main.update(&model, message, &fx);
        try testing.expectEqualStrings(option.slug, activeThread(&model).modelName());
        try testing.expectEqualStrings(option.label, model.selectedModelLabel());
        try testing.expect(!model.model_picker_open);
    }
}

test "workspace grows past prototype project and chat limits" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    var index: usize = 0;
    while (index < 12) : (index += 1) main.update(&model, .new_project, &fx);
    while (index < 48) : (index += 1) main.update(&model, .new_thread, &fx);
    try testing.expect(model.project_count > 8);
    try testing.expect(model.thread_count > 24);
    try testing.expect(!model.cannotAddProject());
    try testing.expect(!model.cannotAddThread());
}

test "provider status errors are actionable" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    activeThread(&model).sending = true;
    main.update(&model, .{ .response = .{ .key = 1001, .status = 429 } }, &fx);
    try testing.expectEqualStrings("OpenRouter is rate limiting requests; wait a moment and retry", activeThread(&model).status_storage[0..activeThread(&model).status_len]);
}

test "projects and threads preserve independent conversations" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const first_project = model.active_project_id;
    const first_thread = model.active_thread_id;
    activeThread(&model).draft_buffer.set("Plan the native app");
    main.update(&model, .send, &fx);
    streamLine(&model, &fx, 1001, "data: {\"model\":\"openrouter/auto\",\"choices\":[{\"delta\":{\"content\":\"Start with the shell.\"}}]}");
    main.update(&model, .{ .response = .{
        .key = 1001,
        .status = 200,
    } }, &fx);
    try testing.expectEqualStrings("Plan the native app", model.activeThreadTitle());

    main.update(&model, .new_thread, &fx);
    const second_thread = model.active_thread_id;
    try testing.expect(second_thread != first_thread);
    try testing.expectEqual(@as(usize, 0), activeThread(&model).message_count);
    try testing.expectEqualStrings("New chat", model.activeThreadTitle());

    main.update(&model, .{ .select_thread = first_thread }, &fx);
    try testing.expectEqual(@as(usize, 2), activeThread(&model).message_count);
    try testing.expectEqualStrings("Plan the native app", activeThread(&model).messages[0].content());
    try testing.expectEqualStrings("Start with the shell.", activeThread(&model).messages[1].content());

    main.update(&model, .new_project, &fx);
    try testing.expect(model.active_project_id != first_project);
    try testing.expectEqual(@as(usize, 2), model.project_count);
    try testing.expectEqual(@as(usize, 3), model.thread_count);

    main.update(&model, .select_top_level_chats, &fx);
    try testing.expectEqual(first_project, model.active_project_id);
    try testing.expectEqual(first_thread, model.active_thread_id);
    var rows_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer rows_arena.deinit();
    const rows = model.topLevelThreadRows(rows_arena.allocator());
    try testing.expectEqual(@as(usize, 2), rows.len);
}

test "top-level and project chats have distinct creation paths" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();

    try testing.expectEqual(main.chats_project_id, model.active_project_id);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 1), model.topLevelThreadRows(arena_state.allocator()).len);
    try testing.expectEqual(@as(usize, 0), model.projectSidebarRows(arena_state.allocator()).len);

    main.update(&model, .new_project, &fx);
    try testing.expect(model.composer_focus_flip);
    const project_id = model.active_project_id;
    const first_project_thread = model.active_thread_id;
    try testing.expect(project_id != main.chats_project_id);

    main.update(&model, .new_project_thread, &fx);
    try testing.expect(!model.composer_focus_flip);
    const second_project_thread = model.active_thread_id;
    try testing.expect(second_project_thread != first_project_thread);
    try testing.expectEqual(project_id, activeThread(&model).project_id);
    _ = arena_state.reset(.retain_capacity);
    try testing.expectEqual(@as(usize, 3), model.projectSidebarRows(arena_state.allocator()).len);

    main.update(&model, .new_thread, &fx);
    try testing.expect(model.composer_focus_flip);
    try testing.expectEqual(main.chats_project_id, model.active_project_id);
    try testing.expectEqual(main.chats_project_id, activeThread(&model).project_id);
    _ = arena_state.reset(.retain_capacity);
    try testing.expectEqual(@as(usize, 2), model.topLevelThreadRows(arena_state.allocator()).len);
    try testing.expectEqual(@as(usize, 3), model.projectSidebarRows(arena_state.allocator()).len);

    main.update(&model, .open_rename_project, &fx);
    try testing.expect(!model.rename_open);
    main.update(&model, .archive_project, &fx);
    try testing.expectEqual(main.chats_project_id, model.active_project_id);
}

test "project chats are grouped directly beneath their project" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    main.update(&model, .new_project, &fx);
    const first_project = model.active_project_id;
    const first_project_thread = model.active_thread_id;
    main.update(&model, .new_project_thread, &fx);
    const second_first_project_thread = model.active_thread_id;
    main.update(&model, .new_project, &fx);
    const second_project = model.active_project_id;
    const second_project_thread = model.active_thread_id;

    const rows = model.projectSidebarRows(arena_state.allocator());
    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expectEqualStrings("", rows[0].prefix);
    try testing.expectEqual(first_project, rows[0].id);
    try testing.expectEqualStrings(projectWithId(&model, first_project).name(), rows[0].title);
    try testing.expect(rows[1].prefix.len > 0);
    try testing.expect(std.mem.indexOfScalar(u8, rows[1].prefix, '-') == null);
    try testing.expectEqual(first_project_thread, rows[1].id);
    try testing.expect(rows[2].prefix.len > 0);
    try testing.expectEqual(second_first_project_thread, rows[2].id);
    try testing.expectEqualStrings("", rows[3].prefix);
    try testing.expectEqual(second_project, rows[3].id);
    try testing.expectEqualStrings(projectWithId(&model, second_project).name(), rows[3].title);
    try testing.expect(rows[4].prefix.len > 0);
    try testing.expectEqual(second_project_thread, rows[4].id);

    main.update(&model, .{ .select_sidebar_row = rows[1].key }, &fx);
    try testing.expectEqual(first_project, model.active_project_id);
    try testing.expectEqual(first_project_thread, model.active_thread_id);
    main.update(&model, .{ .select_sidebar_row = rows[3].key }, &fx);
    try testing.expectEqual(second_project, model.active_project_id);
    try testing.expectEqual(second_project_thread, model.active_thread_id);
}

test "loading repairs a stale active project from the active chat" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    main.update(&model, .new_project, &fx);
    const project_thread_id = model.active_thread_id;
    const project_id = model.active_project_id;
    model.active_project_id = main.chats_project_id;
    model.active_thread_id = project_thread_id;

    try testing.expect(main.normalizeLoadedWorkspace(&model));
    try testing.expectEqual(project_id, model.active_project_id);
    try testing.expectEqual(project_thread_id, model.active_thread_id);
}

test "loading removes model suffixes from legacy fork titles" {
    var model = main.initialModel("test-key");
    const legacy_title = "hi · Claude Sonnet 5";
    const thread = activeThread(&model);
    thread.model_choice = .claude_sonnet;
    @memcpy(thread.title_storage[0..legacy_title.len], legacy_title);
    thread.title_len = legacy_title.len;

    try testing.expect(main.normalizeLoadedWorkspace(&model));
    try testing.expectEqualStrings("hi", thread.title());
    try testing.expect(model.persistence_structure_dirty);
}

test "projects and chats can be renamed without changing their identity" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .new_project, &fx);
    const project_id = model.active_project_id;
    const thread_id = model.active_thread_id;
    main.update(&model, .open_rename_project, &fx);
    try testing.expect(model.rename_open);
    model.rename_buffer.clear();
    main.update(&model, .{ .rename_edit = .{ .insert_text = "  Client launch  " } }, &fx);
    main.update(&model, .save_rename, &fx);
    try testing.expectEqual(project_id, model.active_project_id);
    try testing.expectEqualStrings("Client launch", projectWithId(&model, project_id).name());

    main.update(&model, .open_rename_thread, &fx);
    model.rename_buffer.clear();
    main.update(&model, .{ .rename_edit = .{ .insert_text = "Release checklist" } }, &fx);
    main.update(&model, .save_rename, &fx);
    try testing.expectEqual(thread_id, model.active_thread_id);
    try testing.expectEqualStrings("Release checklist", threadWithId(&model, thread_id).title());
}

test "archived chats leave the workspace and can be restored" {
    var test_clock: native_sdk.TestClock = .{};
    test_clock.setWallMs(1_700_000_000_000);
    var model = main.initialModelWithClock("test-key", test_clock.clock());
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const archived_id = model.active_thread_id;
    activeThread(&model).draft_buffer.set("Background request");
    main.update(&model, .send, &fx);
    try testing.expect(activeThread(&model).sending);
    main.update(&model, .archive_thread, &fx);

    try testing.expect(threadWithId(&model, archived_id).isArchived());
    try testing.expect(model.toastVisible());
    try testing.expectEqualStrings("Chat archived", model.toastText());
    const toast_timer = fx.pendingTimerAt(0) orelse return error.TestExpectedTimer;
    try testing.expectEqual(@as(u64, 2200), toast_timer.interval_ms);
    main.update(&model, .{ .dismiss_toast = .{ .key = toast_timer.key } }, &fx);
    try testing.expect(!model.toastVisible());
    try testing.expect(!threadWithId(&model, archived_id).sending);
    try testing.expect(model.active_thread_id != archived_id);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 1), model.topLevelThreadRows(arena_state.allocator()).len);
    const archived = model.archivedThreadRows(arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), archived.len);
    try testing.expectEqualStrings("Deletes in 30 days", archived[0].expiry);

    main.update(&model, .open_archive, &fx);
    const tree = try buildTree(arena_state.allocator(), &model);
    var nodes: [360]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, main.window_min_width, main.window_min_height), &nodes);
    try testing.expect(layout.nodes.len > 0);
    main.update(&model, .{ .restore_thread = archived_id }, &fx);
    try testing.expect(!threadWithId(&model, archived_id).isArchived());
    try testing.expectEqual(archived_id, model.active_thread_id);
    try testing.expect(!model.archive_open);
}

test "archived projects cascade their chats and permanent delete requires confirmation" {
    var test_clock: native_sdk.TestClock = .{};
    test_clock.setWallMs(1_700_000_000_000);
    var model = main.initialModelWithClock("test-key", test_clock.clock());
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .new_project, &fx);
    const archived_project_id = model.active_project_id;
    const child_thread_id = model.active_thread_id;
    main.update(&model, .archive_project, &fx);
    try testing.expect(projectWithId(&model, archived_project_id).isArchived());
    try testing.expectEqualStrings("Project archived", model.toastText());
    try testing.expect(model.active_project_id != archived_project_id);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 1), model.archivedProjectRows(arena_state.allocator()).len);
    try testing.expectEqual(@as(usize, 0), model.archivedThreadRows(arena_state.allocator()).len);

    main.update(&model, .{ .restore_project = archived_project_id }, &fx);
    try testing.expect(!projectWithId(&model, archived_project_id).isArchived());
    try testing.expectEqual(archived_project_id, model.active_project_id);
    main.update(&model, .archive_project, &fx);
    try testing.expect(projectWithId(&model, archived_project_id).isArchived());

    main.update(&model, .{ .delete_project = archived_project_id }, &fx);
    try testing.expect(model.delete_confirm_open);
    try testing.expect(projectWithId(&model, archived_project_id).isArchived());
    main.update(&model, .confirm_delete, &fx);
    try testing.expect(!model.delete_confirm_open);
    try testing.expectEqualStrings("Project deleted permanently", model.toastText());
    for (model.projects[0..model.project_count]) |project| try testing.expect(project.id != archived_project_id);
    for (model.threads[0..model.thread_count]) |thread| try testing.expect(thread.id != child_thread_id);
}

test "archive purges items after thirty days" {
    var test_clock: native_sdk.TestClock = .{};
    test_clock.setWallMs(1_700_000_000_000);
    var model = main.initialModelWithClock("test-key", test_clock.clock());
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const archived_id = model.active_thread_id;
    main.update(&model, .archive_thread, &fx);
    test_clock.advanceMs(29 * 24 * 60 * 60 * 1000);
    main.update(&model, .open_archive, &fx);
    try testing.expect(threadWithId(&model, archived_id).isArchived());

    test_clock.advanceMs(24 * 60 * 60 * 1000);
    main.update(&model, .open_archive, &fx);
    for (model.threads[0..model.thread_count]) |thread| try testing.expect(thread.id != archived_id);
    try testing.expect(model.archiveEmpty());
}

test "SQLite restores the workspace after reopening and purges expired archives" {
    const path = "/tmp/superchat-native-storage-roundtrip.sqlite3";
    removeTestDatabase(path);
    defer removeTestDatabase(path);

    var test_clock: native_sdk.TestClock = .{};
    test_clock.setWallMs(1_700_000_000_000);
    const model = try testing.allocator.create(main.Model);
    defer testing.allocator.destroy(model);
    model.* = main.initialModelWithClock("test-key", test_clock.clock());
    model.notifications_enabled = false;
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(model, .new_project, &fx);
    const persisted_project_id = model.active_project_id;
    const persisted_thread_id = model.active_thread_id;
    try testing.expect(model.appendMessage(.user, "Persist this conversation"));
    try testing.expect(model.appendMessage(.assistant, "Stored locally in SQLite."));
    activeThread(model).messages[1].cost_micros = 789;
    activeThread(model).draft_buffer.set("An unfinished local draft");
    main.update(model, .{ .select_model = .gemini }, &fx);
    main.update(model, .open_rename_project, &fx);
    model.rename_buffer.clear();
    main.update(model, .{ .rename_edit = .{ .insert_text = "Persistent project" } }, &fx);
    main.update(model, .save_rename, &fx);
    main.update(model, .new_project, &fx);
    const archived_project_id = model.active_project_id;
    main.update(model, .archive_project, &fx);
    const archived_at = projectWithId(model, archived_project_id).archived_at_ms;
    main.update(model, .{ .select_project_slot = 1 }, &fx);

    {
        var database = try main.workspace_storage.Database.open(path);
        defer database.close();
        try testing.expectEqual(@as(i64, 6), try database.schemaVersion());
        try database.save(model);
    }

    const restored = try testing.allocator.create(main.Model);
    defer testing.allocator.destroy(restored);
    restored.* = main.initialModelWithClock("", test_clock.clock());
    {
        var database = try main.workspace_storage.Database.open(path);
        defer database.close();
        try testing.expect(try database.load(restored));
        try testing.expectEqual(persisted_project_id, restored.active_project_id);
        try testing.expectEqual(persisted_thread_id, restored.active_thread_id);
        try testing.expectEqualStrings("Persistent project", projectWithId(restored, persisted_project_id).name());
        const thread = threadWithId(restored, persisted_thread_id);
        try testing.expectEqualStrings("An unfinished local draft", thread.draft());
        try testing.expectEqual(main.ModelChoice.gemini, thread.model_choice);
        try testing.expectEqual(@as(usize, 2), thread.message_count);
        try testing.expectEqualStrings("Stored locally in SQLite.", thread.messages[1].content());
        try testing.expectEqual(@as(u64, 789), thread.total_cost_micros);
        try testing.expect(!restored.notifications_enabled);
        try testing.expect(projectWithId(restored, archived_project_id).isArchived());

        // At exactly 30 days, the archived project and its chats cascade away.
        try database.purgeExpired(archived_at);
    }

    const purged = try testing.allocator.create(main.Model);
    defer testing.allocator.destroy(purged);
    purged.* = main.initialModelWithClock("", test_clock.clock());
    {
        var database = try main.workspace_storage.Database.open(path);
        defer database.close();
        try testing.expect(try database.load(purged));
    }
    for (purged.projects[0..purged.project_count]) |project| try testing.expect(project.id != archived_project_id);
}

test "SQLite retains complete history while hydration stays bounded" {
    const path = "/tmp/superchat-complete-history.sqlite3";
    removeTestDatabase(path);
    defer removeTestDatabase(path);

    var source = main.initialModel("test-key");
    const thread_id = source.active_thread_id;
    {
        var database = try main.workspace_storage.Database.open(path);
        defer database.close();
        try database.save(&source);
        var id: u32 = 1;
        while (id <= 64) : (id += 1) {
            var content: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&content, "message {d}", .{id});
            try database.upsertMessage(id, thread_id, @intFromEnum(main.Role.user), text);
        }
        try testing.expectEqual(@as(usize, 64), try database.messageCount(thread_id));
    }

    var restored = main.initialModel("");
    {
        var database = try main.workspace_storage.Database.open(path);
        defer database.close();
        try testing.expect(try database.load(&restored));
        try testing.expectEqual(@as(usize, 64), try database.messageCount(thread_id));
    }
    const thread = threadWithId(&restored, thread_id);
    try testing.expectEqual(@as(usize, 50), thread.message_count);
    try testing.expectEqual(@as(u32, 15), thread.messages[0].id);
    try testing.expectEqual(@as(u32, 64), thread.messages[49].id);
    try testing.expect(thread.has_older_messages);
    var database = try main.workspace_storage.Database.open(path);
    defer database.close();
    var older = try database.loadHistoryBefore(testing.allocator, thread_id, thread.messages[0].id, 50);
    defer older.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 14), older.messages.len);
    try testing.expectEqual(@as(u32, 1), older.messages[0].id);
    try testing.expect(!older.has_more);
}

test "background persistence worker owns and flushes SQLite writes" {
    const path = "/tmp/superchat-background-persistence.sqlite3";
    removeTestDatabase(path);
    defer removeTestDatabase(path);

    var model = main.initialModel("test-key");
    const thread_id = model.active_thread_id;
    var database = try main.workspace_storage.Database.open(path);
    try database.save(&model);
    const worker = try persistence.Worker.create(testing.allocator, database, testing.io);

    try testing.expect(model.appendMessage(.user, "written off the UI thread"));
    const thread = threadWithId(&model, thread_id);
    try testing.expect(worker.enqueueMessage(persistence.MessageRecord.from(thread_id, &thread.messages[0])));
    worker.stopAndDestroy();

    var reopened = try main.workspace_storage.Database.open(path);
    defer reopened.close();
    try testing.expectEqual(@as(usize, 1), try reopened.messageCount(thread_id));
}

test "background persistence commands stay compact" {
    try testing.expect(@sizeOf(persistence.Command) < 1024);
}

test "complete SQLite exports include full chat history and a portable workspace" {
    const database_path = "/tmp/superchat-export.sqlite3";
    const markdown_path = "/tmp/superchat-export.md";
    const json_path = "/tmp/superchat-export.json";
    removeTestDatabase(database_path);
    std.Io.Dir.deleteFileAbsolute(testing.io, markdown_path) catch {};
    std.Io.Dir.deleteFileAbsolute(testing.io, json_path) catch {};
    defer {
        removeTestDatabase(database_path);
        std.Io.Dir.deleteFileAbsolute(testing.io, markdown_path) catch {};
        std.Io.Dir.deleteFileAbsolute(testing.io, json_path) catch {};
    }

    var model = main.initialModel("test-key");
    defer model.deinit();
    try testing.expect(model.appendMessage(.user, "Export this question"));
    try testing.expect(model.appendMessage(.assistant, "Export this answer"));
    const assistant = &activeThread(&model).messages[1];
    assistant.response_model_len = "openai/example".len;
    @memcpy(assistant.response_model_storage[0..assistant.response_model_len], "openai/example");
    assistant.latency_ms = 1250;
    assistant.prompt_tokens = 12;
    assistant.completion_tokens = 34;
    assistant.cost_micros = 456;
    var mcp_server = main.workspace_mcp.Server{ .id = 1 };
    mcp_server.setName("Local tools");
    mcp_server.setCommand("local-tools --stdio");
    model.mcp_servers[0] = mcp_server;
    model.mcp_server_count = 1;

    var database = try main.workspace_storage.Database.open(database_path);
    defer database.close();
    try database.save(&model);
    try database.exportThreadMarkdown(testing.allocator, testing.io, model.active_thread_id, markdown_path);
    try database.exportWorkspaceJson(testing.allocator, testing.io, json_path);

    const markdown = try std.Io.Dir.cwd().readFileAlloc(testing.io, markdown_path, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(markdown);
    try testing.expect(std.mem.indexOf(u8, markdown, "Export this answer") != null);
    try testing.expect(std.mem.indexOf(u8, markdown, "openai/example") != null);

    const json = try std.Io.Dir.cwd().readFileAlloc(testing.io, json_path, testing.allocator, .limited(256 * 1024));
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"format\":\"superchat-workspace\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"version\":2") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"snippets\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"mcp_servers\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "local-tools --stdio") != null);
    try testing.expect(std.mem.indexOf(u8, json, "Export this question") != null);
}

test "draft persistence is debounced per thread" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .{ .draft_edit = .{ .insert_text = "typing" } }, &fx);
    try testing.expectEqual(@as(usize, 0), model.persistence_thread_count);
    const timer = fx.pendingTimerAt(0) orelse return error.TestExpectedTimer;
    try testing.expectEqual(@as(u64, 300), timer.interval_ms);

    main.update(&model, .{ .persist_draft = .{ .key = timer.key } }, &fx);
    try testing.expectEqual(@as(usize, 1), model.persistence_thread_count);
    try testing.expectEqual(model.active_thread_id, model.persistence_thread_ids[0]);
}

test "sending dirties only the new message in a long chat" {
    var model = main.initialModel("test-key");
    defer model.deinit();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    for (0..200) |index| {
        const role: main.Role = if (index % 2 == 0) .user else .assistant;
        try testing.expect(model.appendMessage(role, "Existing history"));
    }
    const new_message_id = model.next_message_id;
    activeThread(&model).draft_buffer.set("Persist only this turn");
    main.update(&model, .send, &fx);
    try testing.expectEqual(@as(usize, 1), model.persistence_message_count);
    try testing.expectEqual(new_message_id, model.persistence_messages[0].message_id);
}

test "database polling follows history work across navigation" {
    var model = main.initialModel("test-key");
    defer model.deinit();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try testing.expect(model.appendMessage(.user, "Newest loaded message"));
    const loading_thread_id = model.active_thread_id;
    activeThread(&model).has_older_messages = true;
    main.update(&model, .load_older, &fx);
    const poll = fx.pendingTimerAt(0) orelse return error.TestExpectedTimer;
    try testing.expectEqual(@as(u64, 1 << 52), poll.key);

    main.update(&model, .new_thread, &fx);
    main.update(&model, .{ .database_poll = .{ .key = poll.key } }, &fx);
    try testing.expect(threadWithId(&model, loading_thread_id).history_loading);
    try testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
}

test "edit and retry safely rewrite a transcript from the selected turn" {
    var model = main.initialModel("test-key");
    defer model.deinit();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try testing.expect(model.appendMessage(.user, "First question"));
    try testing.expect(model.appendMessage(.assistant, "First answer"));
    try testing.expect(model.appendMessage(.user, "Follow-up"));
    try testing.expect(model.appendMessage(.assistant, "Second answer"));
    const thread = activeThread(&model);
    const follow_up_id = thread.messages[2].id;
    main.update(&model, .{ .edit_message = follow_up_id }, &fx);
    try testing.expectEqualStrings("Follow-up", thread.draft());
    try testing.expectEqual(@as(usize, 2), thread.message_count);
    try testing.expectEqual(@as(usize, 1), model.persistence_truncate_count);
    try testing.expectEqual(follow_up_id, model.persistence_truncations[0].from_message_id);

    thread.draft_buffer.set("Edited follow-up");
    main.update(&model, .send, &fx);
    const edited_user_id = thread.messages[2].id;
    streamLine(&model, &fx, 1001, "data: {\"choices\":[{\"delta\":{\"content\":\"Edited answer\"}}]}");
    main.update(&model, .{ .response = .{ .key = 1001, .status = 200 } }, &fx);
    const answer_id = thread.messages[3].id;
    main.update(&model, .{ .retry_message = answer_id }, &fx);
    try testing.expect(thread.sending);
    try testing.expectEqual(@as(usize, 3), thread.message_count);
    try testing.expect(thread.messages[2].id != edited_user_id);
    try testing.expectEqualStrings("Edited follow-up", thread.messages[2].content());
}

test "background completions become unread until their chat is opened" {
    var model = main.initialModel("test-key");
    defer model.deinit();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const background_id = model.active_thread_id;
    activeThread(&model).draft_buffer.set("Work in the background");
    main.update(&model, .send, &fx);
    main.update(&model, .new_thread, &fx);
    streamLine(&model, &fx, 1000 + background_id, "data: {\"choices\":[{\"delta\":{\"content\":\"Finished\"}}]}");
    main.update(&model, .{ .response = .{ .key = 1000 + background_id, .status = 200 } }, &fx);
    try testing.expect(threadWithId(&model, background_id).unread);
    try testing.expectEqual(background_id, model.pending_notification_thread_id);

    main.update(&model, .{ .select_thread = background_id }, &fx);
    try testing.expect(!threadWithId(&model, background_id).unread);
}

test "SQLite search covers messages outside the hydrated UI window" {
    const path = "/tmp/superchat-search.sqlite3";
    removeTestDatabase(path);
    defer removeTestDatabase(path);
    var model = main.initialModel("");
    defer model.deinit();
    var database = try main.workspace_storage.Database.open(path);
    defer database.close();
    try database.save(&model);
    try database.upsertMessage(900, model.active_thread_id, @intFromEnum(main.Role.user), "A uniquely searchable archived thought");
    var page = try database.search(testing.allocator, "uniquely searchable", 10);
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), page.hits.len);
    try testing.expectEqual(model.active_thread_id, page.hits[0].thread_id);
    try testing.expect(std.mem.indexOf(u8, page.hits[0].snippet, "uniquely searchable") != null);
    var literal = try database.search(testing.allocator, "%_", 10);
    defer literal.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), literal.hits.len);
}

test "GitHub release responses expose a newer version in Settings" {
    var model = main.initialModel("");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    main.update(&model, .{ .response = .{
        .key = (1 << 61) + 6,
        .status = 200,
        .body = "{\"tag_name\":\"v0.2.0\",\"html_url\":\"https://github.com/sscode/superchat/releases/tag/v0.2.0\"}",
    } }, &fx);
    try testing.expectEqual(main.UpdateState.available, model.update_state);
    try testing.expectEqualStrings("https://github.com/sscode/superchat/releases/tag/v0.2.0", model.update_url_storage[0..model.update_url_len]);
    main.update(&model, .{ .response = .{
        .key = (1 << 61) + 6,
        .status = 200,
        .body = "{\"tag_name\":\"latest\",\"html_url\":\"https://github.com/sscode/superchat/releases/latest\"}",
    } }, &fx);
    try testing.expectEqual(main.UpdateState.failed, model.update_state);
}

test "background responses return to their owning thread while navigation stays live" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const first_thread = model.active_thread_id;
    activeThread(&model).draft_buffer.set("First background task");
    main.update(&model, .send, &fx);
    try testing.expect(activeThread(&model).sending);
    try testing.expectEqual(@as(u64, 1001), (fx.pendingFetchAt(0) orelse return error.TestExpectedFetch).key);

    // Navigation and a second request remain available while the first
    // thread is waiting.
    main.update(&model, .new_thread, &fx);
    const second_thread = model.active_thread_id;
    try testing.expect(second_thread != first_thread);
    try testing.expect(!activeThread(&model).sending);
    activeThread(&model).draft_buffer.set("Second background task");
    main.update(&model, .send, &fx);
    try testing.expectEqual(@as(u64, 1002), (fx.pendingFetchAt(1) orelse return error.TestExpectedFetch).key);

    main.update(&model, .{ .select_thread = first_thread }, &fx);
    activeThread(&model).draft_buffer.set("Keep this unfinished draft");
    try testing.expect(activeThread(&model).sending);

    // The second response updates its owning thread directly without
    // changing the visible transcript or unfinished draft.
    streamLine(&model, &fx, 1002, "data: {\"model\":\"openai/gpt-5.5\",\"choices\":[{\"delta\":{\"content\":\"Second result\"}}]}");
    main.update(&model, .{ .response = .{
        .key = 1002,
        .status = 200,
    } }, &fx);
    try testing.expectEqual(first_thread, model.active_thread_id);
    try testing.expect(activeThread(&model).sending);
    try testing.expectEqualStrings("Keep this unfinished draft", model.draft());
    try testing.expectEqual(@as(usize, 1), activeThread(&model).message_count);

    main.update(&model, .{ .select_thread = second_thread }, &fx);
    try testing.expect(!activeThread(&model).sending);
    try testing.expectEqual(@as(usize, 2), activeThread(&model).message_count);
    try testing.expectEqualStrings("Second result", activeThread(&model).messages[1].content());

    // The first request can finish later and still lands in thread one.
    streamLine(&model, &fx, 1001, "data: {\"model\":\"openrouter/auto\",\"choices\":[{\"delta\":{\"content\":\"First result\"}}]}");
    main.update(&model, .{ .response = .{
        .key = 1001,
        .status = 200,
    } }, &fx);
    try testing.expectEqual(second_thread, model.active_thread_id);
    main.update(&model, .{ .select_thread = first_thread }, &fx);
    try testing.expect(!activeThread(&model).sending);
    try testing.expectEqual(@as(usize, 2), activeThread(&model).message_count);
    try testing.expectEqualStrings("First result", activeThread(&model).messages[1].content());
    try testing.expectEqualStrings("Keep this unfinished draft", model.draft());
}

test "assistant responses can be copied as a whole" {
    var model = main.initialModel("test-key");
    try testing.expect(model.appendMessage(.user, "Give me a concise answer"));
    try testing.expect(model.appendMessage(.assistant, "A complete response to copy."));
    const response_id = activeThread(&model).messages[1].id;

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .{ .copy_message = response_id }, &fx);

    const request = fx.pendingClipboardAt(0) orelse return error.TestExpectedClipboardWrite;
    try testing.expectEqual(native_sdk.EffectClipboardOp.write, request.op);
    try testing.expectEqualStrings("A complete response to copy.", request.text);
    try testing.expectEqualStrings("Response copied", model.toastText());
}

test "one response can fork into several model-specific chats" {
    var model = main.initialModel("test-key");
    try testing.expect(model.appendMessage(.user, "Design the API"));
    try testing.expect(model.appendMessage(.assistant, "Start with a small provider interface."));
    const source_thread_id = model.active_thread_id;
    const response_id = activeThread(&model).messages[1].id;
    try testing.expect(model.appendMessage(.user, "Now add an unrelated dashboard"));
    try testing.expect(model.appendMessage(.assistant, "That belongs after the API is stable."));

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .{ .open_fork = response_id }, &fx);
    try testing.expect(model.fork_open);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);
    var nodes: [360]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, main.window_min_width, main.window_min_height), &nodes);
    try testing.expect(layout.nodes.len > 0);

    // Replace the default Auto selection with GPT and Gemini.
    main.update(&model, .{ .toggle_fork_model = .auto }, &fx);
    main.update(&model, .{ .toggle_fork_model = .gpt }, &fx);
    main.update(&model, .{ .toggle_fork_model = .gemini }, &fx);
    main.update(&model, .{ .fork_seed_edit = .{ .insert_text = "Compare two implementation strategies" } }, &fx);
    main.update(&model, .create_forks, &fx);

    try testing.expect(!model.fork_open);
    try testing.expectEqual(@as(usize, 3), model.thread_count);
    try testing.expectEqual(@as(usize, 2), fx.activeCount());
    const gpt_thread = activeThread(&model);
    try testing.expectEqual(main.ModelChoice.gpt, gpt_thread.model_choice);
    try testing.expectEqualStrings("Design the API", gpt_thread.title());
    try testing.expect(gpt_thread.sending);
    try testing.expectEqual(@as(usize, 3), gpt_thread.message_count);
    try testing.expectEqualStrings("Start with a small provider interface.", gpt_thread.messages[1].content());
    try testing.expect(gpt_thread.messages[1].id != response_id);
    // Messages after the selected response are deliberately excluded.
    try testing.expectEqualStrings("Compare two implementation strategies", gpt_thread.messages[2].content());

    var gemini_thread_id: u32 = 0;
    for (model.threads[0..model.thread_count]) |thread| {
        if (thread.model_choice == .gemini) gemini_thread_id = thread.id;
    }
    try testing.expect(gemini_thread_id != 0);
    try testing.expect(threadWithId(&model, gemini_thread_id).sending);
    try testing.expect(std.mem.indexOf(u8, (fx.pendingFetchAt(0) orelse return error.TestExpectedFetch).body, "\"model\":\"openai/gpt-5.5\"") != null);
    try testing.expect(std.mem.indexOf(u8, (fx.pendingFetchAt(1) orelse return error.TestExpectedFetch).body, "\"model\":\"google/gemini-3.5-flash\"") != null);

    // The same response can be forked again without sending a message.
    main.update(&model, .{ .select_thread = source_thread_id }, &fx);
    main.update(&model, .{ .open_fork = response_id }, &fx);
    main.update(&model, .create_forks, &fx);
    try testing.expectEqual(@as(usize, 4), model.thread_count);
    try testing.expect(!activeThread(&model).sending);
    try testing.expectEqual(@as(usize, 2), activeThread(&model).message_count);
}

test "clearing an in-flight thread waits for cancellation before allowing reuse" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    activeThread(&model).draft_buffer.set("Cancel this request");
    main.update(&model, .send, &fx);
    try testing.expect(activeThread(&model).sending);

    main.update(&model, .clear, &fx);
    try testing.expectEqual(model.active_thread_id, model.clear_confirm_thread_id);
    try testing.expectEqual(@as(usize, 1), activeThread(&model).message_count);
    main.update(&model, .clear, &fx);
    try testing.expectEqual(@as(u32, 0), model.clear_confirm_thread_id);
    try testing.expect(activeThread(&model).sending);
    try testing.expectEqual(@as(usize, 0), activeThread(&model).message_count);
    try testing.expect(!model.canSend());

    main.update(&model, .{ .response = .{
        .key = 1001,
        .outcome = .cancelled,
    } }, &fx);
    try testing.expect(!activeThread(&model).sending);

    activeThread(&model).draft_buffer.set("Safe to send again");
    try testing.expect(model.canSend());
}

test "clear confirmation cannot carry across chats" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try testing.expect(model.appendMessage(.user, "First chat"));
    main.update(&model, .clear, &fx);
    const first_thread_id = model.active_thread_id;
    try testing.expectEqual(first_thread_id, model.clear_confirm_thread_id);

    main.update(&model, .new_thread, &fx);
    try testing.expect(model.active_thread_id != first_thread_id);
    try testing.expect(model.appendMessage(.user, "Second chat"));
    main.update(&model, .clear, &fx);

    try testing.expectEqual(@as(usize, 1), activeThread(&model).message_count);
    try testing.expectEqual(model.active_thread_id, model.clear_confirm_thread_id);
}

test "a mid-stream OpenRouter error preserves partial text and its explanation" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    activeThread(&model).draft_buffer.set("Start a response");
    main.update(&model, .send, &fx);
    streamLine(&model, &fx, 1001, "data: {\"choices\":[{\"delta\":{\"content\":\"Partial answer\"}}]}");
    streamLine(&model, &fx, 1001, "data: {\"error\":{\"message\":\"Provider disconnected\"},\"choices\":[]}");
    main.update(&model, .{ .response = .{ .key = 1001, .outcome = .cancelled } }, &fx);

    const thread = activeThread(&model);
    try testing.expect(!thread.sending);
    try testing.expectEqual(@as(usize, 2), thread.message_count);
    try testing.expectEqualStrings("Partial answer", thread.messages[1].content());
    try testing.expectEqualStrings("Provider disconnected", thread.status_storage[0..thread.status_len]);
}

test "an incomplete stream is cancelled instead of silently losing text" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    activeThread(&model).draft_buffer.set("Do not return damaged output");
    main.update(&model, .send, &fx);
    main.update(&model, .{ .stream_line = .{
        .key = 1001,
        .line = "data: {cut}",
        .truncated = true,
    } }, &fx);
    main.update(&model, .{ .response = .{ .key = 1001, .outcome = .cancelled } }, &fx);

    const thread = activeThread(&model);
    try testing.expect(!thread.sending);
    try testing.expectEqual(@as(usize, 1), thread.message_count);
    try testing.expectEqualStrings("Streaming response was incomplete; request cancelled", thread.status_storage[0..thread.status_len]);
}

test "the global shortcut map reaches creation navigation focus and settings" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const commands = [_][]const u8{
        main.cmd_new_thread,
        main.cmd_new_project_thread,
        main.cmd_new_project,
        main.cmd_previous_thread,
        main.cmd_next_thread,
        main.cmd_previous_project,
        main.cmd_next_project,
        main.cmd_focus_composer,
        main.cmd_model_picker,
        main.cmd_auto_model,
        main.cmd_top_level_chats,
        main.cmd_load_older,
        main.cmd_move_thread,
        main.cmd_snippets,
        main.cmd_mcp_tools,
        main.cmd_export_thread,
        main.cmd_export_workspace,
        main.cmd_settings,
        main.cmd_fork_latest,
        main.cmd_copy_latest,
        main.cmd_rename_thread,
        main.cmd_rename_project,
        main.cmd_archive_thread,
        main.cmd_archive_project,
        main.cmd_open_archive,
        main.cmd_clear_thread,
        main.cmd_close_overlay,
    };
    for (commands) |command| try testing.expect(main.onCommand(command) != null);
    for (main.project_slot_commands) |command| try testing.expect(main.onCommand(command) != null);
    for (main.thread_slot_commands) |command| try testing.expect(main.onCommand(command) != null);
    for (main.quick_model_commands) |command| try testing.expect(main.onCommand(command) != null);
    try testing.expect(main.onCommand("workspace.unknown") == null);

    main.update(&model, main.onCommand(main.cmd_new_thread).?, &fx);
    const first_project = model.active_project_id;
    const second_thread = model.active_thread_id;
    try testing.expectEqual(@as(usize, 2), model.thread_count);

    main.update(&model, main.onCommand(main.cmd_previous_thread).?, &fx);
    try testing.expect(model.active_thread_id != second_thread);
    main.update(&model, main.onCommand(main.cmd_next_thread).?, &fx);
    try testing.expectEqual(second_thread, model.active_thread_id);

    main.update(&model, main.onCommand(main.cmd_new_project).?, &fx);
    const second_project = model.active_project_id;
    try testing.expect(second_project != first_project);
    const first_project_thread = model.active_thread_id;
    main.update(&model, main.onCommand(main.cmd_new_project_thread).?, &fx);
    try testing.expect(model.active_thread_id != first_project_thread);
    try testing.expectEqual(second_project, activeThread(&model).project_id);
    main.update(&model, main.onCommand(main.cmd_previous_project).?, &fx);
    try testing.expectEqual(first_project, model.active_project_id);
    main.update(&model, main.onCommand(main.cmd_next_project).?, &fx);
    try testing.expectEqual(second_project, model.active_project_id);

    const focus_before = model.composer_focus_flip;
    main.update(&model, main.onCommand(main.cmd_focus_composer).?, &fx);
    try testing.expect(model.composer_focus_flip != focus_before);
    main.update(&model, main.onCommand(main.cmd_model_picker).?, &fx);
    try testing.expect(model.model_picker_open);
    main.update(&model, main.onCommand(main.cmd_settings).?, &fx);
    try testing.expect(model.settings_open);
    main.update(&model, main.onCommand(main.cmd_close_overlay).?, &fx);
    try testing.expect(!model.settings_open and !model.model_picker_open);
}

test "MCP servers persist and discovered tools become keyboard-editable composer commands" {
    const path = "/tmp/superchat-mcp.sqlite3";
    removeTestDatabase(path);
    defer removeTestDatabase(path);

    var model = main.initialModel("test-key");
    defer model.deinit();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    model.mcp_server_name_buffer.set("Weather");
    model.mcp_server_command_buffer.set("weather-mcp --stdio");
    main.update(&model, .add_mcp_server, &fx);
    try testing.expectEqual(@as(usize, 1), model.mcp_server_count);

    const response =
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"forecast","title":"Forecast","description":"Get a forecast","inputSchema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]}}
    ;
    model.mcp_tool_count = try main.workspace_mcp.parseTools(testing.allocator, response, model.mcp_servers[0].id, &model.mcp_tools);
    model.settings_open = true;
    main.update(&model, .{ .select_mcp_tool = 0 }, &fx);
    try testing.expectEqualStrings("/mcp 1 forecast {}", activeThread(&model).draft());
    try testing.expect(!model.settings_open);

    {
        var database = try main.workspace_storage.Database.open(path);
        defer database.close();
        try database.save(&model);
    }
    var restored = main.initialModel("test-key");
    defer restored.deinit();
    {
        var database = try main.workspace_storage.Database.open(path);
        defer database.close();
        try testing.expect(try database.load(&restored));
    }
    try testing.expectEqual(@as(usize, 1), restored.mcp_server_count);
    try testing.expectEqualStrings("Weather", restored.mcp_servers[0].name());
    try testing.expectEqualStrings("weather-mcp --stdio", restored.mcp_servers[0].command());
}

test "MCP composer commands launch the bounded helper with explicit JSON arguments" {
    var model = main.initialModel("test-key");
    defer model.deinit();
    model.setExecutablePath("/tmp/superchat");
    var server = main.workspace_mcp.Server{ .id = 3 };
    server.setName("Weather");
    server.setCommand("weather-mcp --stdio");
    model.mcp_servers[0] = server;
    model.mcp_server_count = 1;
    const response =
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"forecast","inputSchema":{"type":"object"}}]}}
    ;
    model.mcp_tool_count = try main.workspace_mcp.parseTools(testing.allocator, response, 3, &model.mcp_tools);
    activeThread(&model).draft_buffer.set("/mcp 3 forecast {\"city\":\"Melbourne\"}");

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .send, &fx);

    const request = fx.pendingSpawnAt(0) orelse return error.TestExpectedSpawn;
    try testing.expectEqualStrings("/tmp/superchat", request.argv[0]);
    try testing.expectEqualStrings("--mcp-helper", request.argv[1]);
    try testing.expectEqualStrings("call", request.argv[2]);
    try testing.expect(std.mem.indexOf(u8, request.stdin, "\"tool\":\"forecast\"") != null);
    try testing.expect(std.mem.indexOf(u8, request.stdin, "\"city\":\"Melbourne\"") != null);
    try testing.expectEqual(main.McpOperation.call, model.mcp_operation);

    main.update(&model, .{ .mcp_exit = .{
        .key = request.key,
        .code = 0,
        .output = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"18 C and sunny\"}],\"isError\":false}}",
    } }, &fx);
    try testing.expectEqual(main.McpOperation.none, model.mcp_operation);
    try testing.expect(std.mem.indexOf(u8, activeThread(&model).draft(), "[MCP result · Weather.forecast]") != null);
    try testing.expect(std.mem.indexOf(u8, activeThread(&model).draft(), "18 C and sunny") != null);
}

test "number shortcuts select top-level chats projects threads and models" {
    var model = main.initialModel("test-key");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const first_top_level_thread = model.active_thread_id;
    main.update(&model, .new_thread, &fx);
    const second_top_level_thread = model.active_thread_id;
    main.update(&model, main.onCommand(main.thread_slot_commands[0]).?, &fx);
    try testing.expectEqual(first_top_level_thread, model.active_thread_id);
    main.update(&model, main.onCommand(main.thread_slot_commands[1]).?, &fx);
    try testing.expectEqual(second_top_level_thread, model.active_thread_id);

    main.update(&model, .new_project, &fx);
    const first_project = model.active_project_id;
    main.update(&model, .new_project, &fx);
    const second_project = model.active_project_id;
    main.update(&model, main.onCommand(main.project_slot_commands[0]).?, &fx);
    try testing.expectEqual(first_project, model.active_project_id);
    main.update(&model, main.onCommand(main.project_slot_commands[1]).?, &fx);
    try testing.expectEqual(second_project, model.active_project_id);

    main.update(&model, main.onCommand(main.cmd_top_level_chats).?, &fx);
    try testing.expectEqual(main.chats_project_id, model.active_project_id);
    main.update(&model, main.onCommand(main.quick_model_commands[0]).?, &fx);
    try testing.expectEqualStrings(main.Model.quickModels[0].slug, activeThread(&model).modelName());
    main.update(&model, main.onCommand(main.cmd_auto_model).?, &fx);
    try testing.expectEqualStrings("openrouter/auto", activeThread(&model).modelName());
}

test "the command palette finds chats and projects and moves chats between them" {
    var model = main.initialModel("test-key");
    defer model.deinit();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const top_level_thread = model.active_thread_id;
    main.update(&model, .new_project, &fx);
    const project_id = model.active_project_id;
    projectWithId(&model, project_id).name_len = "Research".len;
    @memcpy(projectWithId(&model, project_id).name_storage[0.."Research".len], "Research");
    activeThread(&model).title_len = "Market notes".len;
    @memcpy(activeThread(&model).title_storage[0.."Market notes".len], "Market notes");

    model.model_search_buffer.set("market");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rows = model.paletteWorkspaceRows(arena_state.allocator());
    try testing.expect(rows.len > 0);
    try testing.expectEqualStrings("Market notes", rows[0].title);

    main.update(&model, .{ .select_thread = top_level_thread }, &fx);
    main.update(&model, .open_move_thread, &fx);
    try testing.expect(model.model_picker_open and model.move_open);
    main.update(&model, .{ .move_thread_to = project_id }, &fx);
    try testing.expectEqual(project_id, threadWithId(&model, top_level_thread).project_id);
    try testing.expectEqualStrings("Chat moved", model.toastText());
}

test "prompt snippets can be saved inserted deleted and expanded from slash commands" {
    var model = main.initialModel("test-key");
    defer model.deinit();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try testing.expectEqual(@as(usize, 3), model.snippet_count);
    main.update(&model, .open_snippets, &fx);
    try testing.expect(model.settings_open);
    const first_id = model.snippets[0].id;
    main.update(&model, .{ .use_snippet = first_id }, &fx);
    try testing.expectEqualStrings(model.snippets[0].body(), activeThread(&model).draft());

    activeThread(&model).draft_buffer.set("/summarize");
    main.update(&model, .send, &fx);
    try testing.expectEqualStrings(model.snippets[0].body(), activeThread(&model).messages[0].content());

    main.update(&model, .{ .snippet_name_edit = .{ .insert_text = "explain" } }, &fx);
    main.update(&model, .{ .snippet_body_edit = .{ .insert_text = "Explain this with one concrete example." } }, &fx);
    main.update(&model, .save_snippet, &fx);
    try testing.expectEqual(@as(usize, 4), model.snippet_count);
    const new_id = model.snippets[3].id;
    main.update(&model, .{ .delete_snippet = new_id }, &fx);
    try testing.expectEqual(@as(usize, 3), model.snippet_count);
}

test "OpenRouter usage and timing are attached to the assistant response" {
    var test_clock: native_sdk.TestClock = .{};
    test_clock.setWallMs(10_000);
    var model = main.initialModelWithClock("test-key", test_clock.clock());
    defer model.deinit();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    activeThread(&model).draft_buffer.set("Measure this response");
    main.update(&model, .send, &fx);
    test_clock.advanceMs(1450);
    streamLine(&model, &fx, 1001, "data: {\"model\":\"openai/measured\",\"choices\":[{\"delta\":{\"content\":\"Measured answer\"}}]}");
    streamLine(&model, &fx, 1001, "data: {\"model\":\"openai/measured\",\"choices\":[],\"usage\":{\"prompt_tokens\":21,\"completion_tokens\":8,\"cost\":0.00125}}");
    main.update(&model, .{ .response = .{ .key = 1001, .status = 200 } }, &fx);

    const assistant = activeThread(&model).messages[1];
    try testing.expectEqualStrings("openai/measured", assistant.responseModel());
    try testing.expectEqual(@as(u32, 1450), assistant.latency_ms);
    try testing.expectEqual(@as(u32, 21), assistant.prompt_tokens);
    try testing.expectEqual(@as(u32, 8), assistant.completion_tokens);
    try testing.expectEqual(@as(u64, 1250), assistant.cost_micros);
    try testing.expectEqual(@as(u64, 1250), activeThread(&model).total_cost_micros);
    const connection_label = model.headerConnectionLabel(testing.allocator);
    defer testing.allocator.free(connection_label);
    try testing.expectEqualStrings("Connected · openai/measured", connection_label);
    const cost_label = model.threadCostLabel(testing.allocator);
    defer testing.allocator.free(cost_label);
    try testing.expectEqualStrings("Thread · $0.001250", cost_label);
    try testing.expect(!model.statusVisible());
}

test "modal forms can submit without a mouse" {
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "on-submit=\"save_settings\"") != null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "on-submit=\"save_rename\"") != null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "on-submit=\"finish_onboarding\"") != null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "on-submit=\"create_forks\"") != null);
}

test "modal layouts fit the 560 point minimum window and long content scrolls" {
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "height=\"610\"") == null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "height=\"530\"") == null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "height=\"560\"") == null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "height=\"520\"") != null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "label=\"Archived items\"") != null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "label=\"Command palette\"") != null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "label=\"Settings and keyboard shortcuts\"") != null);
}

test "first-run onboarding is bypassed by credentials completion or dev mode" {
    try testing.expect(main.shouldShowOnboarding(false, false, false, false));
    try testing.expect(!main.shouldShowOnboarding(false, false, true, false));
    try testing.expect(!main.shouldShowOnboarding(false, false, false, true));
    try testing.expect(!main.shouldShowOnboarding(true, false, false, false));
    try testing.expect(main.shouldShowOnboarding(true, true, true, true));
    try testing.expect(!main.usesPersistentCredentialStore(true));
    try testing.expect(!main.usesPersistentCredentialStore(false));

    const dev_model = main.initialModelWithMode("", true);
    try testing.expect(dev_model.dev_mode);
}

test "onboarding offers subscriptions and still verifies OpenRouter keys" {
    var model = main.initialModel("");
    model.onboarding_open = true;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);
    var nodes: [240]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, main.window_min_width, main.window_min_height), &nodes);
    try testing.expect(layout.nodes.len > 0);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "on-press=\"connect_codex\"") != null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "on-press=\"connect_claude\"") != null);
    try testing.expect(std.mem.indexOf(u8, main.app_markup, "roadmap items") == null);

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try testing.expect(fx.pendingFetchAt(0) == null);
    main.update(&model, .finish_onboarding, &fx);
    try testing.expect(model.onboarding_open);

    main.update(&model, .{ .api_key_edit = .{ .insert_text = "sk-or-v1-onboarding" } }, &fx);
    main.update(&model, .finish_onboarding, &fx);
    try testing.expect(model.onboarding_open and model.missingKey());
    const validation = fx.pendingFetchAt(0) orelse return error.TestExpectedFetch;
    main.update(&model, .{ .response = .{ .key = validation.key, .status = 200 } }, &fx);
    try testing.expect(!model.onboarding_open);
    try testing.expect(!model.missingKey());
    try testing.expectEqual(main.CredentialAction.save, model.credential_action);
    for (model.api_key_buffer.storage) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "onboarding can be completed without configuring a provider" {
    var model = main.initialModel("");
    model.onboarding_open = true;
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .skip_onboarding, &fx);
    try testing.expect(!model.onboarding_open);
    try testing.expect(model.missingKey());
    try testing.expectEqual(main.CredentialAction.complete_onboarding, model.credential_action);
}
