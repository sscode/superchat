//! Superchat: a small, native OpenRouter chat client.
//!
//! The interface is declarative `.native` markup. This file owns the
//! model/message/update loop and uses Native SDK's typed HTTP effect so
//! network work never blocks the window thread.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
pub const workspace_storage = @import("storage.zig");
const storage = workspace_storage;
const persistence = @import("persistence.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "chat-canvas";
pub const window_width: f32 = 940;
pub const window_height: f32 = 680;
pub const window_min_width: f32 = 720;
pub const window_min_height: f32 = 480;
pub const header_natural_height: f32 = 56;

const openrouter_url = "https://openrouter.ai/api/v1/chat/completions";
const openrouter_key_url = "https://openrouter.ai/api/v1/key";
const key_validation_request: u64 = 1 << 61;
const models_request: u64 = (1 << 61) + 1;
const model_search_timer: u64 = (1 << 52) + 1;
const openrouter_models_url = "https://openrouter.ai/api/v1/models";
const credential_service = "dev.sscode.superchat";
const credential_account = "openrouter-api-key";
const onboarding_account = "onboarding-complete";
const onboarding_marker = "1";
const request_key_base: u64 = 1000;
const clipboard_key_base: u64 = 1 << 40;
const stream_flush_key_base: u64 = 1 << 44;
const draft_save_key_base: u64 = 1 << 48;
const history_poll_key: u64 = 1 << 52;
const stream_flush_interval_ms: u64 = 16;
const draft_save_interval_ms: u64 = 300;
const archive_retention_ms: i64 = 30 * 24 * 60 * 60 * 1000;
const day_ms: i64 = 24 * 60 * 60 * 1000;
const provider_context_messages = 12;
const history_page_size = 50;
const max_message_bytes = 64 * 1024;
const persistence_batch_ids = 4096;
const max_project_name_bytes = 48;
const max_thread_title_bytes = 64;
const max_draft_bytes = 4000;
const max_model_bytes = 128;
const max_api_key_bytes = 256;
const max_status_bytes = 240;
const max_stream_line_bytes = 32 * 1024;
const max_request_bytes = native_sdk.max_effect_fetch_payload_bytes;

fn utf8PrefixLen(text: []const u8, limit: usize) usize {
    var len = @min(text.len, limit);
    if (len == text.len) return len;
    while (len > 0 and text[len] & 0xc0 == 0x80) len -= 1;
    return len;
}

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
    native_sdk.security.permission_network,
    native_sdk.security.permission_credentials,
    native_sdk.security.permission_clipboard,
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Chat canvas", .accessibility_label = "Superchat", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Superchat",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = true,
    .restore_policy = .center_on_primary,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Role = enum { user, assistant };

pub const ModelChoice = enum {
    auto,
    claude_sonnet,
    claude_opus,
    gpt,
    gemini,
    deepseek,
    custom,
};

pub const CredentialAction = enum { none, save, delete, complete_onboarding };
pub const RenameKind = enum { project, thread };

pub const ModelOption = struct {
    choice: ModelChoice,
    label: []const u8,
    slug: []const u8,
};

pub const CatalogModel = struct {
    slug_storage: [max_model_bytes]u8 = undefined,
    slug_len: usize = 0,
    label_storage: [96]u8 = undefined,
    label_len: usize = 0,
    favorite: bool = false,

    pub fn slug(entry: *const CatalogModel) []const u8 {
        return entry.slug_storage[0..entry.slug_len];
    }
    pub fn label(entry: *const CatalogModel) []const u8 {
        return entry.label_storage[0..entry.label_len];
    }
};

pub const CatalogRow = struct {
    index: u32,
    label: []const u8,
    slug: []const u8,
    favorite: bool,
    favorite_label: []const u8,
};

pub const Message = struct {
    id: u32 = 0,
    role: Role = .user,
    content_storage: []u8 = @constCast(&[_]u8{}),
    content_len: usize = 0,

    pub fn content(message: *const Message) []const u8 {
        return message.content_storage[0..message.content_len];
    }

    pub fn isUser(message: *const Message) bool {
        return message.role == .user;
    }

    pub fn isAssistant(message: *const Message) bool {
        return message.role == .assistant;
    }

    fn deinit(message: *Message, allocator: std.mem.Allocator) void {
        if (message.content_storage.len > 0) allocator.free(message.content_storage);
        message.* = .{};
    }
};

pub const Project = struct {
    id: u32 = 0,
    name_storage: [max_project_name_bytes]u8 = undefined,
    name_len: usize = 0,
    archived_at_ms: i64 = 0,

    pub fn name(project: *const Project) []const u8 {
        return project.name_storage[0..project.name_len];
    }

    pub fn isArchived(project: *const Project) bool {
        return project.archived_at_ms > 0;
    }
};

pub const Thread = struct {
    id: u32 = 0,
    project_id: u32 = 0,
    title_storage: [max_thread_title_bytes]u8 = undefined,
    title_len: usize = 0,
    archived_at_ms: i64 = 0,
    messages: []Message = @constCast(&[_]Message{}),
    message_count: usize = 0,
    draft_buffer: canvas.TextBuffer(max_draft_bytes) = .{},
    model_buffer: canvas.TextBuffer(max_model_bytes) = canvas.TextBuffer(max_model_bytes).init("openrouter/auto"),
    model_choice: ModelChoice = .auto,
    sending: bool = false,
    status_storage: [max_status_bytes]u8 = undefined,
    status_len: usize = 0,
    active_model_storage: [max_model_bytes]u8 = undefined,
    active_model_len: usize = 0,
    stream_message_index: ?usize = null,
    stream_failed: bool = false,
    stream_pending_storage: []u8 = @constCast(&[_]u8{}),
    stream_pending_len: usize = 0,
    stream_flush_scheduled: bool = false,
    has_older_messages: bool = false,
    history_loading: bool = false,

    pub fn title(thread: *const Thread) []const u8 {
        return thread.title_storage[0..thread.title_len];
    }

    pub fn isArchived(thread: *const Thread) bool {
        return thread.archived_at_ms > 0;
    }

    fn setTitle(thread: *Thread, title_text: []const u8) void {
        const trimmed = std.mem.trim(u8, title_text, " \t\r\n");
        const len = utf8PrefixLen(trimmed, max_thread_title_bytes);
        @memcpy(thread.title_storage[0..len], trimmed[0..len]);
        thread.title_len = len;
    }

    pub fn draft(thread: *const Thread) []const u8 {
        return thread.draft_buffer.text();
    }

    pub fn modelName(thread: *const Thread) []const u8 {
        return thread.model_buffer.text();
    }

    fn setStatus(thread: *Thread, text: []const u8) void {
        const len = utf8PrefixLen(text, max_status_bytes);
        @memcpy(thread.status_storage[0..len], text[0..len]);
        thread.status_len = len;
    }

    fn clearStatus(thread: *Thread) void {
        thread.status_len = 0;
    }

    fn setActiveModel(thread: *Thread, text: []const u8) void {
        const len = utf8PrefixLen(text, max_model_bytes);
        @memcpy(thread.active_model_storage[0..len], text[0..len]);
        thread.active_model_len = len;
    }

    pub fn ensureMessageCapacity(thread: *Thread, allocator: std.mem.Allocator, needed: usize) bool {
        if (needed <= thread.messages.len) return true;
        const capacity = @max(needed, @max(@as(usize, 8), thread.messages.len * 2));
        thread.messages = if (thread.messages.len == 0)
            allocator.alloc(Message, capacity) catch return false
        else
            allocator.realloc(thread.messages, capacity) catch return false;
        return true;
    }

    fn appendMessage(thread: *Thread, allocator: std.mem.Allocator, next_message_id: *u32, role: Role, content: []const u8) bool {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len == 0) return false;
        const len = utf8PrefixLen(trimmed, max_message_bytes);
        if (!thread.ensureMessageCapacity(allocator, thread.message_count + 1)) return false;
        const owned = allocator.dupe(u8, trimmed[0..len]) catch return false;
        const message = Message{ .id = next_message_id.*, .role = role, .content_storage = owned, .content_len = len };
        thread.messages[thread.message_count] = message;
        thread.message_count += 1;
        next_message_id.* += 1;
        if (role == .user and thread.message_count == 1) thread.setTitle(trimmed);
        return true;
    }

    fn appendClonedMessage(thread: *Thread, allocator: std.mem.Allocator, next_message_id: *u32, source: *const Message) bool {
        if (!thread.ensureMessageCapacity(allocator, thread.message_count + 1)) return false;
        var cloned = source.*;
        cloned.content_storage = allocator.dupe(u8, source.content()) catch return false;
        cloned.id = next_message_id.*;
        thread.messages[thread.message_count] = cloned;
        thread.message_count += 1;
        next_message_id.* += 1;
        return true;
    }

    fn appendStreamDelta(thread: *Thread, allocator: std.mem.Allocator, next_message_id: *u32, delta: []const u8) bool {
        if (delta.len == 0) return true;
        if (thread.stream_message_index == null) {
            if (!thread.ensureMessageCapacity(allocator, thread.message_count + 1)) return false;
            thread.messages[thread.message_count] = Message{ .id = next_message_id.*, .role = .assistant };
            thread.stream_message_index = thread.message_count;
            thread.message_count += 1;
            next_message_id.* += 1;
        }
        const message = &thread.messages[thread.stream_message_index.?];
        const available = max_message_bytes - message.content_len;
        const copy_len = utf8PrefixLen(delta, available);
        message.content_storage = if (message.content_storage.len == 0)
            allocator.alloc(u8, copy_len) catch return false
        else
            allocator.realloc(message.content_storage, message.content_len + copy_len) catch return false;
        @memcpy(message.content_storage[message.content_len..][0..copy_len], delta[0..copy_len]);
        message.content_len += copy_len;
        return copy_len == delta.len;
    }

    fn queueStreamDelta(thread: *Thread, allocator: std.mem.Allocator, delta: []const u8) bool {
        const existing_len = if (thread.stream_message_index) |index| thread.messages[index].content_len else 0;
        if (existing_len + thread.stream_pending_len + delta.len > max_message_bytes) return false;
        thread.stream_pending_storage = if (thread.stream_pending_storage.len == 0)
            allocator.alloc(u8, delta.len) catch return false
        else
            allocator.realloc(thread.stream_pending_storage, thread.stream_pending_len + delta.len) catch return false;
        @memcpy(thread.stream_pending_storage[thread.stream_pending_len..][0..delta.len], delta);
        thread.stream_pending_len += delta.len;
        return true;
    }

    fn flushStreamDelta(thread: *Thread, allocator: std.mem.Allocator, next_message_id: *u32) bool {
        defer {
            thread.stream_pending_len = 0;
            thread.stream_flush_scheduled = false;
        }
        return thread.appendStreamDelta(allocator, next_message_id, thread.stream_pending_storage[0..thread.stream_pending_len]);
    }

    fn deinit(thread: *Thread, allocator: std.mem.Allocator) void {
        for (thread.messages[0..thread.message_count]) |*message| message.deinit(allocator);
        if (thread.messages.len > 0) allocator.free(thread.messages);
        if (thread.stream_pending_storage.len > 0) allocator.free(thread.stream_pending_storage);
        thread.messages = @constCast(&[_]Message{});
        thread.stream_pending_storage = @constCast(&[_]u8{});
        thread.message_count = 0;
    }
};

pub const ThreadRow = struct {
    id: u32,
    title: []const u8,
    selected: bool,
};

pub const ShortcutHint = struct {
    action: []const u8,
    keys: []const u8,
};

pub const ForkModelRow = struct {
    choice: ModelChoice,
    label: []const u8,
    selected: bool,
};

pub const ArchivedProjectRow = struct {
    id: u32,
    name: []const u8,
    expiry: []const u8,
};

pub const ArchivedThreadRow = struct {
    id: u32,
    title: []const u8,
    project_name: []const u8,
    expiry: []const u8,
};

pub const cmd_new_thread = "workspace.new-thread";
pub const cmd_new_project = "workspace.new-project";
pub const cmd_previous_thread = "workspace.previous-thread";
pub const cmd_next_thread = "workspace.next-thread";
pub const cmd_previous_project = "workspace.previous-project";
pub const cmd_next_project = "workspace.next-project";
pub const cmd_focus_composer = "workspace.focus-composer";
pub const cmd_model_picker = "workspace.model-picker";
pub const cmd_settings = "workspace.settings";
pub const cmd_fork_latest = "workspace.fork-latest";
pub const cmd_copy_latest = "workspace.copy-latest";
pub const cmd_rename_thread = "workspace.rename-thread";
pub const cmd_rename_project = "workspace.rename-project";
pub const cmd_archive_thread = "workspace.archive-thread";
pub const cmd_archive_project = "workspace.archive-project";
pub const cmd_open_archive = "workspace.archive";
pub const cmd_clear_thread = "workspace.clear-thread";
pub const cmd_close_overlay = "workspace.close-overlay";

fn requestKey(thread_id: u32) u64 {
    return request_key_base + thread_id;
}

fn requestThreadId(key: u64) ?u32 {
    if (key <= request_key_base or key - request_key_base > std.math.maxInt(u32)) return null;
    return @intCast(key - request_key_base);
}

fn clipboardKey(message_id: u32) u64 {
    return clipboard_key_base + message_id;
}

fn forkChoiceBit(choice: ModelChoice) u8 {
    return @as(u8, 1) << @intCast(@intFromEnum(choice));
}

fn appendUniqueId(ids: []u32, count: *usize, id: u32) void {
    for (ids[0..count.*]) |existing| if (existing == id) return;
    if (count.* == ids.len) return;
    ids[count.*] = id;
    count.* += 1;
}

fn streamFlushKey(thread_id: u32) u64 {
    return stream_flush_key_base + thread_id;
}

fn streamFlushThreadId(key: u64) ?u32 {
    if (key <= stream_flush_key_base or key - stream_flush_key_base > std.math.maxInt(u32)) return null;
    return @intCast(key - stream_flush_key_base);
}

fn draftSaveKey(thread_id: u32) u64 {
    return draft_save_key_base + thread_id;
}

fn draftSaveThreadId(key: u64) ?u32 {
    if (key <= draft_save_key_base or key - draft_save_key_base > std.math.maxInt(u32)) return null;
    return @intCast(key - draft_save_key_base);
}

const ApiMessage = struct {
    role: []const u8,
    content: []const u8,
};

const ApiRequest = struct {
    model: []const u8,
    messages: []const ApiMessage,
    stream: bool = true,
};

const ApiError = struct {
    message: []const u8 = "OpenRouter rejected the request.",
};

const ApiStreamDelta = struct {
    content: ?[]const u8 = null,
};

const ApiStreamChoice = struct {
    delta: ApiStreamDelta = .{},
};

const ApiStreamChunk = struct {
    choices: []const ApiStreamChoice = &.{},
    model: []const u8 = "",
    @"error": ?ApiError = null,
};

const RemoteModel = struct { id: []const u8, name: []const u8 = "" };
const RemoteModels = struct { data: []const RemoteModel = &.{} };

pub const Msg = union(enum) {
    draft_edit: canvas.TextInputEvent,
    model_edit: canvas.TextInputEvent,
    api_key_edit: canvas.TextInputEvent,
    model_search_edit: canvas.TextInputEvent,
    fork_seed_edit: canvas.TextInputEvent,
    toggle_model_picker,
    close_model_picker,
    select_model: ModelChoice,
    select_auto_model,
    select_custom_model,
    select_catalog_model: u32,
    toggle_model_favorite: u32,
    model_search: native_sdk.EffectTimer,
    open_settings,
    close_settings,
    save_settings,
    remove_api_key,
    finish_onboarding,
    skip_onboarding,
    copy_message: u32,
    copy_latest,
    clipboard_result: native_sdk.EffectClipboardResult,
    open_fork: u32,
    fork_latest,
    close_fork,
    toggle_fork_model: ModelChoice,
    create_forks,
    open_rename_thread,
    open_rename_project,
    rename_edit: canvas.TextInputEvent,
    save_rename,
    close_rename,
    archive_thread,
    archive_project,
    open_archive,
    close_archive,
    restore_thread: u32,
    restore_project: u32,
    delete_thread: u32,
    delete_project: u32,
    confirm_delete,
    cancel_delete,
    new_project,
    new_thread,
    select_project: u32,
    select_thread: u32,
    previous_project,
    next_project,
    previous_thread,
    next_thread,
    focus_composer,
    open_model_picker,
    close_overlay,
    send,
    clear,
    load_older,
    history_poll: native_sdk.EffectTimer,
    stream_line: native_sdk.EffectLine,
    stream_flush: native_sdk.EffectTimer,
    persist_draft: native_sdk.EffectTimer,
    response: native_sdk.EffectResponse,
    chrome_changed: native_sdk.WindowChrome,

    pub const view_unbound = .{
        "response",
        "stream_line",
        "stream_flush",
        "history_poll",
        "model_search",
        "persist_draft",
        "clipboard_result",
        "chrome_changed",
        "previous_project",
        "next_project",
        "previous_thread",
        "next_thread",
        "focus_composer",
        "open_model_picker",
        "copy_latest",
        "fork_latest",
        "open_rename_thread",
        "open_rename_project",
        "archive_thread",
        "archive_project",
        "open_archive",
        "close_overlay",
        "select_model",
    };
};

pub const Model = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    projects: []Project = @constCast(&[_]Project{}),
    project_count: usize = 0,
    threads: []Thread = @constCast(&[_]Thread{}),
    thread_count: usize = 0,
    next_project_id: u32 = 1,
    next_thread_id: u32 = 1,
    active_project_id: u32 = 0,
    active_thread_id: u32 = 0,
    next_message_id: u32 = 1,
    api_key_buffer: canvas.TextBuffer(max_api_key_bytes) = .{},
    api_key_storage: [max_api_key_bytes]u8 = undefined,
    api_key_len: usize = 0,
    request_storage: [max_request_bytes]u8 = undefined,
    model_search_buffer: canvas.TextBuffer(80) = .{},
    model_catalog: [32]CatalogModel = undefined,
    model_catalog_count: usize = 0,
    model_catalog_loading: bool = false,
    model_catalog_status_storage: [120]u8 = undefined,
    model_catalog_status_len: usize = 0,
    model_catalog_url_storage: [512]u8 = undefined,
    model_catalog_dirty_mask: u32 = 0,
    model_picker_open: bool = false,
    settings_open: bool = false,
    onboarding_open: bool = false,
    dev_mode: bool = false,
    force_onboarding: bool = false,
    key_validation_pending: bool = false,
    key_validation_onboarding: bool = false,
    fork_open: bool = false,
    fork_source_thread_id: u32 = 0,
    fork_source_message_id: u32 = 0,
    fork_model_mask: u8 = 0,
    fork_seed_buffer: canvas.TextBuffer(max_draft_bytes) = .{},
    rename_open: bool = false,
    rename_kind: RenameKind = .thread,
    rename_id: u32 = 0,
    rename_buffer: canvas.TextBuffer(max_thread_title_bytes) = .{},
    archive_open: bool = false,
    delete_confirm_open: bool = false,
    delete_kind: RenameKind = .thread,
    delete_id: u32 = 0,
    clock: native_sdk.Clock = .system,
    composer_focus_flip: bool = false,
    credential_action: CredentialAction = .none,
    chrome_leading: f32 = 0,
    chrome_trailing: f32 = 0,
    header_height: f32 = header_natural_height,
    persistence_workspace_dirty: bool = false,
    persistence_structure_dirty: bool = false,
    persistence_meta_dirty: bool = false,
    persistence_thread_ids: [persistence_batch_ids]u32 = undefined,
    persistence_thread_count: usize = 0,
    persistence_message_thread_ids: [persistence_batch_ids]u32 = undefined,
    persistence_message_thread_count: usize = 0,
    persistence_clear_thread_ids: [persistence_batch_ids]u32 = undefined,
    persistence_clear_thread_count: usize = 0,
    history_request_thread_id: u32 = 0,
    stream_parse_storage: [max_stream_line_bytes * 2]u8 = undefined,

    // These are implementation state read by the derived bindings below
    // or by update/effects; they are intentionally not exposed directly
    // to the markup contract.
    pub const view_unbound = .{
        "projects",
        "allocator",
        "project_count",
        "threads",
        "thread_count",
        "next_project_id",
        "next_thread_id",
        "next_message_id",
        "api_key_buffer",
        "api_key_storage",
        "api_key_len",
        "request_storage",
        "model_search_buffer",
        "model_catalog",
        "model_catalog_count",
        "model_catalog_status_storage",
        "model_catalog_status_len",
        "model_catalog_url_storage",
        "model_catalog_dirty_mask",
        "model_catalog_loading",
        "dev_mode",
        "composer_focus_flip",
        "hasMessages",
        "canSend",
        "forkCount",
        "credential_action",
        "force_onboarding",
        "key_validation_pending",
        "key_validation_onboarding",
        "fork_source_thread_id",
        "fork_source_message_id",
        "fork_model_mask",
        "fork_seed_buffer",
        "rename_kind",
        "rename_id",
        "rename_buffer",
        "clock",
        "persistence_workspace_dirty",
        "persistence_structure_dirty",
        "persistence_meta_dirty",
        "persistence_thread_ids",
        "persistence_thread_count",
        "persistence_message_thread_ids",
        "persistence_message_thread_count",
        "persistence_clear_thread_ids",
        "persistence_clear_thread_count",
        "history_request_thread_id",
        "stream_parse_storage",
        "delete_kind",
        "delete_id",
        "activeThread",
        "activeThreadConst",
        "threadById",
        "active_thread_id",
        "modelOptions",
        "activeModelChoice",
    };

    pub const modelOptions = [_]ModelOption{
        .{ .choice = .auto, .label = "Auto · best fit", .slug = "openrouter/auto" },
        .{ .choice = .claude_sonnet, .label = "Claude Sonnet 5", .slug = "anthropic/claude-sonnet-5" },
        .{ .choice = .claude_opus, .label = "Claude Opus 4.8", .slug = "anthropic/claude-opus-4.8" },
        .{ .choice = .gpt, .label = "GPT-5.5", .slug = "openai/gpt-5.5" },
        .{ .choice = .gemini, .label = "Gemini 3.5 Flash", .slug = "google/gemini-3.5-flash" },
        .{ .choice = .deepseek, .label = "DeepSeek V4 Pro", .slug = "deepseek/deepseek-v4-pro" },
        .{ .choice = .custom, .label = "Custom model…", .slug = "" },
    };

    pub const shortcutHints = [_]ShortcutHint{
        .{ .action = "New chat", .keys = "Cmd + N" },
        .{ .action = "New project", .keys = "Cmd + Shift + N" },
        .{ .action = "Previous chat", .keys = "Cmd + [" },
        .{ .action = "Next chat", .keys = "Cmd + ]" },
        .{ .action = "Previous project", .keys = "Cmd + Option + Up" },
        .{ .action = "Next project", .keys = "Cmd + Option + Down" },
        .{ .action = "Focus message", .keys = "Cmd + L" },
        .{ .action = "Choose model", .keys = "Cmd + K" },
        .{ .action = "Open settings", .keys = "Cmd + ," },
        .{ .action = "Fork latest response", .keys = "Cmd + Shift + F" },
        .{ .action = "Copy latest response", .keys = "Cmd + Shift + C" },
        .{ .action = "Rename chat", .keys = "Cmd + Shift + R" },
        .{ .action = "Rename project", .keys = "Cmd + Option + R" },
        .{ .action = "Archive chat", .keys = "Cmd + Shift + E" },
        .{ .action = "Archive project", .keys = "Cmd + Option + E" },
        .{ .action = "Open archive", .keys = "Cmd + Shift + H" },
        .{ .action = "Clear current chat", .keys = "Cmd + Shift + Backspace" },
        .{ .action = "Send message", .keys = "Cmd + Enter" },
        .{ .action = "Close overlay", .keys = "Escape" },
    };

    pub fn draft(model: *const Model) []const u8 {
        const thread = model.activeThreadConst() orelse return "";
        return thread.draft();
    }

    fn markWorkspaceDirty(model: *Model) void {
        model.persistence_workspace_dirty = true;
        model.persistence_structure_dirty = true;
        model.persistence_meta_dirty = true;
    }

    fn markStructureDirty(model: *Model) void {
        model.persistence_structure_dirty = true;
        model.persistence_meta_dirty = true;
    }

    fn markMetaDirty(model: *Model) void {
        model.persistence_meta_dirty = true;
    }

    fn markThreadDirty(model: *Model, thread_id: u32) void {
        appendUniqueId(&model.persistence_thread_ids, &model.persistence_thread_count, thread_id);
    }

    fn markMessagesDirty(model: *Model, thread_id: u32) void {
        model.markThreadDirty(thread_id);
        appendUniqueId(&model.persistence_message_thread_ids, &model.persistence_message_thread_count, thread_id);
        model.persistence_meta_dirty = true;
    }

    fn markMessagesCleared(model: *Model, thread_id: u32) void {
        model.markThreadDirty(thread_id);
        appendUniqueId(&model.persistence_clear_thread_ids, &model.persistence_clear_thread_count, thread_id);
        model.persistence_meta_dirty = true;
    }

    pub fn brandLabel(model: *const Model) []const u8 {
        return if (model.dev_mode) "Superchat · Dev" else "Superchat";
    }

    pub fn composerKey(model: *const Model) []const u8 {
        return if (model.composer_focus_flip) "composer-a" else "composer-b";
    }

    pub fn projectRows(model: *const Model, arena: std.mem.Allocator) []const Project {
        const out = arena.alloc(Project, model.project_count) catch return &.{};
        var count: usize = 0;
        for (model.projects[0..model.project_count]) |project| {
            if (project.isArchived()) continue;
            out[count] = project;
            count += 1;
        }
        return out[0..count];
    }

    pub fn threadRows(model: *const Model, arena: std.mem.Allocator) []const ThreadRow {
        const out = arena.alloc(ThreadRow, model.thread_count) catch return &.{};
        var count: usize = 0;
        for (model.threads[0..model.thread_count]) |*thread| {
            if (thread.project_id != model.active_project_id or thread.isArchived()) continue;
            out[count] = .{
                .id = thread.id,
                .title = if (thread.sending)
                    std.fmt.allocPrint(arena, "{s} · responding", .{thread.title()}) catch thread.title()
                else
                    thread.title(),
                .selected = thread.id == model.active_thread_id,
            };
            count += 1;
        }
        return out[0..count];
    }

    pub fn activeProjectName(model: *const Model) []const u8 {
        for (model.projects[0..model.project_count]) |*project| {
            if (project.id == model.active_project_id) return project.name();
        }
        return "Project";
    }

    pub fn activeThreadTitle(model: *const Model) []const u8 {
        for (model.threads[0..model.thread_count]) |*thread| {
            if (thread.id == model.active_thread_id) return thread.title();
        }
        return "New chat";
    }

    pub fn cannotAddProject(model: *const Model) bool {
        _ = model;
        return false;
    }

    pub fn cannotAddThread(model: *const Model) bool {
        _ = model;
        return false;
    }

    pub fn workspaceStatus(model: *const Model, arena: std.mem.Allocator) []const u8 {
        var projects: usize = 0;
        var threads: usize = 0;
        for (model.projects[0..model.project_count]) |project| projects += @intFromBool(!project.isArchived());
        for (model.threads[0..model.thread_count]) |thread| {
            if (thread.isArchived()) continue;
            const project = model.projectByIdConst(thread.project_id) orelse continue;
            threads += @intFromBool(!project.isArchived());
        }
        return std.fmt.allocPrint(arena, "{d} projects · {d} chats", .{ projects, threads }) catch "Workspace";
    }

    pub fn renameValue(model: *const Model) []const u8 {
        return model.rename_buffer.text();
    }

    pub fn renameHeading(model: *const Model) []const u8 {
        return if (model.rename_kind == .project) "Rename project" else "Rename chat";
    }

    pub fn cannotSaveRename(model: *const Model) bool {
        return std.mem.trim(u8, model.rename_buffer.text(), " \t\r\n").len == 0;
    }

    fn expiryLabel(model: *const Model, arena: std.mem.Allocator, archived_at_ms: i64) []const u8 {
        const remaining = @max(archive_retention_ms - @max(model.clock.wallMs() - archived_at_ms, 0), 0);
        const days = @divTrunc(remaining + day_ms - 1, day_ms);
        return if (days == 0)
            "Deletes today"
        else
            std.fmt.allocPrint(arena, "Deletes in {d} {s}", .{ days, if (days == 1) "day" else "days" }) catch "Deletes within 30 days";
    }

    pub fn archivedProjectRows(model: *const Model, arena: std.mem.Allocator) []const ArchivedProjectRow {
        const out = arena.alloc(ArchivedProjectRow, model.project_count) catch return &.{};
        var count: usize = 0;
        for (model.projects[0..model.project_count]) |*project| {
            if (!project.isArchived()) continue;
            out[count] = .{ .id = project.id, .name = project.name(), .expiry = model.expiryLabel(arena, project.archived_at_ms) };
            count += 1;
        }
        return out[0..count];
    }

    pub fn archivedThreadRows(model: *const Model, arena: std.mem.Allocator) []const ArchivedThreadRow {
        const out = arena.alloc(ArchivedThreadRow, model.thread_count) catch return &.{};
        var count: usize = 0;
        for (model.threads[0..model.thread_count]) |*thread| {
            if (!thread.isArchived()) continue;
            const project = model.projectByIdConst(thread.project_id) orelse continue;
            if (project.isArchived()) continue;
            out[count] = .{
                .id = thread.id,
                .title = thread.title(),
                .project_name = project.name(),
                .expiry = model.expiryLabel(arena, thread.archived_at_ms),
            };
            count += 1;
        }
        return out[0..count];
    }

    pub fn archiveEmpty(model: *const Model) bool {
        for (model.projects[0..model.project_count]) |project| if (project.isArchived()) return false;
        for (model.threads[0..model.thread_count]) |thread| if (thread.isArchived()) return false;
        return true;
    }

    pub fn deleteTargetLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!model.delete_confirm_open) return "";
        if (model.delete_kind == .project) {
            const project = model.projectByIdConst(model.delete_id) orelse return "this project";
            return std.fmt.allocPrint(arena, "Permanently delete project “{s}” and all its chats?", .{project.name()}) catch "Permanently delete this project?";
        }
        const thread = model.threadByIdConst(model.delete_id) orelse return "this chat";
        return std.fmt.allocPrint(arena, "Permanently delete chat “{s}”?", .{thread.title()}) catch "Permanently delete this chat?";
    }

    pub fn modelName(model: *const Model) []const u8 {
        const thread = model.activeThreadConst() orelse return "";
        return thread.modelName();
    }

    pub fn selectedModelLabel(model: *const Model) []const u8 {
        const thread = model.activeThreadConst() orelse return "No model";
        if (thread.model_choice == .custom) return thread.modelName();
        for (modelOptions) |option| {
            if (option.choice == thread.model_choice) return option.label;
        }
        return "Custom model";
    }

    pub fn modelSearch(model: *const Model) []const u8 {
        return model.model_search_buffer.text();
    }

    pub fn catalogRows(model: *const Model, arena: std.mem.Allocator) []const CatalogRow {
        const rows = arena.alloc(CatalogRow, model.model_catalog_count) catch return &.{};
        for (model.model_catalog[0..model.model_catalog_count], 0..) |*entry, index| {
            rows[index] = .{ .index = @intCast(index), .label = entry.label(), .slug = entry.slug(), .favorite = entry.favorite, .favorite_label = if (entry.favorite) "Unfavorite" else "Favorite" };
        }
        return rows;
    }

    pub fn modelCatalogLoading(model: *const Model) bool {
        return model.model_catalog_loading;
    }

    pub fn modelCatalogStatus(model: *const Model) []const u8 {
        return model.model_catalog_status_storage[0..model.model_catalog_status_len];
    }

    fn setModelCatalogStatus(model: *Model, value: []const u8) void {
        const len = utf8PrefixLen(value, model.model_catalog_status_storage.len);
        @memcpy(model.model_catalog_status_storage[0..len], value[0..len]);
        model.model_catalog_status_len = len;
    }

    fn selectCatalogModel(model: *Model, index: u32) void {
        if (index >= model.model_catalog_count) return;
        const entry = &model.model_catalog[index];
        const thread = model.activeThread() orelse return;
        thread.model_choice = .custom;
        thread.model_buffer.set(entry.slug());
        model.model_picker_open = false;
        model.markThreadDirty(thread.id);
    }

    pub fn activeModelChoice(model: *const Model) ModelChoice {
        const thread = model.activeThreadConst() orelse return .auto;
        return thread.model_choice;
    }

    pub fn forkSeed(model: *const Model) []const u8 {
        return model.fork_seed_buffer.text();
    }

    pub fn forkSourcePreview(model: *const Model) []const u8 {
        const thread = model.threadByIdConst(model.fork_source_thread_id) orelse return "Response unavailable";
        for (thread.messages[0..thread.message_count]) |*message| {
            if (message.id != model.fork_source_message_id) continue;
            return message.content()[0..utf8PrefixLen(message.content(), 320)];
        }
        return "Response unavailable";
    }

    pub fn forkModelRows(model: *const Model, arena: std.mem.Allocator) []const ForkModelRow {
        const source = model.threadByIdConst(model.fork_source_thread_id);
        const include_custom = source != null and source.?.model_choice == .custom;
        const capacity = modelOptions.len - @intFromBool(!include_custom);
        const rows = arena.alloc(ForkModelRow, capacity) catch return &.{};
        var count: usize = 0;
        for (modelOptions) |option| {
            if (option.choice == .custom and !include_custom) continue;
            rows[count] = .{
                .choice = option.choice,
                .label = if (option.choice == .custom) source.?.modelName() else option.label,
                .selected = model.fork_model_mask & forkChoiceBit(option.choice) != 0,
            };
            count += 1;
        }
        return rows[0..count];
    }

    pub fn forkCount(model: *const Model) usize {
        return @popCount(model.fork_model_mask);
    }

    pub fn forkCountLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const count = model.forkCount();
        return std.fmt.allocPrint(arena, "Create {d} {s}", .{ count, if (count == 1) "chat" else "chats" }) catch "Create forks";
    }

    pub fn cannotCreateForks(model: *const Model) bool {
        const count = model.forkCount();
        return count == 0 or model.fork_source_message_id == 0;
    }

    pub fn apiKeyField(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const out = arena.alloc(u8, model.api_key_buffer.text().len) catch return "";
        @memset(out, '*');
        return out;
    }

    pub fn apiKeyPlaceholder(model: *const Model) []const u8 {
        return if (model.api_key_len > 0) "Key is set · paste to replace" else "sk-or-v1-…";
    }

    pub fn cannotFinishOnboarding(model: *const Model) bool {
        return model.key_validation_pending or (model.api_key_len == 0 and model.api_key_buffer.isEmpty());
    }

    pub fn cannotSaveSettings(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return true;
        return thread.model_buffer.isEmpty() or model.key_validation_pending;
    }

    pub fn messageRows(model: *const Model) []const Message {
        const thread = model.activeThreadConst() orelse return &.{};
        return thread.messages[0..thread.message_count];
    }

    pub fn canLoadOlder(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return false;
        return thread.has_older_messages and !thread.history_loading and thread.message_count > 0;
    }

    pub fn historyLoading(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return false;
        return thread.history_loading;
    }

    pub fn hasMessages(model: *const Model) bool {
        return model.messageRows().len > 0;
    }

    pub fn cannotClear(model: *const Model) bool {
        return !model.hasMessages();
    }

    pub fn canSend(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return false;
        return !thread.sending and model.api_key_len > 0 and !thread.draft_buffer.isEmpty() and !thread.model_buffer.isEmpty();
    }

    pub fn cannotSend(model: *const Model) bool {
        return !model.canSend();
    }

    pub fn missingKey(model: *const Model) bool {
        return model.api_key_len == 0;
    }

    pub fn sending(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return false;
        return thread.sending;
    }

    pub fn statusLine(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const thread = model.activeThreadConst();
        if (thread) |active| {
            if (active.status_len > 0) return active.status_storage[0..active.status_len];
        }
        if (model.api_key_len == 0) return "Add an OpenRouter API key in Settings";
        if (thread) |active| {
            if (active.active_model_len > 0) {
                return std.fmt.allocPrint(arena, "Connected · {s}", .{active.active_model_storage[0..active.active_model_len]}) catch "Connected";
            }
        }
        return "Connected · ready";
    }

    fn setApiKey(model: *Model, key: []const u8) void {
        @memset(&model.api_key_storage, 0);
        const len = @min(key.len, max_api_key_bytes);
        @memcpy(model.api_key_storage[0..len], key[0..len]);
        model.api_key_len = len;
    }

    fn clearApiKeyInput(model: *Model) void {
        @memset(&model.api_key_buffer.storage, 0);
        model.api_key_buffer.clear();
    }

    fn apiKey(model: *const Model) []const u8 {
        return model.api_key_storage[0..model.api_key_len];
    }

    fn selectModel(model: *Model, choice: ModelChoice) void {
        const thread = model.activeThread() orelse return;
        thread.model_choice = choice;
        model.model_picker_open = false;
        for (modelOptions) |option| {
            if (option.choice != choice) continue;
            if (choice == .custom) {
                model.settings_open = true;
            } else {
                thread.model_buffer.set(option.slug);
            }
            return;
        }
    }

    fn setStatus(model: *Model, text: []const u8) void {
        const thread = model.activeThread() orelse return;
        thread.setStatus(text);
    }

    fn setProjectName(project: *Project, name: []const u8) void {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        const len = utf8PrefixLen(trimmed, max_project_name_bytes);
        @memcpy(project.name_storage[0..len], trimmed[0..len]);
        project.name_len = len;
    }

    fn projectById(model: *Model, project_id: u32) ?*Project {
        for (model.projects[0..model.project_count]) |*project| {
            if (project.id == project_id) return project;
        }
        return null;
    }

    fn projectByIdConst(model: *const Model, project_id: u32) ?*const Project {
        for (model.projects[0..model.project_count]) |*project| {
            if (project.id == project_id) return project;
        }
        return null;
    }

    pub fn ensureProjectCapacity(model: *Model, needed: usize) bool {
        if (needed <= model.projects.len) return true;
        const capacity = @max(needed, @max(@as(usize, 8), model.projects.len * 2));
        model.projects = if (model.projects.len == 0)
            model.allocator.alloc(Project, capacity) catch return false
        else
            model.allocator.realloc(model.projects, capacity) catch return false;
        return true;
    }

    pub fn ensureThreadCapacity(model: *Model, needed: usize) bool {
        if (needed <= model.threads.len) return true;
        const capacity = @max(needed, @max(@as(usize, 16), model.threads.len * 2));
        model.threads = if (model.threads.len == 0)
            model.allocator.alloc(Thread, capacity) catch return false
        else
            model.allocator.realloc(model.threads, capacity) catch return false;
        return true;
    }

    fn addProject(model: *Model) ?u32 {
        if (!model.ensureProjectCapacity(model.project_count + 1)) return null;
        const id = model.next_project_id;
        model.next_project_id += 1;
        var project = Project{ .id = id };
        var buffer: [max_project_name_bytes]u8 = undefined;
        const name = if (id == 1) "My project" else std.fmt.bufPrint(&buffer, "Project {d}", .{id}) catch "New project";
        setProjectName(&project, name);
        model.projects[model.project_count] = project;
        model.project_count += 1;
        return id;
    }

    fn addThread(model: *Model, project_id: u32) ?u32 {
        if (!model.ensureThreadCapacity(model.thread_count + 1)) return null;
        const id = model.next_thread_id;
        model.next_thread_id += 1;
        var thread = Thread{ .id = id, .project_id = project_id };
        thread.setTitle("New chat");
        model.threads[model.thread_count] = thread;
        model.thread_count += 1;
        return id;
    }

    fn activeThread(model: *Model) ?*Thread {
        return model.threadById(model.active_thread_id);
    }

    fn activeThreadConst(model: *const Model) ?*const Thread {
        for (model.threads[0..model.thread_count]) |*thread| {
            if (thread.id == model.active_thread_id) return thread;
        }
        return null;
    }

    fn threadById(model: *Model, thread_id: u32) ?*Thread {
        for (model.threads[0..model.thread_count]) |*thread| {
            if (thread.id == thread_id) return thread;
        }
        return null;
    }

    fn threadByIdConst(model: *const Model, thread_id: u32) ?*const Thread {
        for (model.threads[0..model.thread_count]) |*thread| {
            if (thread.id == thread_id) return thread;
        }
        return null;
    }

    fn openRename(model: *Model, kind: RenameKind) void {
        model.rename_buffer.clear();
        model.rename_kind = kind;
        if (kind == .project) {
            const project = model.projectByIdConst(model.active_project_id) orelse return;
            model.rename_id = project.id;
            model.rename_buffer.set(project.name());
        } else {
            const thread = model.activeThreadConst() orelse return;
            model.rename_id = thread.id;
            model.rename_buffer.set(thread.title());
        }
        model.settings_open = false;
        model.fork_open = false;
        model.archive_open = false;
        model.rename_open = true;
    }

    fn saveRename(model: *Model) void {
        const value = std.mem.trim(u8, model.rename_buffer.text(), " \t\r\n");
        if (value.len == 0) return;
        if (model.rename_kind == .project) {
            const project = model.projectById(model.rename_id) orelse return;
            setProjectName(project, value);
        } else {
            const thread = model.threadById(model.rename_id) orelse return;
            thread.setTitle(value);
        }
        model.rename_open = false;
        model.rename_id = 0;
        model.rename_buffer.clear();
    }

    fn removeThreadAt(model: *Model, index: usize, fx: *Effects) void {
        const thread = &model.threads[index];
        if (thread.sending) fx.cancel(requestKey(thread.id));
        thread.deinit(model.allocator);
        if (index + 1 < model.thread_count) {
            std.mem.copyForwards(Thread, model.threads[index .. model.thread_count - 1], model.threads[index + 1 .. model.thread_count]);
        }
        model.thread_count -= 1;
    }

    fn deleteThread(model: *Model, thread_id: u32, fx: *Effects) void {
        for (model.threads[0..model.thread_count], 0..) |thread, index| {
            if (thread.id != thread_id or !thread.isArchived()) continue;
            model.removeThreadAt(index, fx);
            return;
        }
    }

    fn deleteProject(model: *Model, project_id: u32, fx: *Effects) void {
        const project = model.projectByIdConst(project_id) orelse return;
        if (!project.isArchived()) return;
        var thread_index: usize = 0;
        while (thread_index < model.thread_count) {
            if (model.threads[thread_index].project_id == project_id) {
                model.removeThreadAt(thread_index, fx);
            } else {
                thread_index += 1;
            }
        }
        for (model.projects[0..model.project_count], 0..) |candidate, index| {
            if (candidate.id != project_id) continue;
            if (index + 1 < model.project_count) {
                std.mem.copyForwards(Project, model.projects[index .. model.project_count - 1], model.projects[index + 1 .. model.project_count]);
            }
            model.project_count -= 1;
            return;
        }
    }

    fn activateFirstVisible(model: *Model) bool {
        for (model.projects[0..model.project_count]) |project| {
            if (project.isArchived()) continue;
            for (model.threads[0..model.thread_count]) |thread| {
                if (thread.project_id == project.id and !thread.isArchived()) return model.activateThread(thread.id);
            }
        }
        return false;
    }

    fn normalizeLoadedWorkspace(model: *Model) bool {
        var max_project_id: u32 = 0;
        var max_thread_id: u32 = 0;
        var max_message_id: u32 = 0;
        for (model.projects[0..model.project_count]) |project| max_project_id = @max(max_project_id, project.id);
        for (model.threads[0..model.thread_count]) |thread| {
            max_thread_id = @max(max_thread_id, thread.id);
            for (thread.messages[0..thread.message_count]) |message| max_message_id = @max(max_message_id, message.id);
        }
        model.next_project_id = @max(model.next_project_id, max_project_id +| 1);
        model.next_thread_id = @max(model.next_thread_id, max_thread_id +| 1);
        model.next_message_id = @max(model.next_message_id, max_message_id +| 1);

        if (model.activeThreadConst()) |thread| {
            const project = model.projectByIdConst(thread.project_id);
            if (!thread.isArchived() and project != null and !project.?.isArchived()) return true;
        }
        if (model.activateFirstVisible()) return true;
        const project_id = model.addProject() orelse return false;
        const thread_id = model.addThread(project_id) orelse return false;
        return model.activateThread(thread_id);
    }

    fn archiveThread(model: *Model, fx: *Effects) void {
        const active_id = model.active_thread_id;
        const project_id = model.active_project_id;
        var replacement_id: u32 = 0;
        for (model.threads[0..model.thread_count]) |thread| {
            if (thread.project_id == project_id and thread.id != active_id and !thread.isArchived()) {
                replacement_id = thread.id;
                break;
            }
        }
        if (replacement_id == 0) replacement_id = model.addThread(project_id) orelse {
            model.setStatus("Delete an archived chat before archiving this one");
            return;
        };
        const thread = model.threadById(active_id) orelse return;
        if (thread.sending) fx.cancel(requestKey(thread.id));
        thread.sending = false;
        thread.archived_at_ms = @max(model.clock.wallMs(), 1);
        _ = model.activateThread(replacement_id);
    }

    fn archiveProject(model: *Model, fx: *Effects) void {
        const active_id = model.active_project_id;
        var replacement_thread_id: u32 = 0;
        for (model.projects[0..model.project_count]) |project| {
            if (project.id == active_id or project.isArchived()) continue;
            for (model.threads[0..model.thread_count]) |thread| {
                if (thread.project_id == project.id and !thread.isArchived()) {
                    replacement_thread_id = thread.id;
                    break;
                }
            }
            if (replacement_thread_id != 0) break;
        }
        if (replacement_thread_id == 0) {
            const new_project_id = model.addProject() orelse {
                model.setStatus("Delete an archived project before archiving this one");
                return;
            };
            replacement_thread_id = model.addThread(new_project_id) orelse return;
        }
        for (model.threads[0..model.thread_count]) |*thread| {
            if (thread.project_id != active_id or !thread.sending) continue;
            fx.cancel(requestKey(thread.id));
            thread.sending = false;
        }
        const project = model.projectById(active_id) orelse return;
        project.archived_at_ms = @max(model.clock.wallMs(), 1);
        _ = model.activateThread(replacement_thread_id);
    }

    fn restoreThread(model: *Model, thread_id: u32) void {
        const thread = model.threadById(thread_id) orelse return;
        const project = model.projectByIdConst(thread.project_id) orelse return;
        if (!thread.isArchived() or project.isArchived()) return;
        thread.archived_at_ms = 0;
        _ = model.activateThread(thread_id);
        model.archive_open = false;
        model.delete_confirm_open = false;
    }

    fn restoreProject(model: *Model, project_id: u32) void {
        const project = model.projectById(project_id) orelse return;
        if (!project.isArchived()) return;
        project.archived_at_ms = 0;
        for (model.threads[0..model.thread_count]) |thread| {
            if (thread.project_id == project_id and !thread.isArchived()) {
                _ = model.activateThread(thread.id);
                model.archive_open = false;
                model.delete_confirm_open = false;
                return;
            }
        }
        const thread_id = model.addThread(project_id) orelse return;
        _ = model.activateThread(thread_id);
        model.archive_open = false;
        model.delete_confirm_open = false;
    }

    fn purgeExpired(model: *Model, fx: *Effects) void {
        const now = model.clock.wallMs();
        var project_index: usize = 0;
        while (project_index < model.project_count) {
            const project = model.projects[project_index];
            if (project.isArchived() and now - project.archived_at_ms >= archive_retention_ms) {
                model.deleteProject(project.id, fx);
            } else {
                project_index += 1;
            }
        }
        var thread_index: usize = 0;
        while (thread_index < model.thread_count) {
            const thread = model.threads[thread_index];
            if (thread.isArchived() and now - thread.archived_at_ms >= archive_retention_ms) {
                model.removeThreadAt(thread_index, fx);
            } else {
                thread_index += 1;
            }
        }
    }

    fn latestAssistantMessageId(model: *const Model) ?u32 {
        const thread = model.activeThreadConst() orelse return null;
        var index = thread.message_count;
        while (index > 0) {
            index -= 1;
            if (thread.messages[index].role == .assistant) return thread.messages[index].id;
        }
        return null;
    }

    fn openFork(model: *Model, message_id: u32) void {
        const thread = model.activeThread() orelse return;
        var source_index: ?usize = null;
        for (thread.messages[0..thread.message_count], 0..) |message, index| {
            if (message.id == message_id and message.role == .assistant) source_index = index;
        }
        const index = source_index orelse return;
        if (thread.sending and thread.stream_message_index == index) return;
        model.fork_source_thread_id = thread.id;
        model.fork_source_message_id = message_id;
        model.fork_model_mask = forkChoiceBit(if (thread.model_choice == .custom) .custom else thread.model_choice);
        model.fork_seed_buffer.clear();
        model.model_picker_open = false;
        model.settings_open = false;
        model.rename_open = false;
        model.archive_open = false;
        model.fork_open = true;
    }

    fn configureThreadModel(thread: *Thread, choice: ModelChoice, custom_slug: []const u8) void {
        thread.model_choice = choice;
        if (choice == .custom) {
            thread.model_buffer.set(custom_slug);
            return;
        }
        for (modelOptions) |option| {
            if (option.choice == choice) {
                thread.model_buffer.set(option.slug);
                return;
            }
        }
    }

    fn activateThread(model: *Model, thread_id: u32) bool {
        const thread = model.threadById(thread_id) orelse return false;
        const project = model.projectByIdConst(thread.project_id) orelse return false;
        if (thread.isArchived() or project.isArchived()) return false;
        model.active_project_id = thread.project_id;
        model.active_thread_id = thread.id;
        return true;
    }

    fn cycleProject(model: *Model, forward: bool) void {
        const ids = model.allocator.alloc(u32, model.project_count) catch return;
        defer model.allocator.free(ids);
        var count: usize = 0;
        var current: usize = 0;
        for (model.projects[0..model.project_count]) |project| {
            if (project.isArchived()) continue;
            ids[count] = project.id;
            if (project.id == model.active_project_id) current = count;
            count += 1;
        }
        if (count < 2) return;
        const target = if (forward)
            (current + 1) % count
        else if (current == 0)
            count - 1
        else
            current - 1;
        const project_id = ids[target];
        for (model.threads[0..model.thread_count]) |thread| {
            if (thread.project_id == project_id and !thread.isArchived()) {
                _ = model.activateThread(thread.id);
                return;
            }
        }
    }

    fn cycleThread(model: *Model, forward: bool) void {
        const ids = model.allocator.alloc(u32, model.thread_count) catch return;
        defer model.allocator.free(ids);
        var count: usize = 0;
        var current: usize = 0;
        for (model.threads[0..model.thread_count]) |thread| {
            if (thread.project_id != model.active_project_id or thread.isArchived()) continue;
            ids[count] = thread.id;
            if (thread.id == model.active_thread_id) current = count;
            count += 1;
        }
        if (count < 2) return;
        const target = if (forward)
            (current + 1) % count
        else if (current == 0)
            count - 1
        else
            current - 1;
        _ = model.activateThread(ids[target]);
    }

    pub fn appendMessage(model: *Model, role: Role, content: []const u8) bool {
        const thread = model.activeThread() orelse return false;
        return thread.appendMessage(model.allocator, &model.next_message_id, role, content);
    }

    fn buildRequest(model: *Model, thread: *const Thread) ?[]const u8 {
        var api_messages: [provider_context_messages]ApiMessage = undefined;
        const first = thread.message_count -| provider_context_messages;
        for (thread.messages[first..thread.message_count], 0..) |*message, index| {
            api_messages[index] = .{
                .role = if (message.role == .user) "user" else "assistant",
                .content = message.content(),
            };
        }
        var writer: std.Io.Writer = .fixed(&model.request_storage);
        std.json.Stringify.value(ApiRequest{
            .model = std.mem.trim(u8, thread.modelName(), " \t"),
            .messages = api_messages[0..@min(thread.message_count, provider_context_messages)],
        }, .{}, &writer) catch return null;
        return writer.buffered();
    }

    pub fn deinit(model: *Model) void {
        for (model.threads[0..model.thread_count]) |*thread| thread.deinit(model.allocator);
        if (model.threads.len > 0) model.allocator.free(model.threads);
        if (model.projects.len > 0) model.allocator.free(model.projects);
        model.threads = @constCast(&[_]Thread{});
        model.projects = @constCast(&[_]Project{});
        model.thread_count = 0;
        model.project_count = 0;
    }
};

pub const ChatApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = builtin.mode == .Debug });
pub const Effects = ChatApp.Effects;

pub fn initialModel(api_key: []const u8) Model {
    return initialModelWithOptionsAndClock(api_key, false, false, .system);
}

pub fn initialModelWithMode(api_key: []const u8, dev_mode: bool) Model {
    return initialModelWithOptionsAndClock(api_key, dev_mode, false, .system);
}

pub fn initialModelWithOptions(api_key: []const u8, dev_mode: bool, force_onboarding: bool) Model {
    return initialModelWithOptionsAndClock(api_key, dev_mode, force_onboarding, .system);
}

pub fn initialModelWithClock(api_key: []const u8, clock: native_sdk.Clock) Model {
    return initialModelWithOptionsAndClock(api_key, false, false, clock);
}

fn initialModelWithOptionsAndClock(api_key: []const u8, dev_mode: bool, force_onboarding: bool, clock: native_sdk.Clock) Model {
    var model = Model{ .dev_mode = dev_mode, .force_onboarding = force_onboarding, .clock = clock };
    model.setApiKey(api_key);
    const project_id = model.addProject().?;
    model.active_project_id = project_id;
    model.active_thread_id = model.addThread(project_id).?;
    return model;
}

pub fn shouldShowOnboarding(dev_mode: bool, force_onboarding: bool, has_api_key: bool, onboarding_complete: bool) bool {
    if (force_onboarding) return true;
    return !dev_mode and !has_api_key and !onboarding_complete;
}

pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, cmd_new_thread)) return .new_thread;
    if (std.mem.eql(u8, name, cmd_new_project)) return .new_project;
    if (std.mem.eql(u8, name, cmd_previous_thread)) return .previous_thread;
    if (std.mem.eql(u8, name, cmd_next_thread)) return .next_thread;
    if (std.mem.eql(u8, name, cmd_previous_project)) return .previous_project;
    if (std.mem.eql(u8, name, cmd_next_project)) return .next_project;
    if (std.mem.eql(u8, name, cmd_focus_composer)) return .focus_composer;
    if (std.mem.eql(u8, name, cmd_model_picker)) return .open_model_picker;
    if (std.mem.eql(u8, name, cmd_settings)) return .open_settings;
    if (std.mem.eql(u8, name, cmd_fork_latest)) return .fork_latest;
    if (std.mem.eql(u8, name, cmd_copy_latest)) return .copy_latest;
    if (std.mem.eql(u8, name, cmd_rename_thread)) return .open_rename_thread;
    if (std.mem.eql(u8, name, cmd_rename_project)) return .open_rename_project;
    if (std.mem.eql(u8, name, cmd_archive_thread)) return .archive_thread;
    if (std.mem.eql(u8, name, cmd_archive_project)) return .archive_project;
    if (std.mem.eql(u8, name, cmd_open_archive)) return .open_archive;
    if (std.mem.eql(u8, name, cmd_clear_thread)) return .clear;
    if (std.mem.eql(u8, name, cmd_close_overlay)) return .close_overlay;
    return null;
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .draft_edit => |edit| {
            const thread = model.activeThread() orelse return;
            thread.draft_buffer.apply(edit);
            fx.startTimer(.{
                .key = draftSaveKey(thread.id),
                .interval_ms = draft_save_interval_ms,
                .on_fire = Effects.timerMsg(.persist_draft),
            });
        },
        .fork_seed_edit => |edit| model.fork_seed_buffer.apply(edit),
        .rename_edit => |edit| model.rename_buffer.apply(edit),
        .model_edit => |edit| {
            const thread = model.activeThread() orelse return;
            thread.model_buffer.apply(edit);
            thread.model_choice = .custom;
            model.markThreadDirty(thread.id);
        },
        .api_key_edit => |edit| model.api_key_buffer.apply(edit),
        .model_search_edit => |edit| {
            model.model_search_buffer.apply(edit);
            fx.startTimer(.{ .key = model_search_timer, .interval_ms = 250, .on_fire = Effects.timerMsg(.model_search) });
        },
        .model_search => searchModels(model, fx),
        .toggle_model_picker => {
            model.model_picker_open = !model.model_picker_open;
            if (model.model_picker_open and model.model_catalog_count == 0) model.setModelCatalogStatus("Search OpenRouter by model or provider");
        },
        .close_model_picker => model.model_picker_open = false,
        .select_model => |choice| {
            model.selectModel(choice);
            if (model.activeThreadConst()) |thread| model.markThreadDirty(thread.id);
        },
        .select_auto_model => model.selectModel(.auto),
        .select_custom_model => model.selectModel(.custom),
        .select_catalog_model => |index| model.selectCatalogModel(index),
        .toggle_model_favorite => |index| {
            if (index < model.model_catalog_count) {
                model.model_catalog[index].favorite = !model.model_catalog[index].favorite;
                model.model_catalog_dirty_mask |= @as(u32, 1) << @intCast(index);
            }
        },
        .open_settings => {
            model.model_picker_open = false;
            model.fork_open = false;
            model.rename_open = false;
            model.archive_open = false;
            model.clearApiKeyInput();
            model.settings_open = true;
        },
        .close_settings => {
            model.clearApiKeyInput();
            model.settings_open = false;
        },
        .save_settings => {
            const thread = model.activeThread() orelse return;
            if (thread.model_buffer.isEmpty()) return;
            if (!model.api_key_buffer.isEmpty()) {
                validateApiKey(model, false, fx);
                return;
            }
            model.clearApiKeyInput();
            model.settings_open = false;
        },
        .remove_api_key => {
            model.setApiKey("");
            model.clearApiKeyInput();
            model.credential_action = .delete;
            model.setStatus("API key removed");
        },
        .finish_onboarding => {
            if (model.cannotFinishOnboarding()) return;
            if (!model.api_key_buffer.isEmpty()) {
                validateApiKey(model, true, fx);
                return;
            } else {
                model.credential_action = .complete_onboarding;
            }
            model.clearApiKeyInput();
            model.onboarding_open = false;
            model.setStatus("OpenRouter connected");
        },
        .skip_onboarding => {
            model.clearApiKeyInput();
            model.onboarding_open = false;
            model.credential_action = .complete_onboarding;
            model.setStatus("Set up a model connection in Settings when you're ready");
        },
        .copy_message => |message_id| copyMessage(model, message_id, fx),
        .copy_latest => {
            const message_id = model.latestAssistantMessageId() orelse return;
            copyMessage(model, message_id, fx);
        },
        .clipboard_result => |result| {
            if (result.outcome != .ok) model.setStatus("Could not copy the response");
        },
        .open_fork => |message_id| model.openFork(message_id),
        .fork_latest => {
            const message_id = model.latestAssistantMessageId() orelse return;
            model.openFork(message_id);
        },
        .close_fork => {
            model.fork_open = false;
            model.fork_seed_buffer.clear();
        },
        .toggle_fork_model => |choice| model.fork_model_mask ^= forkChoiceBit(choice),
        .create_forks => {
            const first_new_thread = model.thread_count;
            createForks(model, fx);
            for (model.threads[first_new_thread..model.thread_count]) |thread| model.markMessagesDirty(thread.id);
        },
        .open_rename_thread => model.openRename(.thread),
        .open_rename_project => model.openRename(.project),
        .save_rename => {
            model.saveRename();
            model.markStructureDirty();
        },
        .close_rename => {
            model.rename_open = false;
            model.rename_id = 0;
            model.rename_buffer.clear();
        },
        .archive_thread => {
            model.archiveThread(fx);
            model.markStructureDirty();
        },
        .archive_project => {
            model.archiveProject(fx);
            model.markStructureDirty();
        },
        .open_archive => {
            model.purgeExpired(fx);
            model.markStructureDirty();
            model.model_picker_open = false;
            model.settings_open = false;
            model.fork_open = false;
            model.rename_open = false;
            model.delete_confirm_open = false;
            model.archive_open = true;
        },
        .close_archive => {
            model.archive_open = false;
            model.delete_confirm_open = false;
        },
        .restore_thread => |thread_id| {
            model.restoreThread(thread_id);
            model.markStructureDirty();
        },
        .restore_project => |project_id| {
            model.restoreProject(project_id);
            model.markStructureDirty();
        },
        .delete_thread => |thread_id| {
            const thread = model.threadByIdConst(thread_id) orelse return;
            if (!thread.isArchived()) return;
            model.delete_kind = .thread;
            model.delete_id = thread_id;
            model.delete_confirm_open = true;
        },
        .delete_project => |project_id| {
            const project = model.projectByIdConst(project_id) orelse return;
            if (!project.isArchived()) return;
            model.delete_kind = .project;
            model.delete_id = project_id;
            model.delete_confirm_open = true;
        },
        .confirm_delete => {
            if (!model.delete_confirm_open) return;
            if (model.delete_kind == .project)
                model.deleteProject(model.delete_id, fx)
            else
                model.deleteThread(model.delete_id, fx);
            model.delete_confirm_open = false;
            model.delete_id = 0;
            model.markStructureDirty();
        },
        .cancel_delete => {
            model.delete_confirm_open = false;
            model.delete_id = 0;
        },
        .new_project => {
            const project_id = model.addProject() orelse return;
            const thread_id = model.addThread(project_id) orelse return;
            _ = model.activateThread(thread_id);
            model.markStructureDirty();
        },
        .new_thread => {
            const thread_id = model.addThread(model.active_project_id) orelse return;
            _ = model.activateThread(thread_id);
            model.markStructureDirty();
        },
        .select_project => |project_id| {
            if (project_id == model.active_project_id) return;
            for (model.threads[0..model.thread_count]) |thread| {
                if (thread.project_id == project_id and !thread.isArchived()) {
                    _ = model.activateThread(thread.id);
                    model.markMetaDirty();
                    return;
                }
            }
        },
        .select_thread => |thread_id| {
            if (thread_id == model.active_thread_id) return;
            _ = model.activateThread(thread_id);
            model.markMetaDirty();
        },
        .previous_project => {
            model.cycleProject(false);
            model.markMetaDirty();
        },
        .next_project => {
            model.cycleProject(true);
            model.markMetaDirty();
        },
        .previous_thread => {
            model.cycleThread(false);
            model.markMetaDirty();
        },
        .next_thread => {
            model.cycleThread(true);
            model.markMetaDirty();
        },
        .focus_composer => model.composer_focus_flip = !model.composer_focus_flip,
        .open_model_picker => {
            model.settings_open = false;
            model.fork_open = false;
            model.rename_open = false;
            model.archive_open = false;
            model.delete_confirm_open = false;
            model.model_picker_open = true;
            if (model.model_catalog_count == 0) model.setModelCatalogStatus("Search OpenRouter by model or provider");
        },
        .close_overlay => {
            model.settings_open = false;
            model.fork_open = false;
            model.rename_open = false;
            model.archive_open = false;
            model.model_picker_open = false;
            model.clearApiKeyInput();
            model.fork_seed_buffer.clear();
            model.rename_buffer.clear();
        },
        .load_older => {
            const thread = model.activeThread() orelse return;
            if (!thread.has_older_messages or thread.history_loading or thread.message_count == 0) return;
            thread.history_loading = true;
            model.history_request_thread_id = thread.id;
            fx.startTimer(.{
                .key = history_poll_key,
                .interval_ms = 50,
                .on_fire = Effects.timerMsg(.history_poll),
            });
        },
        .history_poll => {
            const thread = model.activeThread() orelse return;
            if (!thread.history_loading) return;
            fx.startTimer(.{
                .key = history_poll_key,
                .interval_ms = 50,
                .on_fire = Effects.timerMsg(.history_poll),
            });
        },
        .clear => {
            const thread = model.activeThread() orelse return;
            if (thread.sending) {
                fx.cancel(requestKey(thread.id));
                thread.setStatus("Cancelling…");
            } else {
                thread.clearStatus();
            }
            for (thread.messages[0..thread.message_count]) |*message| message.deinit(model.allocator);
            thread.message_count = 0;
            thread.active_model_len = 0;
            thread.stream_message_index = null;
            thread.stream_failed = false;
            thread.stream_pending_len = 0;
            thread.stream_flush_scheduled = false;
            fx.cancelTimer(streamFlushKey(thread.id));
            model.markMessagesCleared(thread.id);
        },
        .send => {
            const thread_id = model.active_thread_id;
            const before = model.next_message_id;
            send(model, fx);
            if (model.next_message_id != before) model.markMessagesDirty(thread_id);
        },
        .stream_line => |line| receiveStreamLine(model, line, fx),
        .stream_flush => |timer| {
            const thread_id = streamFlushThreadId(timer.key) orelse return;
            const thread = model.threadById(thread_id) orelse return;
            if (!thread.flushStreamDelta(model.allocator, &model.next_message_id)) {
                thread.stream_failed = true;
                thread.setStatus("Response exceeded the 64 KiB safety limit");
                fx.cancel(requestKey(thread.id));
            }
        },
        .persist_draft => |timer| {
            const thread_id = draftSaveThreadId(timer.key) orelse return;
            if (model.threadByIdConst(thread_id) != null) model.markThreadDirty(thread_id);
        },
        .response => |response| {
            if (response.key == key_validation_request) {
                receiveKeyValidation(model, response);
                return;
            }
            if (response.key == models_request) {
                receiveModels(model, response);
                return;
            }
            const thread_id = requestThreadId(response.key) orelse return;
            receive(model, response, fx);
            model.markMessagesDirty(thread_id);
        },
        .chrome_changed => |chrome| {
            model.chrome_leading = chrome.insets.left;
            model.chrome_trailing = chrome.insets.right;
            model.header_height = @max(header_natural_height, chrome.insets.top);
        },
    }
}

fn copyMessage(model: *Model, message_id: u32, fx: *Effects) void {
    const thread = model.activeThread() orelse return;
    for (thread.messages[0..thread.message_count]) |*message| {
        if (message.id != message_id or message.role != .assistant) continue;
        fx.writeClipboard(.{
            .key = clipboardKey(message.id),
            .text = message.content(),
            .on_result = Effects.clipboardMsg(.clipboard_result),
        });
        thread.setStatus("Response copied");
        return;
    }
}

fn createForks(model: *Model, fx: *Effects) void {
    if (model.cannotCreateForks()) return;
    if (!model.ensureThreadCapacity(model.thread_count + model.forkCount())) return;
    const source = model.threadById(model.fork_source_thread_id) orelse return;
    var source_message_count: ?usize = null;
    for (source.messages[0..source.message_count], 0..) |message, index| {
        if (message.id == model.fork_source_message_id and message.role == .assistant) source_message_count = index + 1;
    }
    const history_count = source_message_count orelse return;
    const project_id = source.project_id;
    const custom_slug = source.modelName();
    const seed = model.fork_seed_buffer.text();
    var first_thread_id: u32 = 0;

    for (Model.modelOptions) |option| {
        if (model.fork_model_mask & forkChoiceBit(option.choice) == 0) continue;
        const thread_id = model.addThread(project_id) orelse break;
        const target = model.threadById(thread_id) orelse continue;
        for (source.messages[0..history_count]) |*message| {
            if (!target.appendClonedMessage(model.allocator, &model.next_message_id, message)) return;
        }
        Model.configureThreadModel(target, option.choice, custom_slug);
        var title_buffer: [max_thread_title_bytes]u8 = undefined;
        const model_label = if (option.choice == .custom) custom_slug else option.label;
        const title = std.fmt.bufPrint(&title_buffer, "{s} · {s}", .{ source.title(), model_label }) catch "Forked chat";
        target.setTitle(title);
        if (seed.len > 0) target.draft_buffer.set(seed);
        if (first_thread_id == 0) first_thread_id = thread_id;
        if (seed.len > 0) sendThread(model, target, fx);
    }

    if (first_thread_id == 0) return;
    _ = model.activateThread(first_thread_id);
    model.fork_open = false;
    model.fork_source_thread_id = 0;
    model.fork_source_message_id = 0;
    model.fork_model_mask = 0;
    model.fork_seed_buffer.clear();
}

fn validateApiKey(model: *Model, onboarding: bool, fx: *Effects) void {
    const candidate = std.mem.trim(u8, model.api_key_buffer.text(), " \t\r\n");
    if (candidate.len == 0 or candidate.len > max_api_key_bytes) {
        model.setStatus("Enter a valid OpenRouter API key");
        return;
    }
    var auth_storage: [max_api_key_bytes + 7]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_storage, "Bearer {s}", .{candidate}) catch {
        model.setStatus("The OpenRouter API key is too long");
        return;
    };
    const headers = [_]std.http.Header{.{ .name = "Authorization", .value = auth }};
    fx.fetch(.{
        .key = key_validation_request,
        .method = .GET,
        .url = openrouter_key_url,
        .headers = &headers,
        .timeout_ms = 15_000,
        .on_response = Effects.responseMsg(.response),
    });
    model.key_validation_pending = true;
    model.key_validation_onboarding = onboarding;
    model.setStatus("Checking OpenRouter key…");
}

fn receiveKeyValidation(model: *Model, response: native_sdk.EffectResponse) void {
    model.key_validation_pending = false;
    if (response.outcome != .ok) {
        model.setStatus("Could not verify the key; check your connection and try again");
        return;
    }
    if (response.status == 401 or response.status == 403) {
        model.setStatus("OpenRouter rejected this API key");
        return;
    }
    if (response.status < 200 or response.status >= 300) {
        model.setStatus("OpenRouter could not verify this key right now");
        return;
    }
    model.setApiKey(std.mem.trim(u8, model.api_key_buffer.text(), " \t\r\n"));
    model.credential_action = .save;
    model.clearApiKeyInput();
    model.settings_open = false;
    if (model.key_validation_onboarding) model.onboarding_open = false;
    model.key_validation_onboarding = false;
    model.setStatus("OpenRouter connected · key verified");
}

fn searchModels(model: *Model, fx: *Effects) void {
    const query = std.mem.trim(u8, model.model_search_buffer.text(), " \t\r\n");
    if (query.len < 2) {
        model.setModelCatalogStatus("Type at least 2 characters to search OpenRouter");
        return;
    }
    var writer: std.Io.Writer = .fixed(&model.model_catalog_url_storage);
    writer.writeAll(openrouter_models_url ++ "?sort=most-popular&q=") catch return;
    for (query) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '/') {
            writer.writeByte(byte) catch return;
        } else if (byte == ' ') {
            writer.writeAll("%20") catch return;
        }
    }
    fx.fetch(.{
        .key = models_request,
        .method = .GET,
        .url = writer.buffered(),
        .timeout_ms = 15_000,
        .on_response = Effects.responseMsg(.response),
    });
    model.model_catalog_loading = true;
    model.setModelCatalogStatus("Searching OpenRouter…");
}

fn receiveModels(model: *Model, response: native_sdk.EffectResponse) void {
    model.model_catalog_loading = false;
    if (response.outcome != .ok) {
        model.setModelCatalogStatus("Could not reach OpenRouter's model catalog");
        return;
    }
    if (response.status < 200 or response.status >= 300 or response.truncated) {
        model.setModelCatalogStatus("Model search failed; try a more specific search");
        return;
    }
    var parsed = std.json.parseFromSlice(RemoteModels, model.allocator, response.body, .{ .ignore_unknown_fields = true }) catch {
        model.setModelCatalogStatus("OpenRouter returned an unreadable model list");
        return;
    };
    defer parsed.deinit();
    var next: [32]CatalogModel = undefined;
    var count: usize = 0;
    for (parsed.value.data) |remote| {
        if (count == next.len or remote.id.len == 0) break;
        var favorite = false;
        for (model.model_catalog[0..model.model_catalog_count]) |*cached| {
            if (std.mem.eql(u8, cached.slug(), remote.id)) favorite = cached.favorite;
        }
        var entry = CatalogModel{ .favorite = favorite };
        entry.slug_len = utf8PrefixLen(remote.id, entry.slug_storage.len);
        @memcpy(entry.slug_storage[0..entry.slug_len], remote.id[0..entry.slug_len]);
        const label = if (remote.name.len > 0) remote.name else remote.id;
        entry.label_len = utf8PrefixLen(label, entry.label_storage.len);
        @memcpy(entry.label_storage[0..entry.label_len], label[0..entry.label_len]);
        next[count] = entry;
        count += 1;
    }
    @memcpy(model.model_catalog[0..count], next[0..count]);
    model.model_catalog_count = count;
    model.model_catalog_dirty_mask = if (count == 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(count)) -| 1;
    model.setModelCatalogStatus(if (count == 0) "No models matched" else "Results from OpenRouter");
}

fn send(model: *Model, fx: *Effects) void {
    const thread = model.activeThread() orelse return;
    sendThread(model, thread, fx);
}

fn sendThread(model: *Model, thread: *Thread, fx: *Effects) void {
    if (thread.sending or model.api_key_len == 0 or thread.draft_buffer.isEmpty() or thread.model_buffer.isEmpty()) return;
    if (!thread.appendMessage(model.allocator, &model.next_message_id, .user, thread.draft())) return;
    thread.draft_buffer.clear();

    const body = model.buildRequest(thread) orelse {
        // The user message remains visible so it can be copied/retried.
        thread.setStatus("Conversation is too large for Native SDK's 64 KiB fetch payload");
        return;
    };

    var auth_storage: [max_api_key_bytes + 7]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_storage, "Bearer {s}", .{model.apiKey()}) catch {
        thread.setStatus("The OpenRouter API key is too long");
        return;
    };
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "X-OpenRouter-Title", .value = "Superchat" },
    };
    fx.fetch(.{
        .key = requestKey(thread.id),
        .method = .POST,
        .url = openrouter_url,
        .headers = &headers,
        .body = body,
        .timeout_ms = 300_000,
        .response = .stream,
        .max_line_bytes = max_stream_line_bytes,
        .on_line = Effects.lineMsg(.stream_line),
        .on_response = Effects.responseMsg(.response),
    });
    thread.sending = true;
    thread.stream_message_index = null;
    thread.stream_failed = false;
    thread.setStatus("Thinking…");
}

fn receiveStreamLine(model: *Model, line: native_sdk.EffectLine, fx: *Effects) void {
    const target_thread_id = requestThreadId(line.key) orelse return;
    const thread = model.threadById(target_thread_id) orelse return;
    if (!thread.sending) return;

    if (line.truncated or line.dropped_before > 0) {
        thread.stream_failed = true;
        thread.setStatus("Streaming response was incomplete; request cancelled");
        fx.cancel(line.key);
        return;
    }

    const event_line = std.mem.trim(u8, line.line, " \t\r");
    if (event_line.len == 0 or event_line[0] == ':') return;
    const payload = if (std.mem.startsWith(u8, event_line, "data:"))
        std.mem.trim(u8, event_line[5..], " \t")
    else
        event_line;
    if (std.mem.eql(u8, payload, "[DONE]")) return;

    var scratch = std.heap.FixedBufferAllocator.init(&model.stream_parse_storage);
    var parsed = std.json.parseFromSlice(ApiStreamChunk, scratch.allocator(), payload, .{ .ignore_unknown_fields = true }) catch {
        thread.stream_failed = true;
        thread.setStatus("OpenRouter returned an unreadable stream event");
        fx.cancel(line.key);
        return;
    };
    defer parsed.deinit();

    if (parsed.value.@"error") |api_error| {
        thread.stream_failed = true;
        thread.setStatus(api_error.message);
        fx.cancel(line.key);
        return;
    }
    if (parsed.value.model.len > 0) thread.setActiveModel(parsed.value.model);
    if (parsed.value.choices.len == 0) return;
    const content = parsed.value.choices[0].delta.content orelse return;
    if (!thread.queueStreamDelta(model.allocator, content)) {
        thread.stream_failed = true;
        thread.setStatus("Response exceeded the 64 KiB safety limit");
        fx.cancel(line.key);
        return;
    }
    if (!thread.stream_flush_scheduled) {
        thread.stream_flush_scheduled = true;
        fx.startTimer(.{
            .key = streamFlushKey(thread.id),
            .interval_ms = stream_flush_interval_ms,
            .on_fire = Effects.timerMsg(.stream_flush),
        });
    }
    thread.clearStatus();
}

fn receive(model: *Model, response: native_sdk.EffectResponse, fx: *Effects) void {
    const target_thread_id = requestThreadId(response.key) orelse return;
    const thread = model.threadById(target_thread_id) orelse return;
    if (thread.stream_flush_scheduled) fx.cancelTimer(streamFlushKey(thread.id));
    if (thread.stream_pending_len > 0 and !thread.flushStreamDelta(model.allocator, &model.next_message_id)) {
        thread.stream_failed = true;
        thread.setStatus("Response exceeded the 64 KiB safety limit");
    }
    receiveThread(thread, response);
}

fn receiveThread(thread: *Thread, response: native_sdk.EffectResponse) void {
    thread.sending = false;
    const received_content = thread.stream_message_index != null;
    thread.stream_message_index = null;
    if (response.dropped_before > 0) {
        thread.stream_failed = true;
        thread.setStatus("Streaming response was incomplete");
    }
    if (response.outcome != .ok) {
        if (thread.stream_failed) return;
        thread.setStatus(switch (response.outcome) {
            .rejected => "The request was rejected before it started",
            .connect_failed => "Could not connect to OpenRouter",
            .tls_failed => "OpenRouter's secure connection failed",
            .protocol_failed => "The connection ended unexpectedly",
            .timed_out => "OpenRouter took too long to respond",
            .cancelled => "Request cancelled",
            .ok => unreachable,
        });
        return;
    }
    if (response.status < 200 or response.status >= 300) {
        if (thread.stream_failed) return;
        const friendly = switch (response.status) {
            400 => "OpenRouter rejected this request; the model name or request may be invalid",
            401, 403 => "OpenRouter rejected the API key; reconnect it in Settings",
            402 => "OpenRouter credits are required for this model",
            404 => "This model is unavailable; choose another model",
            408 => "OpenRouter timed out while preparing the response",
            413 => "This conversation exceeds the model's context limit",
            429 => "OpenRouter is rate limiting requests; wait a moment and retry",
            else => "",
        };
        if (friendly.len > 0) {
            thread.setStatus(friendly);
            return;
        }
        var status_buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&status_buffer, "OpenRouter returned HTTP {d}", .{response.status}) catch "OpenRouter request failed";
        thread.setStatus(text);
        return;
    }
    if (thread.stream_failed) return;
    if (!received_content) {
        thread.setStatus("OpenRouter returned no text");
        return;
    }
    thread.clearStatus();
}

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");
pub const CompiledAppView = blk: {
    @setEvalBranchQuota(200_000);
    const View = canvas.CompiledMarkupView(Model, Msg, app_markup);
    _ = View.document;
    break :blk View;
};

// UiApp deliberately keeps update pure of platform services. This thin
// wrapper handles the OS-bound credential concerns around it: the
// OpenRouter key and the non-secret first-run completion marker.
const SecureChatApp = struct {
    inner: native_sdk.App,
    chat: *ChatApp,
    persistence_worker: *persistence.Worker,
    credential_loaded: bool = false,
    persistence_error_shown: bool = false,

    fn app(self: *SecureChatApp) native_sdk.App {
        return .{
            .context = self,
            .name = "superchat",
            .scene_fn = scene,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn scene(context: *anyopaque) anyerror!native_sdk.ShellConfig {
        const self: *SecureChatApp = @ptrCast(@alignCast(context));
        return (try self.inner.scene()).?;
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, value: native_sdk.Event) anyerror!void {
        const self: *SecureChatApp = @ptrCast(@alignCast(context));
        if (!self.credential_loaded) {
            self.credential_loaded = true;
            // An explicit launch-time environment key wins for developer
            // workflows; otherwise restore from the OS credential store.
            if (self.chat.model.api_key_len == 0) {
                var buffer: [max_api_key_bytes]u8 = undefined;
                if (runtime.getCredential(.{ .service = credential_service, .account = credential_account }, &buffer) catch null) |secret| {
                    self.chat.model.setApiKey(secret);
                }
            }
            var onboarding_buffer: [8]u8 = undefined;
            const onboarding_complete = (runtime.getCredential(.{ .service = credential_service, .account = onboarding_account }, &onboarding_buffer) catch null) != null;
            self.chat.model.onboarding_open = shouldShowOnboarding(self.chat.model.dev_mode, self.chat.model.force_onboarding, self.chat.model.api_key_len > 0, onboarding_complete);
        }

        try self.inner.event(runtime, value);
        if (self.chat.model.history_request_thread_id != 0) {
            const thread_id = self.chat.model.history_request_thread_id;
            self.chat.model.history_request_thread_id = 0;
            if (self.chat.model.threadByIdConst(thread_id)) |thread| {
                if (thread.message_count > 0) {
                    _ = self.persistence_worker.enqueue(.{ .load_history = .{
                        .thread_id = thread_id,
                        .before_id = thread.messages[0].id,
                        .limit = history_page_size,
                    } });
                }
            }
        }
        if (self.persistence_worker.takeHistoryResult()) |result_value| {
            var result = result_value;
            const model = &self.chat.model;
            if (model.threadById(result.thread_id)) |thread| {
                const count = result.page.messages.len;
                if (thread.ensureMessageCapacity(model.allocator, thread.message_count + count)) {
                    std.mem.copyBackwards(Message, thread.messages[count .. count + thread.message_count], thread.messages[0..thread.message_count]);
                    for (result.page.messages, 0..) |history, index| {
                        thread.messages[index] = .{
                            .id = history.id,
                            .role = if (history.role == @intFromEnum(Role.assistant)) .assistant else .user,
                            .content_storage = history.content,
                            .content_len = history.content.len,
                        };
                        result.page.messages[index].content = @constCast(&[_]u8{});
                    }
                    thread.message_count += count;
                    thread.has_older_messages = result.page.has_more;
                }
                thread.history_loading = false;
            }
            result.page.deinit(model.allocator);
            if (self.chat.installed) try self.chat.rebuild(runtime, self.chat.canvas_window_id);
        }
        if (self.chat.model.model_catalog_dirty_mask != 0) {
            const now = self.chat.model.clock.wallMs();
            for (self.chat.model.model_catalog[0..self.chat.model.model_catalog_count], 0..) |*entry, index| {
                const bit = @as(u32, 1) << @intCast(index);
                if (self.chat.model.model_catalog_dirty_mask & bit == 0) continue;
                if (!self.persistence_worker.enqueue(.{ .upsert_cached_model = persistence.CachedModelRecord.from(entry, now) })) break;
                self.chat.model.model_catalog_dirty_mask &= ~bit;
            }
        }
        const action = self.chat.model.credential_action;
        self.chat.model.credential_action = .none;
        switch (action) {
            .none => {},
            .save => {
                var key_saved = true;
                runtime.setCredential(.{
                    .service = credential_service,
                    .account = credential_account,
                    .secret = self.chat.model.apiKey(),
                }) catch {
                    key_saved = false;
                    self.chat.model.setStatus("Key is active for this session; secure storage is unavailable");
                    if (self.chat.installed) try self.chat.rebuild(runtime, self.chat.canvas_window_id);
                };
                if (key_saved) {
                    runtime.setCredential(.{
                        .service = credential_service,
                        .account = onboarding_account,
                        .secret = onboarding_marker,
                    }) catch {
                        self.chat.model.setStatus("Connected, but first-run completion could not be saved");
                        if (self.chat.installed) try self.chat.rebuild(runtime, self.chat.canvas_window_id);
                    };
                }
            },
            .delete => _ = runtime.deleteCredential(.{ .service = credential_service, .account = credential_account }) catch false,
            .complete_onboarding => runtime.setCredential(.{
                .service = credential_service,
                .account = onboarding_account,
                .secret = onboarding_marker,
            }) catch {
                self.chat.model.setStatus("First-run completion could not be saved");
                if (self.chat.installed) try self.chat.rebuild(runtime, self.chat.canvas_window_id);
            },
        }

        self.flushPersistence();
        if (self.persistence_worker.hasFailed() and !self.persistence_error_shown) {
            self.persistence_error_shown = true;
            self.chat.model.setStatus("Workspace changes could not be saved locally");
            if (self.chat.installed) try self.chat.rebuild(runtime, self.chat.canvas_window_id);
        }
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *SecureChatApp = @ptrCast(@alignCast(context));
        for (self.chat.model.threads[0..self.chat.model.thread_count]) |*thread| {
            if (thread.stream_pending_len > 0) {
                _ = thread.flushStreamDelta(self.chat.model.allocator, &self.chat.model.next_message_id);
                self.chat.model.markMessagesDirty(thread.id);
            } else {
                self.chat.model.markThreadDirty(thread.id);
            }
        }
        self.chat.model.markMetaDirty();
        self.flushPersistence();
        self.persistence_worker.stopAndDestroy();
        try self.inner.stop(runtime);
    }

    fn flushPersistence(self: *SecureChatApp) void {
        const model = &self.chat.model;
        var required: usize = 0;
        if (model.persistence_structure_dirty) {
            required = model.project_count + model.thread_count + 2;
            if (model.persistence_workspace_dirty) {
                for (model.threads[0..model.thread_count]) |thread| required += thread.message_count;
            }
        } else {
            required = model.persistence_clear_thread_count + model.persistence_thread_count + @intFromBool(model.persistence_meta_dirty);
            for (model.persistence_message_thread_ids[0..model.persistence_message_thread_count]) |thread_id| {
                const thread = model.threadByIdConst(thread_id) orelse continue;
                required += thread.message_count;
            }
        }
        if (required == 0 or !self.persistence_worker.canEnqueue(required)) return;

        if (model.persistence_structure_dirty) {
            for (model.projects[0..model.project_count], 0..) |project, position| {
                _ = self.persistence_worker.enqueue(.{ .upsert_project = persistence.ProjectRecord.from(&project, position) });
            }
            for (model.threads[0..model.thread_count], 0..) |thread, position| {
                _ = self.persistence_worker.enqueue(.{ .upsert_thread = persistence.ThreadRecord.from(&thread, position) });
                if (model.persistence_workspace_dirty) {
                    for (thread.messages[0..thread.message_count]) |message| {
                        _ = self.persistence_worker.enqueue(.{ .upsert_message = persistence.MessageRecord.from(thread.id, &message) });
                    }
                }
            }
            var reconcile = persistence.ReconcileRecord{};
            for (model.projects[0..model.project_count]) |project| {
                reconcile.project_ids[reconcile.project_count] = project.id;
                reconcile.project_count += 1;
            }
            for (model.threads[0..model.thread_count]) |thread| {
                reconcile.thread_ids[reconcile.thread_count] = thread.id;
                reconcile.thread_count += 1;
            }
            _ = self.persistence_worker.enqueue(.{ .reconcile = reconcile });
        } else {
            for (model.persistence_clear_thread_ids[0..model.persistence_clear_thread_count]) |thread_id| {
                _ = self.persistence_worker.enqueue(.{ .clear_messages = thread_id });
            }
            for (model.persistence_thread_ids[0..model.persistence_thread_count]) |thread_id| {
                for (model.threads[0..model.thread_count], 0..) |thread, position| {
                    if (thread.id != thread_id) continue;
                    _ = self.persistence_worker.enqueue(.{ .upsert_thread = persistence.ThreadRecord.from(&thread, position) });
                    break;
                }
            }
            for (model.persistence_message_thread_ids[0..model.persistence_message_thread_count]) |thread_id| {
                const thread = model.threadByIdConst(thread_id) orelse continue;
                for (thread.messages[0..thread.message_count]) |message| {
                    _ = self.persistence_worker.enqueue(.{ .upsert_message = persistence.MessageRecord.from(thread.id, &message) });
                }
            }
        }
        if (model.persistence_meta_dirty) {
            _ = self.persistence_worker.enqueue(.{ .meta = .{
                .active_project_id = model.active_project_id,
                .active_thread_id = model.active_thread_id,
                .next_project_id = model.next_project_id,
                .next_thread_id = model.next_thread_id,
                .next_message_id = model.next_message_id,
            } });
        }
        model.persistence_workspace_dirty = false;
        model.persistence_structure_dirty = false;
        model.persistence_meta_dirty = false;
        model.persistence_thread_count = 0;
        model.persistence_message_thread_count = 0;
        model.persistence_clear_thread_count = 0;
    }
};

// -------------------------------------------------------------------- app

pub fn main(init: std.process.Init) !void {
    const api_key = init.environ_map.get("OPENROUTER_API_KEY") orelse "";
    const dev_mode_value = init.environ_map.get("SUPERCHAT_DEV_MODE") orelse "";
    const dev_mode = std.mem.eql(u8, dev_mode_value, "1") or std.ascii.eqlIgnoreCase(dev_mode_value, "true");
    const force_onboarding_value = init.environ_map.get("SUPERCHAT_FORCE_ONBOARDING") orelse "";
    const force_onboarding = std.mem.eql(u8, force_onboarding_value, "1") or std.ascii.eqlIgnoreCase(force_onboarding_value, "true");

    const directory_env: native_sdk.app_dirs.Env = .{
        .home = init.environ_map.get("HOME"),
        .xdg_config_home = init.environ_map.get("XDG_CONFIG_HOME"),
        .xdg_cache_home = init.environ_map.get("XDG_CACHE_HOME"),
        .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
        .xdg_state_home = init.environ_map.get("XDG_STATE_HOME"),
        .local_app_data = init.environ_map.get("LOCALAPPDATA"),
        .app_data = init.environ_map.get("APPDATA"),
        .temp = init.environ_map.get("TEMP"),
        .tmp = init.environ_map.get("TMP"),
        .tmpdir = init.environ_map.get("TMPDIR"),
    };
    var data_directory_buffer: [1024]u8 = undefined;
    const data_directory = try native_sdk.app_dirs.resolveOne(.{ .name = "superchat" }, native_sdk.app_dirs.currentPlatform(), directory_env, .data, &data_directory_buffer);
    try std.Io.Dir.cwd().createDirPath(init.io, data_directory);
    var database_path_buffer: [1200]u8 = undefined;
    const database_path = try native_sdk.app_dirs.join(native_sdk.app_dirs.currentPlatform(), &database_path_buffer, &.{ data_directory, "superchat.sqlite3" });
    var database = try storage.Database.open(database_path);
    var database_owned = true;
    errdefer if (database_owned) database.close();
    const now_ms = native_sdk.Clock.system.wallMs();
    try database.purgeExpired(now_ms -| archive_retention_ms);

    const app_state = try ChatApp.create(std.heap.page_allocator, .{
        .name = "superchat",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .on_chrome = onChrome,
        .on_command = onCommand,
        .view = CompiledAppView.build,
        .markup = if (builtin.mode == .Debug)
            .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io }
        else
            null,
    });
    defer app_state.destroy();
    app_state.model = initialModelWithOptions(api_key, dev_mode, force_onboarding);
    defer app_state.model.deinit();
    const loaded_workspace = try database.load(&app_state.model);
    if (loaded_workspace) {
        if (!app_state.model.normalizeLoadedWorkspace()) return error.InvalidWorkspace;
    } else {
        app_state.model.deinit();
        app_state.model = initialModelWithOptions(api_key, dev_mode, force_onboarding);
        try database.save(&app_state.model);
    }
    const persistence_worker = try persistence.Worker.create(std.heap.page_allocator, database, init.io);
    database_owned = false;
    var secure_app = SecureChatApp{ .inner = app_state.app(), .chat = app_state, .persistence_worker = persistence_worker };
    app_state.model.markWorkspaceDirty();
    secure_app.flushPersistence();

    try runner.runWithOptions(secure_app.app(), .{
        .app_name = "superchat",
        .window_title = "Superchat",
        .bundle_id = "dev.sscode.superchat",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = true,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
