//! Superchat: a fast, local-first native AI chat workspace.
//!
//! The interface is declarative `.native` markup. This file owns the
//! model/message/update loop and uses Native SDK's typed HTTP effect so
//! network work never blocks the window thread.

const std = @import("std");
const builtin = @import("builtin");
const superchat_options = @import("superchat_options");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
pub const workspace_storage = @import("storage.zig");
const storage = workspace_storage;
const persistence = @import("persistence.zig");
pub const workspace_mcp = @import("mcp.zig");
const mcp = workspace_mcp;

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
const codex_status_key: u64 = (1 << 61) + 2;
const claude_status_key: u64 = (1 << 61) + 3;
const codex_login_key: u64 = (1 << 61) + 4;
const claude_login_key: u64 = (1 << 61) + 5;
const model_search_timer: u64 = (1 << 52) + 1;
const openrouter_models_url = "https://openrouter.ai/api/v1/models";
const credential_service = "dev.sscode.superchat.credentials.v1";
const credential_account = "openrouter-api-key";
const onboarding_account = "onboarding-complete";
const onboarding_marker = "1";
const request_key_base: u64 = 1000;
const clipboard_key_base: u64 = 1 << 40;
const stream_flush_key_base: u64 = 1 << 44;
const draft_save_key_base: u64 = 1 << 48;
const database_poll_key: u64 = 1 << 52;
const toast_timer_key: u64 = (1 << 52) + 2;
const search_timer_key: u64 = (1 << 52) + 3;
const updates_request: u64 = (1 << 61) + 6;
const updates_url = "https://api.github.com/repos/sscode/superchat/releases/latest";
const releases_url_prefix = "https://github.com/sscode/superchat/releases/";
const stream_flush_interval_ms: u64 = 16;
const draft_save_interval_ms: u64 = 300;
const toast_duration_ms: u64 = 2200;
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
const max_toast_bytes = 96;
const max_search_results = 24;
const max_palette_workspace_results = 12;
const max_snippets = persistence.max_snippets;
const max_snippet_name_bytes = persistence.max_snippet_name_bytes;
const max_snippet_body_bytes = persistence.max_snippet_body_bytes;
const max_stream_line_bytes = 32 * 1024;
const max_request_bytes = native_sdk.max_effect_fetch_payload_bytes;
const max_attachments_per_message = 4;
const max_attachment_path_bytes = 1024;
const max_attachment_name_bytes = 128;
const max_attachment_total_bytes = 640 * 1024;
const attachment_read_key_base: u64 = 1 << 56;
const request_body_key_base: u64 = 1 << 55;
const mcp_helper_key: u64 = (1 << 61) + 7;
const mcp_timeout_key: u64 = (1 << 52) + 4;
const mcp_timeout_ms: u64 = 20_000;

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
    native_sdk.security.permission_filesystem,
    native_sdk.security.permission_dialog,
    native_sdk.security.permission_notifications,
};
const allowed_external_urls = [_][]const u8{"https://github.com/sscode/superchat/releases/*"};
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
    .titlebar = .standard,
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
    codex_subscription,
    claude_subscription,
};

pub const CredentialAction = enum { none, save, delete, complete_onboarding };
pub const RenameKind = enum { project, thread };
pub const ConnectionState = enum { disabled, checking, connected, disconnected, connecting, unavailable, failed };
pub const UpdateState = enum { idle, checking, current, available, failed };
pub const AttachmentKind = enum { image, pdf, text };
pub const PaletteAction = enum { search, new_thread, new_project_thread, move_thread, attach, tools, snippets, export_thread, export_workspace, archive, settings };
pub const ExportKind = enum { none, thread_markdown, workspace_json };
pub const McpOperation = enum { none, discover, call };

pub const Attachment = struct {
    kind: AttachmentKind = .text,
    path_storage: [max_attachment_path_bytes]u8 = undefined,
    path_len: usize = 0,
    name_storage: [max_attachment_name_bytes]u8 = undefined,
    name_len: usize = 0,
    bytes: []u8 = @constCast(&[_]u8{}),

    pub fn path(attachment: *const Attachment) []const u8 {
        return attachment.path_storage[0..attachment.path_len];
    }

    pub fn name(attachment: *const Attachment) []const u8 {
        return attachment.name_storage[0..attachment.name_len];
    }

    pub fn deinit(attachment: *Attachment, allocator: std.mem.Allocator) void {
        if (attachment.bytes.len > 0) allocator.free(attachment.bytes);
        attachment.* = .{};
    }
};

pub const ModelOption = struct {
    choice: ModelChoice,
    label: []const u8,
    slug: []const u8,
};

pub const QuickModel = struct {
    number: u8,
    label: []const u8,
    slug: []const u8,
    shortcut: []const u8,
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
    response_model_storage: [max_model_bytes]u8 = undefined,
    response_model_len: usize = 0,
    latency_ms: u32 = 0,
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    cost_micros: u64 = 0,
    attachments: [max_attachments_per_message]Attachment = [_]Attachment{.{}} ** max_attachments_per_message,
    attachment_count: usize = 0,

    pub fn content(message: *const Message) []const u8 {
        return message.content_storage[0..message.content_len];
    }

    pub fn isUser(message: *const Message) bool {
        return message.role == .user;
    }

    pub fn isAssistant(message: *const Message) bool {
        return message.role == .assistant;
    }

    pub fn responseModel(message: *const Message) []const u8 {
        return message.response_model_storage[0..message.response_model_len];
    }

    pub fn hasAttachments(message: *const Message) bool {
        return message.attachment_count > 0;
    }

    pub fn attachmentSummary(message: *const Message, arena: std.mem.Allocator) []const u8 {
        if (message.attachment_count == 0) return "";
        var writer: std.Io.Writer.Allocating = .init(arena);
        for (message.attachments[0..message.attachment_count], 0..) |*attachment, index| {
            if (index > 0) writer.writer.writeAll("  ·  ") catch return "Attachments";
            writer.writer.print("{s} {s}", .{ switch (attachment.kind) {
                .image => "Image",
                .pdf => "PDF",
                .text => "File",
            }, attachment.name() }) catch return "Attachments";
        }
        return writer.written();
    }

    fn deinit(message: *Message, allocator: std.mem.Allocator) void {
        for (message.attachments[0..message.attachment_count]) |*attachment| attachment.deinit(allocator);
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

pub const PromptSnippet = struct {
    id: u32 = 0,
    name_storage: [max_snippet_name_bytes]u8 = undefined,
    name_len: usize = 0,
    body_storage: [max_snippet_body_bytes]u8 = undefined,
    body_len: usize = 0,

    pub fn name(snippet: *const PromptSnippet) []const u8 {
        return snippet.name_storage[0..snippet.name_len];
    }

    pub fn body(snippet: *const PromptSnippet) []const u8 {
        return snippet.body_storage[0..snippet.body_len];
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
    unread: bool = false,
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
    request_path_storage: [128]u8 = undefined,
    request_path_len: usize = 0,
    draft_attachments: [max_attachments_per_message]Attachment = [_]Attachment{.{}} ** max_attachments_per_message,
    draft_attachment_count: usize = 0,
    request_started_ms: i64 = 0,
    request_prompt_tokens: u32 = 0,
    request_completion_tokens: u32 = 0,
    request_cost_micros: u64 = 0,
    total_cost_micros: u64 = 0,

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

    fn requestPath(thread: *const Thread) []const u8 {
        return thread.request_path_storage[0..thread.request_path_len];
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
        if (trimmed.len == 0 and (role != .user or thread.draft_attachment_count == 0)) return false;
        const visible_content = if (trimmed.len > 0) trimmed else "Please analyze the attached files.";
        const len = utf8PrefixLen(visible_content, max_message_bytes);
        if (!thread.ensureMessageCapacity(allocator, thread.message_count + 1)) return false;
        const owned = allocator.dupe(u8, visible_content[0..len]) catch return false;
        var message = Message{ .id = next_message_id.*, .role = role, .content_storage = owned, .content_len = len };
        if (role == .user) {
            message.attachment_count = thread.draft_attachment_count;
            for (thread.draft_attachments[0..thread.draft_attachment_count], 0..) |attachment, index| {
                message.attachments[index] = attachment;
                thread.draft_attachments[index] = .{};
            }
            thread.draft_attachment_count = 0;
        }
        thread.messages[thread.message_count] = message;
        thread.message_count += 1;
        next_message_id.* += 1;
        if (role == .user and thread.message_count == 1) thread.setTitle(if (trimmed.len > 0) trimmed else message.attachments[0].name());
        return true;
    }

    fn appendClonedMessage(thread: *Thread, allocator: std.mem.Allocator, next_message_id: *u32, source: *const Message) bool {
        if (!thread.ensureMessageCapacity(allocator, thread.message_count + 1)) return false;
        var cloned = source.*;
        cloned.content_storage = allocator.dupe(u8, source.content()) catch return false;
        for (source.attachments[0..source.attachment_count], 0..) |*source_attachment, index| {
            cloned.attachments[index].bytes = if (source_attachment.bytes.len > 0)
                allocator.dupe(u8, source_attachment.bytes) catch {
                    cloned.deinit(allocator);
                    return false;
                }
            else
                @constCast(&[_]u8{});
        }
        cloned.id = next_message_id.*;
        thread.messages[thread.message_count] = cloned;
        thread.message_count += 1;
        thread.total_cost_micros +|= cloned.cost_micros;
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
        for (thread.draft_attachments[0..thread.draft_attachment_count]) |*attachment| attachment.deinit(allocator);
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

pub const ProjectSidebarRow = struct {
    key: u64,
    id: u32,
    title: []const u8,
    prefix: []const u8,
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

pub const AttachmentRow = struct {
    index: u8,
    name: []const u8,
    detail: []const u8,
};

pub const SearchRow = struct {
    index: u8,
    title: []const u8,
    snippet: []const u8,
};

pub const PaletteWorkspaceRow = struct {
    key: u64,
    title: []const u8,
    detail: []const u8,
};

pub const MoveProjectRow = struct {
    id: u32,
    name: []const u8,
    selected: bool,
};

pub const SnippetRow = struct {
    id: u32,
    command: []const u8,
    preview: []const u8,
};

pub const McpServerRow = struct {
    id: u32,
    name: []const u8,
    detail: []const u8,
    toggle_label: []const u8,
};

pub const McpToolRow = struct {
    index: u8,
    title: []const u8,
    detail: []const u8,
};

const SearchEntry = struct {
    thread_id: u32 = 0,
    title_storage: [max_thread_title_bytes]u8 = undefined,
    title_len: usize = 0,
    snippet_storage: [180]u8 = undefined,
    snippet_len: usize = 0,
};

pub const PaletteActionRow = struct {
    id: PaletteAction,
    label: []const u8,
    shortcut: []const u8,
};

pub const MessageTruncation = struct {
    thread_id: u32,
    from_message_id: u32,
};

pub const DirtyMessage = struct {
    thread_id: u32,
    message_id: u32,
};

const UpdateRelease = struct {
    tag_name: []const u8 = "",
    html_url: []const u8 = "",
};

const PendingAttachment = struct {
    key: u64 = 0,
    thread_id: u32 = 0,
    kind: AttachmentKind = .text,
    path_storage: [max_attachment_path_bytes]u8 = undefined,
    path_len: usize = 0,

    fn path(pending: *const PendingAttachment) []const u8 {
        return pending.path_storage[0..pending.path_len];
    }
};

pub const chats_project_id: u32 = 0;
const chats_project_name = "Chats";

pub const cmd_new_thread = "workspace.new-thread";
pub const cmd_new_project_thread = "workspace.new-project-thread";
pub const cmd_new_project = "workspace.new-project";
pub const cmd_previous_thread = "workspace.previous-thread";
pub const cmd_next_thread = "workspace.next-thread";
pub const cmd_previous_project = "workspace.previous-project";
pub const cmd_next_project = "workspace.next-project";
pub const cmd_focus_composer = "workspace.focus-composer";
pub const cmd_attach_files = "workspace.attach-files";
pub const cmd_model_picker = "workspace.model-picker";
pub const cmd_search = "workspace.search";
pub const cmd_retry_latest = "workspace.retry-latest";
pub const cmd_stop = "workspace.stop";
pub const cmd_auto_model = "workspace.model-auto";
pub const cmd_codex_subscription = "workspace.model-codex-subscription";
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
pub const cmd_top_level_chats = "workspace.top-level-chats";
pub const cmd_load_older = "workspace.load-older";
pub const cmd_move_thread = "workspace.move-thread";
pub const cmd_export_thread = "workspace.export-thread";
pub const cmd_export_workspace = "workspace.export-workspace";
pub const cmd_snippets = "workspace.snippets";
pub const cmd_mcp_tools = "workspace.mcp-tools";
pub const project_slot_commands = [_][]const u8{
    "workspace.project-1",
    "workspace.project-2",
    "workspace.project-3",
    "workspace.project-4",
    "workspace.project-5",
    "workspace.project-6",
    "workspace.project-7",
    "workspace.project-8",
    "workspace.project-9",
};
pub const thread_slot_commands = [_][]const u8{
    "workspace.thread-1",
    "workspace.thread-2",
    "workspace.thread-3",
    "workspace.thread-4",
    "workspace.thread-5",
    "workspace.thread-6",
    "workspace.thread-7",
    "workspace.thread-8",
    "workspace.thread-9",
};
pub const quick_model_commands = [_][]const u8{
    "workspace.model-1",
    "workspace.model-2",
    "workspace.model-3",
    "workspace.model-4",
    "workspace.model-5",
    "workspace.model-6",
    "workspace.model-7",
    "workspace.model-8",
    "workspace.model-9",
};

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

fn forkChoiceBit(choice: ModelChoice) u16 {
    return @as(u16, 1) << @intCast(@intFromEnum(choice));
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

fn requestBodyKey(thread_id: u32) u64 {
    return request_body_key_base + thread_id;
}

fn requestBodyThreadId(key: u64) ?u32 {
    if (key <= request_body_key_base or key - request_body_key_base > std.math.maxInt(u32)) return null;
    return @intCast(key - request_body_key_base);
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

const ApiUsage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    cost: f64 = 0,
};

const ApiStreamChunk = struct {
    choices: []const ApiStreamChoice = &.{},
    model: []const u8 = "",
    usage: ?ApiUsage = null,
    @"error": ?ApiError = null,
};

const CodexItem = struct {
    type: []const u8 = "",
    text: []const u8 = "",
};

const CodexStreamEvent = struct {
    type: []const u8 = "",
    item: ?CodexItem = null,
};

const ClaudeDelta = struct {
    type: []const u8 = "",
    text: []const u8 = "",
};

const ClaudeEvent = struct {
    type: []const u8 = "",
    delta: ?ClaudeDelta = null,
};

const ClaudeStreamEvent = struct {
    type: []const u8 = "",
    event: ?ClaudeEvent = null,
    is_error: bool = false,
    result: []const u8 = "",
};

const RemoteModel = struct { id: []const u8, name: []const u8 = "" };
const RemoteModels = struct { data: []const RemoteModel = &.{} };

pub const Msg = union(enum) {
    draft_edit: canvas.TextInputEvent,
    composer_newline,
    open_file_picker,
    files_dropped: native_sdk.platform.FileDropEvent,
    attachment_file_result: native_sdk.EffectFileResult,
    request_body_written: native_sdk.EffectFileResult,
    remove_attachment: u8,
    model_edit: canvas.TextInputEvent,
    api_key_edit: canvas.TextInputEvent,
    model_search_edit: canvas.TextInputEvent,
    search_edit: canvas.TextInputEvent,
    fork_seed_edit: canvas.TextInputEvent,
    toggle_model_picker,
    select_model: ModelChoice,
    select_quick_model: u8,
    select_auto_model,
    select_codex_subscription,
    select_claude_subscription,
    select_custom_model,
    select_catalog_model: u32,
    toggle_model_favorite: u32,
    model_search: native_sdk.EffectTimer,
    search_timer: native_sdk.EffectTimer,
    database_poll: native_sdk.EffectTimer,
    open_search,
    select_search_result: u8,
    select_palette_workspace: u64,
    palette_action: PaletteAction,
    open_settings,
    close_settings,
    save_settings,
    remove_api_key,
    connect_codex,
    connect_claude,
    finish_onboarding,
    skip_onboarding,
    copy_message: u32,
    edit_message: u32,
    retry_message: u32,
    retry_latest,
    stop,
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
    open_move_thread,
    move_thread_to: u32,
    open_snippets,
    snippet_name_edit: canvas.TextInputEvent,
    snippet_body_edit: canvas.TextInputEvent,
    save_snippet,
    use_snippet: u32,
    delete_snippet: u32,
    mcp_server_name_edit: canvas.TextInputEvent,
    mcp_server_command_edit: canvas.TextInputEvent,
    add_mcp_server,
    remove_mcp_server: u32,
    toggle_mcp_server: u32,
    refresh_mcp_server: u32,
    open_mcp_tools,
    select_mcp_tool: u8,
    mcp_exit: native_sdk.EffectExit,
    mcp_timeout: native_sdk.EffectTimer,
    export_thread,
    export_workspace,
    export_started,
    export_finished: bool,
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
    new_project_thread,
    select_top_level_chats,
    select_project_slot: u8,
    select_thread_slot: u8,
    select_sidebar_row: u64,
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
    stream_line: native_sdk.EffectLine,
    harness_line: native_sdk.EffectLine,
    harness_exit: native_sdk.EffectExit,
    openrouter_exit: native_sdk.EffectExit,
    connection_exit: native_sdk.EffectExit,
    stream_flush: native_sdk.EffectTimer,
    persist_draft: native_sdk.EffectTimer,
    dismiss_toast: native_sdk.EffectTimer,
    toggle_notifications,
    check_updates,
    open_update,
    response: native_sdk.EffectResponse,
    chrome_changed: native_sdk.WindowChrome,

    pub const view_unbound = .{
        "response",
        "stream_line",
        "harness_line",
        "harness_exit",
        "openrouter_exit",
        "connection_exit",
        "stream_flush",
        "database_poll",
        "model_search",
        "search_timer",
        "persist_draft",
        "dismiss_toast",
        "mcp_exit",
        "mcp_timeout",
        "clipboard_result",
        "files_dropped",
        "attachment_file_result",
        "request_body_written",
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
        "retry_latest",
        "stop",
        "clear",
        "open_search",
        "check_updates",
        "open_archive",
        "close_overlay",
        "select_model",
        "select_top_level_chats",
        "select_project_slot",
        "select_thread_slot",
        "open_file_picker",
        "open_move_thread",
        "open_snippets",
        "open_mcp_tools",
        "export_thread",
        "export_workspace",
        "export_started",
        "export_finished",
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
    search_open: bool = false,
    search_buffer: canvas.TextBuffer(persistence.max_search_query_bytes) = .{},
    search_results: [max_search_results]SearchEntry = [_]SearchEntry{.{}} ** max_search_results,
    search_result_count: usize = 0,
    search_generation: u32 = 0,
    search_loading: bool = false,
    search_request_pending: bool = false,
    settings_open: bool = false,
    onboarding_open: bool = false,
    dev_mode: bool = false,
    force_onboarding: bool = false,
    key_validation_pending: bool = false,
    key_validation_onboarding: bool = false,
    fork_open: bool = false,
    fork_source_thread_id: u32 = 0,
    fork_source_message_id: u32 = 0,
    fork_model_mask: u16 = 0,
    fork_seed_buffer: canvas.TextBuffer(max_draft_bytes) = .{},
    rename_open: bool = false,
    rename_kind: RenameKind = .thread,
    rename_id: u32 = 0,
    rename_buffer: canvas.TextBuffer(max_thread_title_bytes) = .{},
    move_open: bool = false,
    move_thread_id: u32 = 0,
    snippets: [max_snippets]PromptSnippet = undefined,
    snippet_count: usize = 0,
    next_snippet_id: u32 = 1,
    snippet_name_buffer: canvas.TextBuffer(max_snippet_name_bytes) = .{},
    snippet_body_buffer: canvas.TextBuffer(max_snippet_body_bytes) = .{},
    snippets_dirty: bool = false,
    mcp_servers: [mcp.max_servers]mcp.Server = undefined,
    mcp_server_count: usize = 0,
    next_mcp_server_id: u32 = 1,
    mcp_tools: [mcp.max_tools]mcp.Tool = undefined,
    mcp_tool_count: usize = 0,
    mcp_server_name_buffer: canvas.TextBuffer(mcp.max_server_name_bytes) = .{},
    mcp_server_command_buffer: canvas.TextBuffer(mcp.max_command_bytes) = .{},
    mcp_arguments_buffer: canvas.TextBuffer(mcp.max_arguments_bytes) = .{},
    mcp_selected_tool: usize = std.math.maxInt(usize),
    mcp_operation: McpOperation = .none,
    mcp_operation_server_id: u32 = 0,
    mcp_operation_thread_id: u32 = 0,
    mcp_servers_dirty: bool = false,
    executable_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined,
    executable_path_len: usize = 0,
    export_request: ExportKind = .none,
    export_thread_id: u32 = 0,
    export_pending: bool = false,
    archive_open: bool = false,
    clear_confirm_thread_id: u32 = 0,
    delete_confirm_open: bool = false,
    delete_kind: RenameKind = .thread,
    delete_id: u32 = 0,
    clock: native_sdk.Clock = .system,
    composer_focus_flip: bool = false,
    credential_action: CredentialAction = .none,
    header_height: f32 = header_natural_height,
    toast_storage: [max_toast_bytes]u8 = undefined,
    toast_len: usize = 0,
    notifications_enabled: bool = true,
    pending_notification_thread_id: u32 = 0,
    update_state: UpdateState = .idle,
    update_status_storage: [120]u8 = undefined,
    update_status_len: usize = 0,
    update_url_storage: [256]u8 = undefined,
    update_url_len: usize = 0,
    open_update_requested: bool = false,
    persistence_structure_dirty: bool = false,
    persistence_meta_dirty: bool = false,
    persistence_thread_ids: [persistence_batch_ids]u32 = undefined,
    persistence_thread_count: usize = 0,
    persistence_messages: [persistence_batch_ids]DirtyMessage = undefined,
    persistence_message_count: usize = 0,
    persistence_clear_thread_ids: [persistence_batch_ids]u32 = undefined,
    persistence_clear_thread_count: usize = 0,
    persistence_truncations: [persistence_batch_ids]MessageTruncation = undefined,
    persistence_truncate_count: usize = 0,
    history_request_thread_id: u32 = 0,
    stream_parse_storage: [max_stream_line_bytes * 2]u8 = undefined,
    codex_connection: ConnectionState = .checking,
    claude_connection: ConnectionState = .checking,
    codex_login_thread_id: u32 = 0,
    claude_login_thread_id: u32 = 0,
    pending_attachments: [16]PendingAttachment = [_]PendingAttachment{.{}} ** 16,
    pending_attachment_count: usize = 0,
    next_attachment_read_key: u64 = attachment_read_key_base + 1,
    file_picker_requested: bool = false,

    // These are implementation state read by the derived bindings below
    // or by update/effects; they are intentionally not exposed directly
    // to the markup contract.
    pub const view_unbound = .{
        "projects",
        "allocator",
        "project_count",
        "threads",
        "thread_count",
        "active_project_id",
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
        "search_loading",
        "update_state",
        "search_buffer",
        "search_results",
        "search_result_count",
        "search_generation",
        "search_request_pending",
        "dev_mode",
        "composer_focus_flip",
        "hasMessages",
        "cannotClear",
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
        "move_thread_id",
        "snippets",
        "snippet_count",
        "next_snippet_id",
        "snippet_name_buffer",
        "snippet_body_buffer",
        "snippets_dirty",
        "mcp_servers",
        "mcp_server_count",
        "next_mcp_server_id",
        "mcp_tools",
        "mcp_tool_count",
        "mcp_server_name_buffer",
        "mcp_server_command_buffer",
        "mcp_arguments_buffer",
        "mcp_selected_tool",
        "mcp_operation",
        "mcp_operation_server_id",
        "mcp_operation_thread_id",
        "mcp_servers_dirty",
        "executable_path_storage",
        "executable_path_len",
        "export_request",
        "export_thread_id",
        "export_pending",
        "clock",
        "toast_storage",
        "toast_len",
        "pending_notification_thread_id",
        "update_status_storage",
        "update_status_len",
        "update_url_storage",
        "update_url_len",
        "open_update_requested",
        "persistence_structure_dirty",
        "persistence_meta_dirty",
        "persistence_thread_ids",
        "persistence_thread_count",
        "persistence_messages",
        "persistence_message_count",
        "persistence_clear_thread_ids",
        "persistence_clear_thread_count",
        "persistence_truncations",
        "persistence_truncate_count",
        "history_request_thread_id",
        "stream_parse_storage",
        "codex_connection",
        "claude_connection",
        "codex_login_thread_id",
        "claude_login_thread_id",
        "pending_attachments",
        "pending_attachment_count",
        "next_attachment_read_key",
        "file_picker_requested",
        "clear_confirm_thread_id",
        "delete_kind",
        "delete_id",
        "activeThread",
        "activeThreadConst",
        "threadById",
        "active_thread_id",
        "modelOptions",
        "activeModelChoice",
        "archiveEmpty",
    };

    pub const quickModels = [_]QuickModel{
        .{ .number = 1, .label = "GPT-5.5", .slug = "openai/gpt-5.5", .shortcut = "Cmd + Shift + 1" },
        .{ .number = 2, .label = "GPT-5.4 Mini", .slug = "openai/gpt-5.4-mini", .shortcut = "Cmd + Shift + 2" },
        .{ .number = 3, .label = "Claude Sonnet 5", .slug = "anthropic/claude-sonnet-5", .shortcut = "Cmd + Shift + 3" },
        .{ .number = 4, .label = "Claude Opus 4.8", .slug = "anthropic/claude-opus-4.8", .shortcut = "Cmd + Shift + 4" },
        .{ .number = 5, .label = "Gemini 3.5 Flash", .slug = "google/gemini-3.5-flash", .shortcut = "Cmd + Shift + 5" },
        .{ .number = 6, .label = "Gemini 3.1 Pro", .slug = "google/gemini-3.1-pro-preview", .shortcut = "Cmd + Shift + 6" },
        .{ .number = 7, .label = "GLM 5.2", .slug = "z-ai/glm-5.2", .shortcut = "Cmd + Shift + 7" },
        .{ .number = 8, .label = "Kimi K2.6", .slug = "moonshotai/kimi-k2.6", .shortcut = "Cmd + Shift + 8" },
        .{ .number = 9, .label = "Kimi K2.7 Code", .slug = "moonshotai/kimi-k2.7-code", .shortcut = "Cmd + Shift + 9" },
    };

    pub const modelOptions = [_]ModelOption{
        .{ .choice = .auto, .label = "Auto · best fit", .slug = "openrouter/auto" },
        .{ .choice = .claude_sonnet, .label = "Claude Sonnet 5", .slug = "anthropic/claude-sonnet-5" },
        .{ .choice = .claude_opus, .label = "Claude Opus 4.8", .slug = "anthropic/claude-opus-4.8" },
        .{ .choice = .gpt, .label = "GPT-5.5", .slug = "openai/gpt-5.5" },
        .{ .choice = .gemini, .label = "Gemini 3.5 Flash", .slug = "google/gemini-3.5-flash" },
        .{ .choice = .deepseek, .label = "DeepSeek V4 Pro", .slug = "deepseek/deepseek-v4-pro" },
        .{ .choice = .custom, .label = "Custom model…", .slug = "" },
        .{ .choice = .codex_subscription, .label = "Codex · ChatGPT", .slug = "codex/default" },
        .{ .choice = .claude_subscription, .label = "Claude · Pro/Max · Experimental", .slug = "sonnet" },
    };

    pub const shortcutHints = [_]ShortcutHint{
        .{ .action = "Move keyboard focus", .keys = "Tab / Shift + Tab" },
        .{ .action = "Activate focused control", .keys = "Enter / Space" },
        .{ .action = "New top-level chat", .keys = "Cmd + N" },
        .{ .action = "New chat in project", .keys = "Cmd + Option + N" },
        .{ .action = "New project", .keys = "Cmd + Shift + N" },
        .{ .action = "Previous chat", .keys = "Cmd + [" },
        .{ .action = "Next chat", .keys = "Cmd + ]" },
        .{ .action = "Top-level chats", .keys = "Cmd + 0" },
        .{ .action = "Project 1–9", .keys = "Cmd + 1–9" },
        .{ .action = "Chat 1–9", .keys = "Option + 1–9" },
        .{ .action = "Previous project", .keys = "Cmd + Option + Up" },
        .{ .action = "Next project", .keys = "Cmd + Option + Down" },
        .{ .action = "Focus message", .keys = "Cmd + L" },
        .{ .action = "Attach images or files", .keys = "Cmd + U" },
        .{ .action = "Open MCP tools", .keys = "Cmd + Option + T" },
        .{ .action = "Choose model", .keys = "Cmd + K" },
        .{ .action = "Search every chat", .keys = "Cmd + F" },
        .{ .action = "Quick model: Auto", .keys = "Cmd + Shift + 0" },
        .{ .action = "Quick model: GPT-5.5", .keys = "Cmd + Shift + 1" },
        .{ .action = "Quick model: GPT-5.4 Mini", .keys = "Cmd + Shift + 2" },
        .{ .action = "Quick model: Claude Sonnet 5", .keys = "Cmd + Shift + 3" },
        .{ .action = "Quick model: Claude Opus 4.8", .keys = "Cmd + Shift + 4" },
        .{ .action = "Quick model: Gemini 3.5 Flash", .keys = "Cmd + Shift + 5" },
        .{ .action = "Quick model: Gemini 3.1 Pro", .keys = "Cmd + Shift + 6" },
        .{ .action = "Quick model: GLM 5.2", .keys = "Cmd + Shift + 7" },
        .{ .action = "Quick model: Kimi K2.6", .keys = "Cmd + Shift + 8" },
        .{ .action = "Quick model: Kimi K2.7 Code", .keys = "Cmd + Shift + 9" },
        .{ .action = "Use Codex", .keys = "Cmd + Option + Shift + 1" },
        .{ .action = "Open settings", .keys = "Cmd + ," },
        .{ .action = "Fork latest response", .keys = "Cmd + Shift + F" },
        .{ .action = "Copy latest response", .keys = "Cmd + Shift + C" },
        .{ .action = "Retry latest response", .keys = "Cmd + Shift + T" },
        .{ .action = "Stop response", .keys = "Cmd + ." },
        .{ .action = "Rename chat", .keys = "Cmd + Shift + R" },
        .{ .action = "Rename project", .keys = "Cmd + Option + R" },
        .{ .action = "Archive chat", .keys = "Cmd + Shift + E" },
        .{ .action = "Archive project", .keys = "Cmd + Option + E" },
        .{ .action = "Open archive", .keys = "Cmd + Shift + H" },
        .{ .action = "Clear current chat", .keys = "Cmd + Shift + Backspace" },
        .{ .action = "Load earlier messages", .keys = "Cmd + Option + L" },
        .{ .action = "Move chat", .keys = "Cmd + Shift + M" },
        .{ .action = "Prompt snippets", .keys = "Cmd + Option + P" },
        .{ .action = "Export current chat", .keys = "Cmd + Shift + S" },
        .{ .action = "Export workspace backup", .keys = "Cmd + Option + Shift + S" },
        .{ .action = "Send message", .keys = "Enter" },
        .{ .action = "New line in message", .keys = "Cmd + Enter" },
        .{ .action = "Close overlay", .keys = "Escape" },
    };

    pub const paletteActionRows = [_]PaletteActionRow{
        .{ .id = .search, .label = "Search every chat", .shortcut = "Cmd + F" },
        .{ .id = .new_thread, .label = "New top-level chat", .shortcut = "Cmd + N" },
        .{ .id = .new_project_thread, .label = "New chat in project", .shortcut = "Cmd + Opt + N" },
        .{ .id = .move_thread, .label = "Move current chat", .shortcut = "Cmd + Shift + M" },
        .{ .id = .attach, .label = "Attach files", .shortcut = "Cmd + U" },
        .{ .id = .tools, .label = "MCP tools", .shortcut = "Cmd + Opt + T" },
        .{ .id = .snippets, .label = "Prompt snippets", .shortcut = "Cmd + Opt + P" },
        .{ .id = .export_thread, .label = "Export current chat", .shortcut = "Cmd + Shift + S" },
        .{ .id = .export_workspace, .label = "Export workspace backup", .shortcut = "Cmd + Opt + Shift + S" },
        .{ .id = .archive, .label = "Open archive", .shortcut = "Cmd + Shift + H" },
        .{ .id = .settings, .label = "Settings and shortcuts", .shortcut = "Cmd + ," },
    };

    pub fn paletteWorkspaceRows(model: *const Model, arena: std.mem.Allocator) []const PaletteWorkspaceRow {
        const rows = arena.alloc(PaletteWorkspaceRow, max_palette_workspace_results) catch return &.{};
        const query = std.mem.trim(u8, model.model_search_buffer.text(), " \t\r\n");
        var count: usize = 0;
        for (model.threads[0..model.thread_count]) |*thread| {
            if (count == rows.len or thread.isArchived()) break;
            const project = model.projectByIdConst(thread.project_id) orelse continue;
            if (project.isArchived()) continue;
            if (query.len > 0 and std.ascii.indexOfIgnoreCase(thread.title(), query) == null and std.ascii.indexOfIgnoreCase(project.name(), query) == null) continue;
            rows[count] = .{
                .key = (@as(u64, 1) << 32) | thread.id,
                .title = thread.title(),
                .detail = if (thread.project_id == chats_project_id) "Chat" else project.name(),
            };
            count += 1;
        }
        if (count < rows.len) for (model.projects[0..model.project_count]) |*project| {
            if (count == rows.len) break;
            if (project.id == chats_project_id or project.isArchived()) continue;
            if (query.len > 0 and std.ascii.indexOfIgnoreCase(project.name(), query) == null) continue;
            rows[count] = .{ .key = project.id, .title = project.name(), .detail = "Project" };
            count += 1;
        };
        return rows[0..count];
    }

    pub fn moveProjectRows(model: *const Model, arena: std.mem.Allocator) []const MoveProjectRow {
        const rows = arena.alloc(MoveProjectRow, model.project_count) catch return &.{};
        const thread = model.threadByIdConst(model.move_thread_id);
        var count: usize = 0;
        for (model.projects[0..model.project_count]) |*project| {
            if (project.isArchived()) continue;
            rows[count] = .{
                .id = project.id,
                .name = if (project.id == chats_project_id) "Top-level chats" else project.name(),
                .selected = thread != null and thread.?.project_id == project.id,
            };
            count += 1;
        }
        return rows[0..count];
    }

    pub fn snippetRows(model: *const Model, arena: std.mem.Allocator) []const SnippetRow {
        const rows = arena.alloc(SnippetRow, model.snippet_count) catch return &.{};
        for (model.snippets[0..model.snippet_count], 0..) |*snippet, index| {
            rows[index] = .{
                .id = snippet.id,
                .command = std.fmt.allocPrint(arena, "/{s}", .{snippet.name()}) catch snippet.name(),
                .preview = snippet.body()[0..utf8PrefixLen(snippet.body(), 120)],
            };
        }
        return rows;
    }

    pub fn snippetName(model: *const Model) []const u8 {
        return model.snippet_name_buffer.text();
    }

    pub fn snippetBody(model: *const Model) []const u8 {
        return model.snippet_body_buffer.text();
    }

    pub fn cannotSaveSnippet(model: *const Model) bool {
        const name = std.mem.trim(u8, model.snippet_name_buffer.text(), " /\t\r\n");
        return name.len == 0 or model.snippet_body_buffer.isEmpty() or model.snippet_count == model.snippets.len;
    }

    pub fn mcpServerRows(model: *const Model, arena: std.mem.Allocator) []const McpServerRow {
        const rows = arena.alloc(McpServerRow, model.mcp_server_count) catch return &.{};
        for (model.mcp_servers[0..model.mcp_server_count], 0..) |*server, index| {
            const state = switch (server.state) {
                .idle => if (server.enabled) "Not checked" else "Disabled",
                .connecting => "Connecting…",
                .connected => std.fmt.allocPrint(arena, "{d} tool{s}", .{ server.tool_count, if (server.tool_count == 1) "" else "s" }) catch "Connected",
                .failed => if (server.status_len > 0) server.status() else "Connection failed",
            };
            rows[index] = .{
                .id = server.id,
                .name = server.name(),
                .detail = state,
                .toggle_label = if (server.enabled) "Disable" else "Enable",
            };
        }
        return rows;
    }

    pub fn mcpToolRows(model: *const Model, arena: std.mem.Allocator) []const McpToolRow {
        const rows = arena.alloc(McpToolRow, model.mcp_tool_count) catch return &.{};
        var count: usize = 0;
        for (model.mcp_tools[0..model.mcp_tool_count], 0..) |*tool, index| {
            const server = model.mcpServerByIdConst(tool.server_id) orelse continue;
            if (!server.enabled) continue;
            rows[count] = .{
                .index = @intCast(index),
                .title = tool.title(),
                .detail = std.fmt.allocPrint(arena, "{s} · {s}", .{ server.name(), tool.name() }) catch tool.name(),
            };
            count += 1;
        }
        return rows[0..count];
    }

    pub fn mcpServerName(model: *const Model) []const u8 {
        return model.mcp_server_name_buffer.text();
    }

    pub fn mcpServerCommand(model: *const Model) []const u8 {
        return model.mcp_server_command_buffer.text();
    }

    fn mcpToolSelected(model: *const Model) bool {
        return model.mcp_selected_tool < model.mcp_tool_count;
    }

    pub fn cannotAddMcpServer(model: *const Model) bool {
        return model.mcp_server_count == model.mcp_servers.len or
            std.mem.trim(u8, model.mcp_server_name_buffer.text(), " \t\r\n").len == 0 or
            std.mem.trim(u8, model.mcp_server_command_buffer.text(), " \t\r\n").len == 0;
    }

    pub fn mcpBusy(model: *const Model) bool {
        return model.mcp_operation != .none;
    }

    pub fn searchText(model: *const Model) []const u8 {
        return model.search_buffer.text();
    }

    pub fn searchRows(model: *const Model, arena: std.mem.Allocator) []const SearchRow {
        const rows = arena.alloc(SearchRow, model.search_result_count) catch return &.{};
        for (model.search_results[0..model.search_result_count], 0..) |*entry, index| {
            rows[index] = .{
                .index = @intCast(index),
                .title = entry.title_storage[0..entry.title_len],
                .snippet = entry.snippet_storage[0..entry.snippet_len],
            };
        }
        return rows;
    }

    pub fn updateStatus(model: *const Model) []const u8 {
        if (model.update_status_len > 0) return model.update_status_storage[0..model.update_status_len];
        return "Version " ++ superchat_options.version;
    }

    pub fn updateButtonText(model: *const Model) []const u8 {
        return if (model.update_state == .available) "View available update" else "Check for updates";
    }

    pub fn updateButtonDisabled(model: *const Model) bool {
        return model.update_state == .checking;
    }

    pub fn draft(model: *const Model) []const u8 {
        const thread = model.activeThreadConst() orelse return "";
        return thread.draft();
    }

    pub fn draftAttachmentRows(model: *const Model, arena: std.mem.Allocator) []const AttachmentRow {
        const thread = model.activeThreadConst() orelse return &.{};
        const rows = arena.alloc(AttachmentRow, thread.draft_attachment_count) catch return &.{};
        for (thread.draft_attachments[0..thread.draft_attachment_count], 0..) |*attachment, index| {
            rows[index] = .{
                .index = @intCast(index),
                .name = attachment.name(),
                .detail = std.fmt.allocPrint(arena, "{s} · {d} KB", .{
                    switch (attachment.kind) {
                        .image => "Image",
                        .pdf => "PDF",
                        .text => "File",
                    },
                    (attachment.bytes.len + 1023) / 1024,
                }) catch "Attached",
            };
        }
        return rows;
    }

    fn attachmentLoading(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return false;
        for (model.pending_attachments[0..model.pending_attachment_count]) |pending| {
            if (pending.thread_id == thread.id) return true;
        }
        return false;
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

    fn appendDirtyMessage(model: *Model, thread_id: u32, message_id: u32) void {
        for (model.persistence_messages[0..model.persistence_message_count]) |existing| {
            if (existing.thread_id == thread_id and existing.message_id == message_id) return;
        }
        if (model.persistence_message_count == model.persistence_messages.len) return;
        model.persistence_messages[model.persistence_message_count] = .{ .thread_id = thread_id, .message_id = message_id };
        model.persistence_message_count += 1;
    }

    fn markMessageDirty(model: *Model, thread_id: u32, message_id: u32) void {
        model.markThreadDirty(thread_id);
        model.appendDirtyMessage(thread_id, message_id);
        model.persistence_meta_dirty = true;
    }

    fn markThreadMessagesDirty(model: *Model, thread_id: u32) void {
        const thread = model.threadByIdConst(thread_id) orelse return;
        model.markThreadDirty(thread_id);
        for (thread.messages[0..thread.message_count]) |message| model.appendDirtyMessage(thread_id, message.id);
        model.persistence_meta_dirty = true;
    }

    fn markMessagesCleared(model: *Model, thread_id: u32) void {
        model.markThreadDirty(thread_id);
        appendUniqueId(&model.persistence_clear_thread_ids, &model.persistence_clear_thread_count, thread_id);
        model.removeDirtyMessagesFrom(thread_id, 0);
        model.persistence_meta_dirty = true;
    }

    fn removeDirtyMessagesFrom(model: *Model, thread_id: u32, from_message_id: u32) void {
        var kept: usize = 0;
        for (model.persistence_messages[0..model.persistence_message_count]) |dirty| {
            if (dirty.thread_id == thread_id and dirty.message_id >= from_message_id) continue;
            model.persistence_messages[kept] = dirty;
            kept += 1;
        }
        model.persistence_message_count = kept;
    }

    fn markMessagesTruncated(model: *Model, thread_id: u32, from_message_id: u32) void {
        model.markThreadDirty(thread_id);
        model.removeDirtyMessagesFrom(thread_id, from_message_id);
        for (model.persistence_truncations[0..model.persistence_truncate_count]) |*existing| {
            if (existing.thread_id != thread_id) continue;
            existing.from_message_id = @min(existing.from_message_id, from_message_id);
            return;
        }
        if (model.persistence_truncate_count == model.persistence_truncations.len) return;
        model.persistence_truncations[model.persistence_truncate_count] = .{ .thread_id = thread_id, .from_message_id = from_message_id };
        model.persistence_truncate_count += 1;
        model.persistence_meta_dirty = true;
    }

    pub fn brandLabel(model: *const Model) []const u8 {
        return if (model.dev_mode) "Superchat · Dev" else "Superchat";
    }

    pub fn composerKey(model: *const Model) []const u8 {
        return if (model.composer_focus_flip) "composer-a" else "composer-b";
    }

    fn focusComposer(model: *Model) void {
        model.composer_focus_flip = !model.composer_focus_flip;
    }

    pub fn toastVisible(model: *const Model) bool {
        return model.toast_len > 0;
    }

    pub fn toastText(model: *const Model) []const u8 {
        return model.toast_storage[0..model.toast_len];
    }

    fn showToast(model: *Model, message: []const u8, fx: *Effects) void {
        const len = utf8PrefixLen(message, max_toast_bytes);
        @memcpy(model.toast_storage[0..len], message[0..len]);
        model.toast_len = len;
        fx.startTimer(.{ .key = toast_timer_key, .interval_ms = toast_duration_ms, .on_fire = Effects.timerMsg(.dismiss_toast) });
    }

    pub fn projectSidebarRows(model: *const Model, arena: std.mem.Allocator) []const ProjectSidebarRow {
        const out = arena.alloc(ProjectSidebarRow, model.project_count + model.thread_count) catch return &.{};
        var count: usize = 0;
        for (model.projects[0..model.project_count]) |*project| {
            if (project.id == chats_project_id or project.isArchived()) continue;
            out[count] = .{
                .key = project.id,
                .id = project.id,
                .title = project.name(),
                .prefix = "",
                .selected = project.id == model.active_project_id,
            };
            count += 1;
            for (model.threads[0..model.thread_count]) |*thread| {
                if (thread.project_id != project.id or thread.isArchived()) continue;
                out[count] = .{
                    .key = (@as(u64, 1) << 32) | thread.id,
                    .id = thread.id,
                    .title = if (thread.sending)
                        std.fmt.allocPrint(arena, "{s} · responding", .{thread.title()}) catch thread.title()
                    else if (thread.unread)
                        std.fmt.allocPrint(arena, "{s} · new", .{thread.title()}) catch thread.title()
                    else
                        thread.title(),
                    .prefix = "    ",
                    .selected = thread.id == model.active_thread_id,
                };
                count += 1;
            }
        }
        return out[0..count];
    }

    pub fn topLevelThreadRows(model: *const Model, arena: std.mem.Allocator) []const ThreadRow {
        const out = arena.alloc(ThreadRow, model.thread_count) catch return &.{};
        var count: usize = 0;
        for (model.threads[0..model.thread_count]) |*thread| {
            if (thread.project_id != chats_project_id or thread.isArchived()) continue;
            out[count] = .{
                .id = thread.id,
                .title = if (thread.sending)
                    std.fmt.allocPrint(arena, "{s} · responding", .{thread.title()}) catch thread.title()
                else if (thread.unread)
                    std.fmt.allocPrint(arena, "{s} · new", .{thread.title()}) catch thread.title()
                else
                    thread.title(),
                .selected = thread.id == model.active_thread_id,
            };
            count += 1;
        }
        return out[0..count];
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

    pub fn cannotManageProject(model: *const Model) bool {
        return model.active_project_id == chats_project_id;
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
            if (project.id == chats_project_id or !project.isArchived()) continue;
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
        for (quickModels) |option| {
            if (std.mem.eql(u8, option.slug, thread.modelName())) return option.label;
        }
        if (thread.model_choice == .custom) return thread.modelName();
        for (modelOptions) |option| {
            if (option.choice == thread.model_choice) return option.label;
        }
        return "Custom model";
    }

    pub fn headerConnectionLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const thread = model.activeThreadConst() orelse return "No model connection";
        if (thread.active_model_len > 0) {
            const active_model = thread.active_model_storage[0..thread.active_model_len];
            return std.fmt.allocPrint(arena, "Connected · {s}", .{active_model}) catch active_model;
        }
        return switch (thread.model_choice) {
            .codex_subscription => switch (model.codex_connection) {
                .connected => "Codex connected",
                .checking => "Checking Codex…",
                .connecting => "Connecting Codex…",
                .disconnected => "Codex not connected",
                .unavailable => "Codex unavailable",
                .failed => "Codex connection failed",
                .disabled => "Codex disabled",
            },
            .claude_subscription => switch (model.claude_connection) {
                .connected => "Claude connected",
                .checking => "Checking Claude…",
                .connecting => "Connecting Claude…",
                .disconnected => "Claude not connected",
                .unavailable => "Claude unavailable",
                .failed => "Claude connection failed",
                .disabled => "Claude disabled",
            },
            else => if (model.api_key_len > 0) "OpenRouter connected" else "OpenRouter not connected",
        };
    }

    pub fn hasThreadCost(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return false;
        const pending_cost = if (thread.sending) thread.request_cost_micros else 0;
        return thread.total_cost_micros +| pending_cost > 0;
    }

    pub fn threadCostLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const thread = model.activeThreadConst() orelse return "";
        const pending_cost = if (thread.sending) thread.request_cost_micros else 0;
        const cost_micros = thread.total_cost_micros +| pending_cost;
        if (cost_micros == 0) return "";
        const cost = @as(f64, @floatFromInt(cost_micros)) / 1_000_000.0;
        return if (cost_micros < 10_000)
            std.fmt.allocPrint(arena, "Thread · ${d:.6}", .{cost}) catch "Thread cost"
        else
            std.fmt.allocPrint(arena, "Thread · ${d:.4}", .{cost}) catch "Thread cost";
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

    fn setModelCatalogStatus(model: *Model, value: []const u8) void {
        const len = utf8PrefixLen(value, model.model_catalog_status_storage.len);
        @memcpy(model.model_catalog_status_storage[0..len], value[0..len]);
        model.model_catalog_status_len = len;
    }

    fn selectCatalogModel(model: *Model, index: u32) void {
        if (index >= model.model_catalog_count) return;
        if (model.blockModelChangeWhileSending()) return;
        const entry = &model.model_catalog[index];
        const thread = model.activeThread() orelse return;
        thread.model_choice = .custom;
        thread.model_buffer.set(entry.slug());
        model.model_picker_open = false;
        model.markThreadDirty(thread.id);
    }

    fn selectQuickModel(model: *Model, number: u8) void {
        if (number == 0 or number > quickModels.len) return;
        if (model.blockModelChangeWhileSending()) return;
        const option = quickModels[number - 1];
        const thread = model.activeThread() orelse return;
        thread.model_choice = .custom;
        thread.model_buffer.set(option.slug);
        model.model_picker_open = false;
        model.markThreadDirty(thread.id);
    }

    fn openMoveThread(model: *Model) void {
        model.model_picker_open = false;
        model.settings_open = false;
        model.move_thread_id = model.active_thread_id;
        model.move_open = model.move_thread_id != 0;
        model.model_picker_open = model.move_open;
    }

    fn moveThread(model: *Model, project_id: u32) bool {
        const project = model.projectByIdConst(project_id) orelse return false;
        if (project.isArchived()) return false;
        const thread = model.threadById(model.move_thread_id) orelse return false;
        if (thread.project_id == project_id) {
            model.move_open = false;
            model.model_picker_open = false;
            model.move_thread_id = 0;
            return false;
        }
        thread.project_id = project_id;
        model.active_project_id = project_id;
        model.active_thread_id = thread.id;
        model.move_open = false;
        model.model_picker_open = false;
        model.move_thread_id = 0;
        model.markStructureDirty();
        return true;
    }

    fn mcpServerById(model: *Model, id: u32) ?*mcp.Server {
        for (model.mcp_servers[0..model.mcp_server_count]) |*server| if (server.id == id) return server;
        return null;
    }

    fn mcpServerByIdConst(model: *const Model, id: u32) ?*const mcp.Server {
        for (model.mcp_servers[0..model.mcp_server_count]) |*server| if (server.id == id) return server;
        return null;
    }

    fn removeMcpToolsForServer(model: *Model, server_id: u32) void {
        var write_index: usize = 0;
        for (model.mcp_tools[0..model.mcp_tool_count]) |tool| {
            if (tool.server_id == server_id) continue;
            model.mcp_tools[write_index] = tool;
            write_index += 1;
        }
        model.mcp_tool_count = write_index;
        model.mcp_selected_tool = std.math.maxInt(usize);
    }

    fn addMcpServer(model: *Model) ?u32 {
        if (model.cannotAddMcpServer()) return null;
        const raw_name = std.mem.trim(u8, model.mcp_server_name_buffer.text(), " \t\r\n");
        const raw_command = std.mem.trim(u8, model.mcp_server_command_buffer.text(), " \t\r\n");
        for (model.mcp_servers[0..model.mcp_server_count]) |server| {
            if (std.ascii.eqlIgnoreCase(server.name(), raw_name)) return null;
        }
        var server = mcp.Server{ .id = model.next_mcp_server_id };
        model.next_mcp_server_id +|= 1;
        server.setName(raw_name);
        server.setCommand(raw_command);
        server.setStatus("Ready to discover tools");
        model.mcp_servers[model.mcp_server_count] = server;
        model.mcp_server_count += 1;
        model.mcp_server_name_buffer.clear();
        model.mcp_server_command_buffer.clear();
        model.mcp_servers_dirty = true;
        return server.id;
    }

    fn removeMcpServer(model: *Model, id: u32) bool {
        for (model.mcp_servers[0..model.mcp_server_count], 0..) |server, index| {
            if (server.id != id or (model.mcp_operation != .none and model.mcp_operation_server_id == id)) continue;
            model.removeMcpToolsForServer(id);
            std.mem.copyForwards(mcp.Server, model.mcp_servers[index .. model.mcp_server_count - 1], model.mcp_servers[index + 1 .. model.mcp_server_count]);
            model.mcp_server_count -= 1;
            model.mcp_servers_dirty = true;
            return true;
        }
        return false;
    }

    fn toggleMcpServer(model: *Model, id: u32) bool {
        const server = model.mcpServerById(id) orelse return false;
        if (model.mcp_operation != .none and model.mcp_operation_server_id == id) return false;
        server.enabled = !server.enabled;
        if (!server.enabled) {
            server.state = .idle;
            server.setStatus("Disabled");
        }
        model.mcp_servers_dirty = true;
        return true;
    }

    pub fn setExecutablePath(model: *Model, path: []const u8) void {
        model.executable_path_len = utf8PrefixLen(path, model.executable_path_storage.len);
        @memcpy(model.executable_path_storage[0..model.executable_path_len], path[0..model.executable_path_len]);
    }

    fn executablePath(model: *const Model) []const u8 {
        return model.executable_path_storage[0..model.executable_path_len];
    }

    fn snippetById(model: *Model, id: u32) ?*PromptSnippet {
        for (model.snippets[0..model.snippet_count]) |*snippet| if (snippet.id == id) return snippet;
        return null;
    }

    fn saveSnippet(model: *Model) bool {
        const raw_name = std.mem.trim(u8, model.snippet_name_buffer.text(), " /\t\r\n");
        const raw_body = std.mem.trim(u8, model.snippet_body_buffer.text(), " \t\r\n");
        if (raw_name.len == 0 or raw_body.len == 0) return false;
        var target: ?*PromptSnippet = null;
        for (model.snippets[0..model.snippet_count]) |*snippet| {
            if (std.ascii.eqlIgnoreCase(snippet.name(), raw_name)) target = snippet;
        }
        if (target == null) {
            if (model.snippet_count == model.snippets.len) return false;
            model.snippets[model.snippet_count] = .{ .id = model.next_snippet_id };
            model.next_snippet_id += 1;
            target = &model.snippets[model.snippet_count];
            model.snippet_count += 1;
        }
        const snippet = target.?;
        snippet.name_len = utf8PrefixLen(raw_name, snippet.name_storage.len);
        @memcpy(snippet.name_storage[0..snippet.name_len], raw_name[0..snippet.name_len]);
        snippet.body_len = utf8PrefixLen(raw_body, snippet.body_storage.len);
        @memcpy(snippet.body_storage[0..snippet.body_len], raw_body[0..snippet.body_len]);
        model.snippet_name_buffer.clear();
        model.snippet_body_buffer.clear();
        model.snippets_dirty = true;
        return true;
    }

    fn deleteSnippet(model: *Model, id: u32) bool {
        for (model.snippets[0..model.snippet_count], 0..) |snippet, index| {
            if (snippet.id != id) continue;
            std.mem.copyForwards(PromptSnippet, model.snippets[index .. model.snippet_count - 1], model.snippets[index + 1 .. model.snippet_count]);
            model.snippet_count -= 1;
            model.snippets_dirty = true;
            return true;
        }
        return false;
    }

    fn insertSnippet(model: *Model, id: u32) bool {
        const snippet = model.snippetById(id) orelse return false;
        const thread = model.activeThread() orelse return false;
        thread.draft_buffer.set(snippet.body());
        model.model_picker_open = false;
        model.settings_open = false;
        model.focusComposer();
        model.markThreadDirty(thread.id);
        return true;
    }

    fn expandSnippetDraft(model: *Model, thread: *Thread) void {
        const draft_text = std.mem.trim(u8, thread.draft(), " \t\r\n");
        if (draft_text.len < 2 or draft_text[0] != '/') return;
        const command = draft_text[1..];
        for (model.snippets[0..model.snippet_count]) |*snippet| {
            if (!std.ascii.eqlIgnoreCase(snippet.name(), command)) continue;
            thread.draft_buffer.set(snippet.body());
            return;
        }
    }

    pub fn activeModelChoice(model: *const Model) ModelChoice {
        const thread = model.activeThreadConst() orelse return .auto;
        return thread.model_choice;
    }

    pub fn ensureDefaultSnippets(model: *Model) void {
        if (model.snippet_count > 0) return;
        const defaults = [_]struct { name: []const u8, body: []const u8 }{
            .{ .name = "summarize", .body = "Summarize this clearly. Lead with the key conclusion, then list the most important supporting points." },
            .{ .name = "rewrite", .body = "Rewrite the following so it is concise, natural, and easy to understand while preserving the original meaning:\n\n" },
            .{ .name = "review", .body = "Review the following critically. Identify the highest-impact problems first, explain why they matter, and recommend concrete improvements:\n\n" },
        };
        for (defaults) |item| {
            var snippet = PromptSnippet{ .id = model.next_snippet_id };
            model.next_snippet_id += 1;
            snippet.name_len = utf8PrefixLen(item.name, snippet.name_storage.len);
            @memcpy(snippet.name_storage[0..snippet.name_len], item.name[0..snippet.name_len]);
            snippet.body_len = utf8PrefixLen(item.body, snippet.body_storage.len);
            @memcpy(snippet.body_storage[0..snippet.body_len], item.body[0..snippet.body_len]);
            model.snippets[model.snippet_count] = snippet;
            model.snippet_count += 1;
        }
        model.snippets_dirty = true;
    }

    pub fn forkSeed(model: *const Model) []const u8 {
        return model.fork_seed_buffer.text();
    }

    pub fn forkModelRows(model: *const Model, arena: std.mem.Allocator) []const ForkModelRow {
        const source = model.threadByIdConst(model.fork_source_thread_id);
        const include_custom = source != null and source.?.model_choice == .custom;
        const capacity = modelOptions.len - @intFromBool(!include_custom) - @intFromBool(!model.dev_mode);
        const rows = arena.alloc(ForkModelRow, capacity) catch return &.{};
        var count: usize = 0;
        for (modelOptions) |option| {
            if (option.choice == .custom and !include_custom) continue;
            if (option.choice == .claude_subscription and !model.dev_mode) continue;
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

    fn codexConnectionStatus(model: *const Model) []const u8 {
        return switch (model.codex_connection) {
            .disabled => "Codex connection disabled",
            .checking => "Checking Codex sign-in…",
            .connected => "Connected through your ChatGPT account",
            .disconnected => "Not signed in to Codex",
            .connecting => "Waiting for Codex browser sign-in…",
            .unavailable => "Codex CLI not found; install Codex or the ChatGPT app",
            .failed => "Could not check the Codex connection",
        };
    }

    fn claudeConnectionStatus(model: *const Model) []const u8 {
        return switch (model.claude_connection) {
            .disabled => "Experimental local adapter; disabled in public builds",
            .checking => "Checking Claude sign-in…",
            .connected => "Connected through your Claude Pro/Max plan",
            .disconnected => "Not signed in to Claude",
            .connecting => "Waiting for Claude browser sign-in…",
            .unavailable => "Claude CLI not found; install it, then retry",
            .failed => "Could not check the Claude connection",
        };
    }

    pub fn codexConnectionButtonText(model: *const Model) []const u8 {
        return switch (model.codex_connection) {
            .disabled => unreachable,
            .checking => "Codex · Checking sign-in…",
            .connected => "Codex · Connected · Use",
            .disconnected => "Codex · Connect ChatGPT",
            .connecting => "Codex · Waiting for browser sign-in…",
            .unavailable => "Codex CLI not installed",
            .failed => "Codex · Retry connection",
        };
    }

    pub fn claudeConnectionButtonText(model: *const Model) []const u8 {
        return switch (model.claude_connection) {
            .disabled => "Claude · Experimental · Development builds only",
            .checking => "Claude · Checking sign-in…",
            .connected => "Claude · Connected · Use",
            .disconnected => "Claude · Connect Pro/Max",
            .connecting => "Claude · Waiting for browser sign-in…",
            .unavailable => "Claude CLI not installed",
            .failed => "Claude · Retry connection",
        };
    }

    pub fn cannotSaveSettings(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return true;
        return thread.model_buffer.isEmpty() or model.key_validation_pending;
    }

    pub fn claudeSubscriptionDisabled(model: *const Model) bool {
        return !model.dev_mode or model.claude_connection == .checking or model.claude_connection == .connecting;
    }

    pub fn codexConnectionBusy(model: *const Model) bool {
        return model.codex_connection == .checking or model.codex_connection == .connecting;
    }

    pub fn messageRows(model: *const Model) []const Message {
        const thread = model.activeThreadConst() orelse return &.{};
        return thread.messages[0..thread.message_count];
    }

    pub fn canLoadOlder(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return false;
        return thread.has_older_messages and !thread.history_loading and thread.message_count > 0;
    }

    pub fn hasMessages(model: *const Model) bool {
        return model.messageRows().len > 0;
    }

    pub fn cannotClear(model: *const Model) bool {
        return !model.hasMessages();
    }

    pub fn canSend(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return false;
        const has_connection = switch (thread.model_choice) {
            .codex_subscription => model.codex_connection == .connected,
            .claude_subscription => model.dev_mode and model.claude_connection == .connected,
            else => model.api_key_len > 0,
        };
        for (thread.draft_attachments[0..thread.draft_attachment_count]) |attachment| if (attachment.bytes.len == 0) return false;
        return !thread.sending and has_connection and (!thread.draft_buffer.isEmpty() or thread.draft_attachment_count > 0) and !thread.model_buffer.isEmpty() and !model.attachmentLoading();
    }

    pub fn cannotSend(model: *const Model) bool {
        return !model.canSend();
    }

    pub fn missingKey(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return model.api_key_len == 0;
        return switch (thread.model_choice) {
            .codex_subscription, .claude_subscription => false,
            else => model.api_key_len == 0,
        };
    }

    pub fn sending(model: *const Model) bool {
        const thread = model.activeThreadConst() orelse return false;
        return thread.sending;
    }

    pub fn cannotStop(model: *const Model) bool {
        return !model.sending();
    }

    pub fn statusLine(model: *const Model) []const u8 {
        const thread = model.activeThreadConst();
        if (thread) |active| {
            if (active.status_len > 0) return active.status_storage[0..active.status_len];
            for (active.draft_attachments[0..active.draft_attachment_count]) |attachment| {
                if (attachment.bytes.len == 0) return "Remove and reattach saved draft files before sending";
            }
        }
        if (thread) |active| {
            switch (active.model_choice) {
                .codex_subscription => return if (model.codex_connection == .connected) "" else model.codexConnectionStatus(),
                .claude_subscription => return if (model.claude_connection == .connected) "" else model.claudeConnectionStatus(),
                else => {},
            }
        }
        if (model.api_key_len == 0) return "Add an OpenRouter API key in Settings";
        return "";
    }

    pub fn statusVisible(model: *const Model) bool {
        return model.statusLine().len > 0;
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
        if (model.blockModelChangeWhileSending()) return;
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

    fn blockModelChangeWhileSending(model: *Model) bool {
        const thread = model.activeThread() orelse return false;
        if (!thread.sending) return false;
        thread.setStatus("Wait for the current response before changing models");
        model.model_picker_open = false;
        return true;
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

    fn ensureChatsProject(model: *Model) bool {
        if (model.projectByIdConst(chats_project_id) != null) return true;
        if (!model.ensureProjectCapacity(model.project_count + 1)) return false;
        var project = Project{ .id = chats_project_id };
        setProjectName(&project, chats_project_name);
        model.projects[model.project_count] = project;
        model.project_count += 1;
        return true;
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
            if (model.active_project_id == chats_project_id) return;
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
        model.clear_confirm_thread_id = 0;
        model.rename_open = true;
    }

    fn saveRename(model: *Model) void {
        const value = std.mem.trim(u8, model.rename_buffer.text(), " \t\r\n");
        if (value.len == 0) return;
        if (model.rename_kind == .project) {
            if (model.rename_id == chats_project_id) return;
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

    fn deleteThread(model: *Model, thread_id: u32, fx: *Effects) bool {
        for (model.threads[0..model.thread_count], 0..) |thread, index| {
            if (thread.id != thread_id or !thread.isArchived()) continue;
            model.removeThreadAt(index, fx);
            return true;
        }
        return false;
    }

    fn deleteProject(model: *Model, project_id: u32, fx: *Effects) bool {
        if (project_id == chats_project_id) return false;
        const project = model.projectByIdConst(project_id) orelse return false;
        if (!project.isArchived()) return false;
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
            return true;
        }
        return false;
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

    fn stripLegacyForkModelSuffix(thread: *Thread) bool {
        const model_label = if (thread.model_choice == .custom) thread.modelName() else blk: {
            for (modelOptions) |option| {
                if (option.choice == thread.model_choice) break :blk option.label;
            }
            break :blk "";
        };
        if (model_label.len == 0 or !std.mem.endsWith(u8, thread.title(), model_label)) return false;
        const delimiter = " · ";
        if (thread.title_len <= model_label.len + delimiter.len) return false;
        const delimiter_start = thread.title_len - model_label.len - delimiter.len;
        if (!std.mem.eql(u8, thread.title()[delimiter_start .. delimiter_start + delimiter.len], delimiter)) return false;
        thread.title_len = delimiter_start;
        return true;
    }

    fn normalizeLoadedWorkspace(model: *Model) bool {
        if (!model.ensureChatsProject()) return false;
        var max_project_id: u32 = 0;
        var max_thread_id: u32 = 0;
        var max_message_id: u32 = 0;
        for (model.projects[0..model.project_count]) |project| max_project_id = @max(max_project_id, project.id);
        for (model.threads[0..model.thread_count]) |*thread| {
            if (stripLegacyForkModelSuffix(thread)) model.persistence_structure_dirty = true;
            max_thread_id = @max(max_thread_id, thread.id);
            for (thread.messages[0..thread.message_count]) |message| max_message_id = @max(max_message_id, message.id);
        }
        model.next_project_id = @max(model.next_project_id, max_project_id +| 1);
        model.next_thread_id = @max(model.next_thread_id, max_thread_id +| 1);
        model.next_message_id = @max(model.next_message_id, max_message_id +| 1);

        if (model.activeThreadConst()) |thread| {
            const project = model.projectByIdConst(thread.project_id);
            if (!thread.isArchived() and project != null and !project.?.isArchived()) {
                model.active_project_id = thread.project_id;
                return true;
            }
        }
        if (model.activateFirstVisible()) return true;
        const thread_id = model.addThread(chats_project_id) orelse return false;
        return model.activateThread(thread_id);
    }

    fn archiveThread(model: *Model, fx: *Effects) bool {
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
            return false;
        };
        const thread = model.threadById(active_id) orelse return false;
        if (thread.sending) fx.cancel(requestKey(thread.id));
        thread.sending = false;
        thread.archived_at_ms = @max(model.clock.wallMs(), 1);
        _ = model.activateThread(replacement_id);
        return true;
    }

    fn archiveProject(model: *Model, fx: *Effects) bool {
        const active_id = model.active_project_id;
        if (active_id == chats_project_id) return false;
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
                return false;
            };
            replacement_thread_id = model.addThread(new_project_id) orelse return false;
        }
        for (model.threads[0..model.thread_count]) |*thread| {
            if (thread.project_id != active_id or !thread.sending) continue;
            fx.cancel(requestKey(thread.id));
            thread.sending = false;
        }
        const project = model.projectById(active_id) orelse return false;
        project.archived_at_ms = @max(model.clock.wallMs(), 1);
        _ = model.activateThread(replacement_thread_id);
        return true;
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
        if (project_id == chats_project_id) return;
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
                _ = model.deleteProject(project.id, fx);
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
        model.clear_confirm_thread_id = 0;
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
        thread.unread = false;
        return true;
    }

    fn activateFirstThreadInProject(model: *Model, project_id: u32) bool {
        for (model.threads[0..model.thread_count]) |thread| {
            if (thread.project_id == project_id and !thread.isArchived()) return model.activateThread(thread.id);
        }
        return false;
    }

    fn activateProjectSlot(model: *Model, slot: u8) bool {
        if (slot == 0) return false;
        var visible_slot: u8 = 0;
        for (model.projects[0..model.project_count]) |project| {
            if (project.id == chats_project_id or project.isArchived()) continue;
            visible_slot += 1;
            if (visible_slot == slot) return model.activateFirstThreadInProject(project.id);
        }
        return false;
    }

    fn activateThreadSlot(model: *Model, slot: u8) bool {
        if (slot == 0) return false;
        var visible_slot: u8 = 0;
        for (model.threads[0..model.thread_count]) |thread| {
            if (thread.project_id != model.active_project_id or thread.isArchived()) continue;
            visible_slot += 1;
            if (visible_slot == slot) return model.activateThread(thread.id);
        }
        return false;
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

    fn buildAttachmentRequest(model: *Model, thread: *const Thread) ?[]u8 {
        var output: std.Io.Writer.Allocating = .init(model.allocator);
        defer output.deinit();
        const writer = &output.writer;
        writer.writeAll("{\"model\":") catch return null;
        std.json.Stringify.value(std.mem.trim(u8, thread.modelName(), " \t"), .{}, writer) catch return null;
        writer.writeAll(",\"messages\":[") catch return null;
        const first = thread.message_count -| provider_context_messages;
        for (thread.messages[first..thread.message_count], 0..) |*message, message_index| {
            if (message_index > 0) writer.writeByte(',') catch return null;
            writer.writeAll("{\"role\":") catch return null;
            std.json.Stringify.value(if (message.role == .user) "user" else "assistant", .{}, writer) catch return null;
            writer.writeAll(",\"content\":") catch return null;
            if (message.attachment_count == 0) {
                std.json.Stringify.value(message.content(), .{}, writer) catch return null;
            } else {
                writer.writeAll("[{\"type\":\"text\",\"text\":") catch return null;
                std.json.Stringify.value(message.content(), .{}, writer) catch return null;
                writer.writeByte('}') catch return null;
                for (message.attachments[0..message.attachment_count]) |*attachment| {
                    if (attachment.bytes.len == 0) {
                        writer.writeAll(",{\"type\":\"text\",\"text\":") catch return null;
                        const note = std.fmt.allocPrint(model.allocator, "Previously attached file: {s}", .{attachment.name()}) catch return null;
                        defer model.allocator.free(note);
                        std.json.Stringify.value(note, .{}, writer) catch return null;
                        writer.writeByte('}') catch return null;
                        continue;
                    }
                    switch (attachment.kind) {
                        .text => {
                            if (!std.unicode.utf8ValidateSlice(attachment.bytes)) return null;
                            writer.writeAll(",{\"type\":\"text\",\"text\":") catch return null;
                            const prefix = std.fmt.allocPrint(model.allocator, "Attached file {s}:\n", .{attachment.name()}) catch return null;
                            defer model.allocator.free(prefix);
                            var combined: std.Io.Writer.Allocating = .init(model.allocator);
                            defer combined.deinit();
                            combined.writer.writeAll(prefix) catch return null;
                            combined.writer.writeAll(attachment.bytes) catch return null;
                            std.json.Stringify.value(combined.written(), .{}, writer) catch return null;
                            writer.writeByte('}') catch return null;
                        },
                        .image => {
                            writer.writeAll(",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:") catch return null;
                            writer.writeAll(imageMimeType(attachment.path())) catch return null;
                            writer.writeAll(";base64,") catch return null;
                            std.base64.standard.Encoder.encodeWriter(writer, attachment.bytes) catch return null;
                            writer.writeAll("\"}}") catch return null;
                        },
                        .pdf => {
                            writer.writeAll(",{\"type\":\"file\",\"file\":{\"filename\":") catch return null;
                            std.json.Stringify.value(attachment.name(), .{}, writer) catch return null;
                            writer.writeAll(",\"file_data\":\"data:application/pdf;base64,") catch return null;
                            std.base64.standard.Encoder.encodeWriter(writer, attachment.bytes) catch return null;
                            writer.writeAll("\"}}") catch return null;
                        },
                    }
                }
                writer.writeByte(']') catch return null;
            }
            writer.writeByte('}') catch return null;
        }
        writer.writeAll("],\"stream\":true}") catch return null;
        if (output.written().len > native_sdk.max_effect_file_bytes) return null;
        return output.toOwnedSlice() catch null;
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

pub fn normalizeLoadedWorkspace(model: *Model) bool {
    return model.normalizeLoadedWorkspace();
}

pub const ChatApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = builtin.mode == .Debug });
pub const Effects = ChatApp.Effects;

const codex_runner_script = "if [ -x /Applications/ChatGPT.app/Contents/Resources/codex ]; then exec /Applications/ChatGPT.app/Contents/Resources/codex \"$@\"; elif [ -x \"$HOME/.local/bin/codex\" ]; then exec \"$HOME/.local/bin/codex\" \"$@\"; else exec codex \"$@\"; fi";
const claude_runner_script = "if [ -x \"$HOME/.local/bin/claude\" ]; then exec \"$HOME/.local/bin/claude\" \"$@\"; else exec claude \"$@\"; fi";
const claude_chat_script = "if [ -x \"$HOME/.local/bin/claude\" ]; then CLAUDE=\"$HOME/.local/bin/claude\"; else CLAUDE=claude; fi; exec \"$CLAUDE\" -p --output-format stream-json --verbose --include-partial-messages --no-session-persistence --safe-mode --tools \"\" --max-turns 1 --model sonnet";
const openrouter_curl_script = "path=\"$1\"; trap 'rm -f -- \"$path\"' EXIT; /bin/chmod 600 \"$path\"; /usr/bin/curl --silent --show-error --no-buffer --fail-with-body --config - -H 'Content-Type: application/json' -H 'X-OpenRouter-Title: Superchat' --data-binary \"@$path\" https://openrouter.ai/api/v1/chat/completions";

fn checkConnections(model: *Model, fx: *Effects) void {
    model.codex_connection = .checking;
    fx.spawn(.{
        .key = codex_status_key,
        .argv = &.{ "/bin/zsh", "-lc", codex_runner_script, "superchat", "login", "status" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.connection_exit),
    });
    if (model.dev_mode) {
        model.claude_connection = .checking;
        fx.spawn(.{
            .key = claude_status_key,
            .argv = &.{ "/bin/zsh", "-lc", claude_runner_script, "superchat", "auth", "status" },
            .output = .collect,
            .on_exit = Effects.exitMsg(.connection_exit),
        });
    } else {
        model.claude_connection = .disabled;
    }
}

pub fn initEffects(model: *Model, fx: *Effects) void {
    checkConnections(model, fx);
    checkUpdates(model, fx);
    for (model.mcp_servers[0..model.mcp_server_count]) |server| {
        if (server.enabled and server.state == .idle) {
            _ = startMcpHelper(model, server.id, null, fx);
            break;
        }
    }
}

fn setUpdateStatus(model: *Model, value: []const u8) void {
    const len = utf8PrefixLen(value, model.update_status_storage.len);
    @memcpy(model.update_status_storage[0..len], value[0..len]);
    model.update_status_len = len;
}

fn isNewerVersion(latest: []const u8, current: []const u8) ?bool {
    const normalized = if (latest.len > 0 and (latest[0] == 'v' or latest[0] == 'V')) latest[1..] else latest;
    const latest_version = std.SemanticVersion.parse(normalized) catch return null;
    const current_version = std.SemanticVersion.parse(current) catch return null;
    return latest_version.order(current_version) == .gt;
}

fn checkUpdates(model: *Model, fx: *Effects) void {
    if (model.update_state == .checking) return;
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "User-Agent", .value = "Superchat" },
    };
    fx.fetch(.{
        .key = updates_request,
        .method = .GET,
        .url = updates_url,
        .headers = &headers,
        .timeout_ms = 12_000,
        .on_response = Effects.responseMsg(.response),
    });
    model.update_state = .checking;
    setUpdateStatus(model, "Checking for updates…");
}

fn receiveUpdateCheck(model: *Model, response: native_sdk.EffectResponse) void {
    if (response.outcome != .ok or response.status < 200 or response.status >= 300 or response.truncated) {
        model.update_state = .failed;
        setUpdateStatus(model, "Could not check GitHub Releases right now");
        return;
    }
    var parsed = std.json.parseFromSlice(UpdateRelease, model.allocator, response.body, .{ .ignore_unknown_fields = true }) catch {
        model.update_state = .failed;
        setUpdateStatus(model, "GitHub returned an unreadable release");
        return;
    };
    defer parsed.deinit();
    if (parsed.value.tag_name.len == 0) {
        model.update_state = .failed;
        setUpdateStatus(model, "No published release found");
        return;
    }
    const newer = isNewerVersion(parsed.value.tag_name, superchat_options.version) orelse {
        model.update_state = .failed;
        setUpdateStatus(model, "The latest GitHub tag is not a semantic version");
        return;
    };
    model.update_state = if (newer) .available else .current;
    if (model.update_state == .current) {
        setUpdateStatus(model, "Superchat is up to date · " ++ superchat_options.version);
        return;
    }
    const safe_url = if (std.mem.startsWith(u8, parsed.value.html_url, releases_url_prefix)) parsed.value.html_url else releases_url_prefix ++ "latest";
    model.update_url_len = utf8PrefixLen(safe_url, model.update_url_storage.len);
    @memcpy(model.update_url_storage[0..model.update_url_len], safe_url[0..model.update_url_len]);
    var buffer: [120]u8 = undefined;
    const status = std.fmt.bufPrint(&buffer, "Update {s} is available", .{parsed.value.tag_name}) catch "A Superchat update is available";
    setUpdateStatus(model, status);
}

fn connectCodex(model: *Model, fx: *Effects) void {
    if (model.codex_connection == .checking or model.codex_connection == .connecting) return;
    if (model.codex_connection == .connected) {
        model.selectModel(.codex_subscription);
        if (model.activeThreadConst()) |thread| model.markThreadDirty(thread.id);
        if (model.onboarding_open) {
            model.onboarding_open = false;
            model.credential_action = .complete_onboarding;
        }
        return;
    }
    model.codex_login_thread_id = model.active_thread_id;
    model.codex_connection = .connecting;
    fx.spawn(.{
        .key = codex_login_key,
        .argv = &.{ "/bin/zsh", "-lc", codex_runner_script, "superchat", "login" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.connection_exit),
    });
}

fn connectClaude(model: *Model, fx: *Effects) void {
    if (!model.dev_mode) {
        model.setStatus("The experimental Claude connection is disabled in public builds");
        return;
    }
    if (model.claude_connection == .checking or model.claude_connection == .connecting) return;
    if (model.claude_connection == .connected) {
        model.selectModel(.claude_subscription);
        if (model.activeThreadConst()) |thread| model.markThreadDirty(thread.id);
        if (model.onboarding_open) {
            model.onboarding_open = false;
            model.credential_action = .complete_onboarding;
        }
        return;
    }
    model.claude_login_thread_id = model.active_thread_id;
    model.claude_connection = .connecting;
    fx.spawn(.{
        .key = claude_login_key,
        .argv = &.{ "/bin/zsh", "-lc", claude_runner_script, "superchat", "auth", "login" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.connection_exit),
    });
}

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
    model.ensureDefaultSnippets();
    model.setApiKey(api_key);
    std.debug.assert(model.ensureChatsProject());
    model.active_project_id = chats_project_id;
    model.active_thread_id = model.addThread(chats_project_id).?;
    return model;
}

pub fn shouldShowOnboarding(dev_mode: bool, force_onboarding: bool, has_api_key: bool, onboarding_complete: bool) bool {
    if (force_onboarding) return true;
    return !dev_mode and !has_api_key and !onboarding_complete;
}

pub fn usesPersistentCredentialStore(dev_mode: bool) bool {
    return superchat_options.credential_store and !dev_mode;
}

pub fn onCommand(name: []const u8) ?Msg {
    for (project_slot_commands, 1..) |command, number| {
        if (std.mem.eql(u8, name, command)) return .{ .select_project_slot = @intCast(number) };
    }
    for (thread_slot_commands, 1..) |command, number| {
        if (std.mem.eql(u8, name, command)) return .{ .select_thread_slot = @intCast(number) };
    }
    for (quick_model_commands, 1..) |command, number| {
        if (std.mem.eql(u8, name, command)) return .{ .select_quick_model = @intCast(number) };
    }
    if (std.mem.eql(u8, name, cmd_new_thread)) return .new_thread;
    if (std.mem.eql(u8, name, cmd_new_project_thread)) return .new_project_thread;
    if (std.mem.eql(u8, name, cmd_new_project)) return .new_project;
    if (std.mem.eql(u8, name, cmd_previous_thread)) return .previous_thread;
    if (std.mem.eql(u8, name, cmd_next_thread)) return .next_thread;
    if (std.mem.eql(u8, name, cmd_previous_project)) return .previous_project;
    if (std.mem.eql(u8, name, cmd_next_project)) return .next_project;
    if (std.mem.eql(u8, name, cmd_focus_composer)) return .focus_composer;
    if (std.mem.eql(u8, name, cmd_attach_files)) return .open_file_picker;
    if (std.mem.eql(u8, name, cmd_model_picker)) return .open_model_picker;
    if (std.mem.eql(u8, name, cmd_search)) return .open_search;
    if (std.mem.eql(u8, name, cmd_retry_latest)) return .retry_latest;
    if (std.mem.eql(u8, name, cmd_stop)) return .stop;
    if (std.mem.eql(u8, name, cmd_auto_model)) return .select_auto_model;
    if (std.mem.eql(u8, name, cmd_codex_subscription)) return .{ .select_model = .codex_subscription };
    if (std.mem.eql(u8, name, cmd_top_level_chats)) return .select_top_level_chats;
    if (std.mem.eql(u8, name, cmd_load_older)) return .load_older;
    if (std.mem.eql(u8, name, cmd_move_thread)) return .open_move_thread;
    if (std.mem.eql(u8, name, cmd_export_thread)) return .export_thread;
    if (std.mem.eql(u8, name, cmd_export_workspace)) return .export_workspace;
    if (std.mem.eql(u8, name, cmd_snippets)) return .open_snippets;
    if (std.mem.eql(u8, name, cmd_mcp_tools)) return .open_mcp_tools;
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

fn attachmentKindForPath(path: []const u8) ?AttachmentKind {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png") or
        std.ascii.eqlIgnoreCase(extension, ".jpg") or
        std.ascii.eqlIgnoreCase(extension, ".jpeg") or
        std.ascii.eqlIgnoreCase(extension, ".webp") or
        std.ascii.eqlIgnoreCase(extension, ".gif")) return .image;
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) return .pdf;
    const text_extensions = [_][]const u8{
        ".txt",  ".md",   ".markdown", ".json", ".jsonl", ".csv", ".tsv",   ".xml", ".yaml", ".yml",
        ".html", ".css",  ".js",       ".jsx",  ".ts",    ".tsx", ".zig",   ".py",  ".rb",   ".go",
        ".rs",   ".java", ".c",        ".h",    ".cpp",   ".hpp", ".swift", ".kt",  ".kts",  ".sh",
        ".zsh",  ".sql",  ".toml",     ".ini",  ".log",   ".rtf",
    };
    for (text_extensions) |candidate| if (std.ascii.eqlIgnoreCase(extension, candidate)) return .text;
    return null;
}

fn imageMimeType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    return "image/jpeg";
}

fn threadAttachmentBytes(thread: *const Thread) usize {
    var total: usize = 0;
    for (thread.draft_attachments[0..thread.draft_attachment_count]) |attachment| total += attachment.bytes.len;
    return total;
}

fn queueAttachmentRead(model: *Model, thread: *Thread, path: []const u8, fx: *Effects) void {
    if (path.len == 0 or path.len > max_attachment_path_bytes) {
        thread.setStatus("That file path is too long to attach");
        return;
    }
    const kind = attachmentKindForPath(path) orelse {
        thread.setStatus("Attach PNG, JPEG, WebP, GIF, PDF, or a plain-text/code file");
        return;
    };
    var reserved = thread.draft_attachment_count;
    for (model.pending_attachments[0..model.pending_attachment_count]) |pending| {
        if (pending.thread_id == thread.id) reserved += 1;
    }
    if (reserved >= max_attachments_per_message or model.pending_attachment_count == model.pending_attachments.len) {
        thread.setStatus("A message can include up to four attachments");
        return;
    }
    for (thread.draft_attachments[0..thread.draft_attachment_count]) |*attachment| {
        if (std.mem.eql(u8, attachment.path(), path)) return;
    }
    for (model.pending_attachments[0..model.pending_attachment_count]) |*pending| {
        if (pending.thread_id == thread.id and std.mem.eql(u8, pending.path(), path)) return;
    }
    const key = model.next_attachment_read_key;
    model.next_attachment_read_key +%= 1;
    if (model.next_attachment_read_key <= attachment_read_key_base) model.next_attachment_read_key = attachment_read_key_base + 1;
    var pending = PendingAttachment{ .key = key, .thread_id = thread.id, .kind = kind, .path_len = path.len };
    @memcpy(pending.path_storage[0..path.len], path);
    model.pending_attachments[model.pending_attachment_count] = pending;
    model.pending_attachment_count += 1;
    thread.setStatus("Reading attachment…");
    fx.readFile(.{ .key = key, .path = path, .on_result = Effects.fileMsg(.attachment_file_result) });
}

fn receiveAttachment(model: *Model, result: native_sdk.EffectFileResult, fx: *Effects) void {
    var pending_index: ?usize = null;
    for (model.pending_attachments[0..model.pending_attachment_count], 0..) |pending, index| {
        if (pending.key == result.key) pending_index = index;
    }
    const index = pending_index orelse return;
    const pending = model.pending_attachments[index];
    model.pending_attachment_count -= 1;
    if (index != model.pending_attachment_count) model.pending_attachments[index] = model.pending_attachments[model.pending_attachment_count];
    const thread = model.threadById(pending.thread_id) orelse return;
    if (result.outcome != .ok) {
        thread.setStatus(switch (result.outcome) {
            .truncated => "That file is over the 1 MB local attachment limit",
            .not_found => "That file is no longer available",
            .io_failed => "Superchat could not read that file",
            .rejected => "The attachment could not be queued",
            .cancelled => "Attachment cancelled",
            .ok => unreachable,
        });
        return;
    }
    if (result.bytes.len == 0) {
        thread.setStatus("Empty files cannot be attached");
        return;
    }
    if (pending.kind == .text and !std.unicode.utf8ValidateSlice(result.bytes)) {
        thread.setStatus("That file is not valid UTF-8 text");
        return;
    }
    if (thread.draft_attachment_count == max_attachments_per_message) return;
    if (threadAttachmentBytes(thread) + result.bytes.len > max_attachment_total_bytes) {
        thread.setStatus("Attachments in one message can total up to 640 KB");
        return;
    }
    const name = std.fs.path.basename(pending.path());
    var attachment = Attachment{ .kind = pending.kind, .path_len = pending.path_len, .name_len = utf8PrefixLen(name, max_attachment_name_bytes) };
    @memcpy(attachment.path_storage[0..pending.path_len], pending.path());
    @memcpy(attachment.name_storage[0..attachment.name_len], name[0..attachment.name_len]);
    attachment.bytes = model.allocator.dupe(u8, result.bytes) catch {
        thread.setStatus("Superchat ran out of memory while attaching that file");
        return;
    };
    thread.draft_attachments[thread.draft_attachment_count] = attachment;
    thread.draft_attachment_count += 1;
    thread.clearStatus();
    model.markThreadDirty(thread.id);
    model.showToast("Attachment added", fx);
}

fn closeSearch(model: *Model, fx: *Effects) void {
    model.search_open = false;
    model.model_picker_open = false;
    model.search_buffer.clear();
    model.search_generation +%= 1;
    model.search_result_count = 0;
    model.search_loading = false;
    model.search_request_pending = false;
    fx.cancelTimer(search_timer_key);
}

fn databaseReadPending(model: *const Model) bool {
    if (model.search_loading) return true;
    if (model.export_pending) return true;
    for (model.threads[0..model.thread_count]) |thread| if (thread.history_loading) return true;
    return false;
}

fn pollDatabaseReads(model: *const Model, fx: *Effects) void {
    if (!databaseReadPending(model)) return;
    fx.startTimer(.{ .key = database_poll_key, .interval_ms = 50, .on_fire = Effects.timerMsg(.database_poll) });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .draft_edit => |edit| {
            if (edit == .insert_text and std.mem.eql(u8, edit.insert_text, "\n")) {
                submitDraft(model, fx);
                return;
            }
            const thread = model.activeThread() orelse return;
            thread.draft_buffer.apply(edit);
            fx.startTimer(.{
                .key = draftSaveKey(thread.id),
                .interval_ms = draft_save_interval_ms,
                .on_fire = Effects.timerMsg(.persist_draft),
            });
        },
        .composer_newline => {
            const thread = model.activeThread() orelse return;
            thread.draft_buffer.apply(.{ .insert_text = "\n" });
            fx.startTimer(.{
                .key = draftSaveKey(thread.id),
                .interval_ms = draft_save_interval_ms,
                .on_fire = Effects.timerMsg(.persist_draft),
            });
        },
        .open_file_picker => model.file_picker_requested = true,
        .files_dropped => |drop| {
            const thread = model.activeThread() orelse return;
            for (drop.paths) |path| queueAttachmentRead(model, thread, path, fx);
        },
        .attachment_file_result => |result| receiveAttachment(model, result, fx),
        .request_body_written => |result| receiveRequestBodyWritten(model, result, fx),
        .remove_attachment => |attachment_index| {
            const thread = model.activeThread() orelse return;
            if (attachment_index >= thread.draft_attachment_count) return;
            thread.draft_attachments[attachment_index].deinit(model.allocator);
            const index: usize = attachment_index;
            if (index + 1 < thread.draft_attachment_count) {
                std.mem.copyForwards(Attachment, thread.draft_attachments[index .. thread.draft_attachment_count - 1], thread.draft_attachments[index + 1 .. thread.draft_attachment_count]);
            }
            thread.draft_attachment_count -= 1;
            thread.draft_attachments[thread.draft_attachment_count] = .{};
            model.markThreadDirty(thread.id);
            model.showToast("Attachment removed", fx);
        },
        .fork_seed_edit => |edit| model.fork_seed_buffer.apply(edit),
        .rename_edit => |edit| model.rename_buffer.apply(edit),
        .model_edit => |edit| {
            if (model.blockModelChangeWhileSending()) return;
            const thread = model.activeThread() orelse return;
            thread.model_buffer.apply(edit);
            thread.model_choice = .custom;
            model.markThreadDirty(thread.id);
        },
        .api_key_edit => |edit| model.api_key_buffer.apply(edit),
        .mcp_server_name_edit => |edit| model.mcp_server_name_buffer.apply(edit),
        .mcp_server_command_edit => |edit| model.mcp_server_command_buffer.apply(edit),
        .model_search_edit => |edit| {
            model.model_search_buffer.apply(edit);
            fx.startTimer(.{ .key = model_search_timer, .interval_ms = 250, .on_fire = Effects.timerMsg(.model_search) });
        },
        .model_search => searchModels(model, fx),
        .search_edit => |edit| {
            model.search_buffer.apply(edit);
            model.search_generation +%= 1;
            model.search_result_count = 0;
            model.search_loading = false;
            fx.startTimer(.{ .key = search_timer_key, .interval_ms = 180, .on_fire = Effects.timerMsg(.search_timer) });
        },
        .search_timer => |timer| {
            if (timer.key != search_timer_key) return;
            const query = std.mem.trim(u8, model.search_buffer.text(), " \t\r\n");
            if (query.len < 2) return;
            model.search_request_pending = true;
            model.search_loading = true;
            pollDatabaseReads(model, fx);
        },
        .database_poll => |timer| {
            if (timer.key != database_poll_key) return;
            pollDatabaseReads(model, fx);
        },
        .open_search => {
            model.model_picker_open = true;
            model.settings_open = false;
            model.fork_open = false;
            model.rename_open = false;
            model.archive_open = false;
            model.move_open = false;
            model.search_open = true;
        },
        .select_search_result => |index| {
            if (index >= model.search_result_count) return;
            const thread_id = model.search_results[index].thread_id;
            if (model.activateThread(thread_id)) {
                closeSearch(model, fx);
                model.markMetaDirty();
                model.showToast("Opened matching chat", fx);
            }
        },
        .select_palette_workspace => |key| {
            model.model_picker_open = false;
            if (key & (@as(u64, 1) << 32) != 0) {
                const thread_id: u32 = @intCast(key & 0xffff_ffff);
                if (model.activateThread(thread_id)) model.markMetaDirty();
            } else {
                const project_id: u32 = @intCast(key);
                if (model.activateFirstThreadInProject(project_id)) model.markMetaDirty();
            }
        },
        .palette_action => |action| {
            model.model_picker_open = false;
            switch (action) {
                .search => update(model, .open_search, fx),
                .new_thread => update(model, .new_thread, fx),
                .new_project_thread => update(model, .new_project_thread, fx),
                .move_thread => update(model, .open_move_thread, fx),
                .attach => update(model, .open_file_picker, fx),
                .tools => update(model, .open_mcp_tools, fx),
                .snippets => update(model, .open_snippets, fx),
                .export_thread => update(model, .export_thread, fx),
                .export_workspace => update(model, .export_workspace, fx),
                .archive => update(model, .open_archive, fx),
                .settings => update(model, .open_settings, fx),
            }
        },
        .toggle_model_picker => {
            model.model_picker_open = !model.model_picker_open;
            if (model.model_picker_open and model.model_catalog_count == 0) model.setModelCatalogStatus("Search OpenRouter by model or provider");
        },
        .select_model => |choice| {
            if (choice == .claude_subscription and !model.dev_mode) {
                model.setStatus("The experimental Claude connection is disabled in public builds");
                return;
            }
            model.selectModel(choice);
            if (model.activeThreadConst()) |thread| model.markThreadDirty(thread.id);
        },
        .select_quick_model => |number| model.selectQuickModel(number),
        .select_auto_model => {
            model.selectModel(.auto);
            if (model.activeThreadConst()) |thread| model.markThreadDirty(thread.id);
        },
        .select_codex_subscription => {
            model.selectModel(.codex_subscription);
            if (model.activeThreadConst()) |thread| model.markThreadDirty(thread.id);
        },
        .select_claude_subscription => {
            if (!model.dev_mode) {
                model.setStatus("The experimental Claude connection is disabled in public builds");
                return;
            }
            model.selectModel(.claude_subscription);
            if (model.activeThreadConst()) |thread| model.markThreadDirty(thread.id);
        },
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
            closeSearch(model, fx);
            model.fork_open = false;
            model.rename_open = false;
            model.archive_open = false;
            model.move_open = false;
            model.clear_confirm_thread_id = 0;
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
        .connect_codex => connectCodex(model, fx),
        .connect_claude => connectClaude(model, fx),
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
        .toggle_fork_model => |choice| {
            if (choice == .claude_subscription and !model.dev_mode) return;
            model.fork_model_mask ^= forkChoiceBit(choice);
        },
        .create_forks => {
            const first_new_thread = model.thread_count;
            createForks(model, fx);
            for (model.threads[first_new_thread..model.thread_count]) |thread| model.markThreadMessagesDirty(thread.id);
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
        .open_move_thread => {
            closeSearch(model, fx);
            model.openMoveThread();
        },
        .move_thread_to => |project_id| {
            if (model.moveThread(project_id)) model.showToast("Chat moved", fx);
        },
        .open_snippets => {
            closeSearch(model, fx);
            model.model_picker_open = false;
            model.settings_open = true;
            model.move_open = false;
        },
        .snippet_name_edit => |edit| model.snippet_name_buffer.apply(edit),
        .snippet_body_edit => |edit| model.snippet_body_buffer.apply(edit),
        .save_snippet => if (model.saveSnippet()) model.showToast("Prompt snippet saved", fx),
        .use_snippet => |id| if (model.insertSnippet(id)) model.showToast("Prompt inserted", fx),
        .delete_snippet => |id| if (model.deleteSnippet(id)) model.showToast("Prompt snippet deleted", fx),
        .add_mcp_server => {
            const id = model.addMcpServer() orelse {
                model.showToast("Use a unique name and command", fx);
                return;
            };
            model.showToast("MCP server added", fx);
            _ = startMcpHelper(model, id, null, fx);
        },
        .remove_mcp_server => |id| if (model.removeMcpServer(id)) model.showToast("MCP server removed", fx),
        .toggle_mcp_server => |id| {
            if (!model.toggleMcpServer(id)) return;
            const server = model.mcpServerByIdConst(id) orelse return;
            model.showToast(if (server.enabled) "MCP server enabled" else "MCP server disabled", fx);
            if (server.enabled) _ = startMcpHelper(model, id, null, fx);
        },
        .refresh_mcp_server => |id| {
            if (!startMcpHelper(model, id, null, fx)) model.showToast("Another MCP request is already running", fx);
        },
        .open_mcp_tools => {
            model.model_picker_open = false;
            model.settings_open = false;
            model.fork_open = false;
            model.rename_open = false;
            model.archive_open = false;
            model.move_open = false;
            model.mcp_selected_tool = std.math.maxInt(usize);
            model.mcp_arguments_buffer.set("{}");
            model.settings_open = true;
        },
        .select_mcp_tool => |index| {
            if (index >= model.mcp_tool_count) return;
            const tool = &model.mcp_tools[index];
            const server = model.mcpServerByIdConst(tool.server_id) orelse return;
            if (!server.enabled) return;
            const thread = model.activeThread() orelse return;
            var draft: [max_draft_bytes]u8 = undefined;
            const invocation = std.fmt.bufPrint(&draft, "/mcp {d} {s} {{}}", .{ server.id, tool.name() }) catch return;
            thread.draft_buffer.set(invocation);
            var status: [max_status_bytes]u8 = undefined;
            var status_writer: std.Io.Writer = .fixed(&status);
            if (tool.description_len > 0) {
                status_writer.writeAll(tool.description()[0..utf8PrefixLen(tool.description(), 96)]) catch {};
                status_writer.writeAll(" · ") catch {};
            }
            status_writer.writeAll(tool.schema()[0..utf8PrefixLen(tool.schema(), status.len - status_writer.buffered().len)]) catch {};
            thread.setStatus(status_writer.buffered());
            model.markThreadDirty(thread.id);
            model.settings_open = false;
            model.focusComposer();
        },
        .export_thread => {
            if (model.export_pending) return;
            model.export_thread_id = model.active_thread_id;
            model.export_request = .thread_markdown;
        },
        .export_workspace => {
            if (model.export_pending) return;
            model.export_request = .workspace_json;
        },
        .export_started => {
            model.export_pending = true;
            pollDatabaseReads(model, fx);
        },
        .export_finished => |success| {
            model.export_pending = false;
            model.showToast(if (success) "Export saved" else "Export failed", fx);
        },
        .archive_thread => {
            if (model.archiveThread(fx)) {
                model.showToast("Chat archived", fx);
                model.markStructureDirty();
            }
        },
        .archive_project => {
            if (model.archiveProject(fx)) {
                model.showToast("Project archived", fx);
                model.markStructureDirty();
            }
        },
        .open_archive => {
            model.purgeExpired(fx);
            model.markStructureDirty();
            model.model_picker_open = false;
            closeSearch(model, fx);
            model.settings_open = false;
            model.fork_open = false;
            model.rename_open = false;
            model.clear_confirm_thread_id = 0;
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
            if (project_id == chats_project_id) return;
            const project = model.projectByIdConst(project_id) orelse return;
            if (!project.isArchived()) return;
            model.delete_kind = .project;
            model.delete_id = project_id;
            model.delete_confirm_open = true;
        },
        .confirm_delete => {
            if (!model.delete_confirm_open) return;
            const deleted = if (model.delete_kind == .project)
                model.deleteProject(model.delete_id, fx)
            else
                model.deleteThread(model.delete_id, fx);
            model.delete_confirm_open = false;
            model.delete_id = 0;
            if (deleted) {
                model.showToast(if (model.delete_kind == .project) "Project deleted permanently" else "Chat deleted permanently", fx);
                model.markStructureDirty();
            }
        },
        .cancel_delete => {
            model.delete_confirm_open = false;
            model.delete_id = 0;
        },
        .new_project => {
            const project_id = model.addProject() orelse return;
            const thread_id = model.addThread(project_id) orelse return;
            _ = model.activateThread(thread_id);
            model.focusComposer();
            model.markStructureDirty();
        },
        .new_thread => {
            const thread_id = model.addThread(chats_project_id) orelse return;
            _ = model.activateThread(thread_id);
            model.focusComposer();
            model.markStructureDirty();
        },
        .new_project_thread => {
            if (model.active_project_id == chats_project_id) return;
            const thread_id = model.addThread(model.active_project_id) orelse return;
            _ = model.activateThread(thread_id);
            model.focusComposer();
            model.markStructureDirty();
        },
        .select_top_level_chats => {
            if (model.active_project_id == chats_project_id) return;
            if (model.activateFirstThreadInProject(chats_project_id)) model.markMetaDirty();
        },
        .select_project_slot => |slot| {
            if (model.activateProjectSlot(slot)) model.markMetaDirty();
        },
        .select_thread_slot => |slot| {
            if (model.activateThreadSlot(slot)) model.markMetaDirty();
        },
        .select_sidebar_row => |key| {
            if (key > std.math.maxInt(u32)) {
                const thread_id: u32 = @intCast(key & std.math.maxInt(u32));
                if (thread_id == model.active_thread_id) return;
                if (model.activateThread(thread_id)) model.markMetaDirty();
                return;
            }
            const project_id: u32 = @intCast(key);
            if (project_id == model.active_project_id) return;
            if (model.activateFirstThreadInProject(project_id)) model.markMetaDirty();
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
        .focus_composer => model.focusComposer(),
        .open_model_picker => {
            model.settings_open = false;
            closeSearch(model, fx);
            model.fork_open = false;
            model.rename_open = false;
            model.archive_open = false;
            model.move_open = false;
            model.clear_confirm_thread_id = 0;
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
            model.move_open = false;
            model.move_thread_id = 0;
            model.mcp_selected_tool = std.math.maxInt(usize);
            model.mcp_arguments_buffer.clear();
            closeSearch(model, fx);
            model.clear_confirm_thread_id = 0;
            model.clearApiKeyInput();
            model.fork_seed_buffer.clear();
            model.rename_buffer.clear();
            model.snippet_name_buffer.clear();
            model.snippet_body_buffer.clear();
        },
        .load_older => {
            const thread = model.activeThread() orelse return;
            if (!thread.has_older_messages or thread.history_loading or thread.message_count == 0) return;
            thread.history_loading = true;
            model.history_request_thread_id = thread.id;
            pollDatabaseReads(model, fx);
        },
        .clear => {
            if (model.cannotClear()) return;
            if (model.clear_confirm_thread_id != model.active_thread_id) {
                model.clear_confirm_thread_id = model.active_thread_id;
                model.showToast("Press Clear again to permanently remove every message", fx);
                return;
            }
            model.settings_open = false;
            model.fork_open = false;
            model.rename_open = false;
            model.archive_open = false;
            model.model_picker_open = false;
            model.clear_confirm_thread_id = 0;
            const thread = model.activeThread() orelse return;
            if (thread.sending) {
                fx.cancel(requestKey(thread.id));
                thread.setStatus("Cancelling…");
            } else {
                thread.clearStatus();
            }
            for (thread.messages[0..thread.message_count]) |*message| message.deinit(model.allocator);
            thread.message_count = 0;
            thread.total_cost_micros = 0;
            thread.active_model_len = 0;
            thread.stream_message_index = null;
            thread.stream_failed = false;
            thread.stream_pending_len = 0;
            thread.stream_flush_scheduled = false;
            fx.cancelTimer(streamFlushKey(thread.id));
            model.markMessagesCleared(thread.id);
            model.showToast("Chat cleared", fx);
        },
        .send => submitDraft(model, fx),
        .stop => stopActiveRequest(model, fx),
        .edit_message => |message_id| editMessage(model, message_id, fx),
        .retry_message => |message_id| retryMessage(model, message_id, fx),
        .retry_latest => {
            const message_id = model.latestAssistantMessageId() orelse return;
            retryMessage(model, message_id, fx);
        },
        .stream_line => |line| receiveStreamLine(model, line, fx),
        .harness_line => |line| receiveHarnessLine(model, line, fx),
        .harness_exit => |exit_event| {
            const thread_id = requestThreadId(exit_event.key) orelse return;
            const completed = receiveHarnessExit(model, exit_event, fx);
            if (completed) if (model.threadById(thread_id)) |thread| completeThreadResponse(model, thread);
            markLatestAssistantDirty(model, thread_id);
        },
        .openrouter_exit => |exit_event| {
            const thread_id = requestThreadId(exit_event.key) orelse return;
            const completed = receiveOpenRouterExit(model, exit_event, fx);
            if (completed) if (model.threadById(thread_id)) |thread| completeThreadResponse(model, thread);
            markLatestAssistantDirty(model, thread_id);
        },
        .connection_exit => |exit_event| receiveConnectionExit(model, exit_event),
        .mcp_exit => |exit_event| {
            const was_call = model.mcp_operation == .call;
            const completed = receiveMcpExit(model, exit_event, fx);
            if (was_call or model.settings_open) {
                model.showToast(if (completed and was_call)
                    "Tool result inserted"
                else if (completed)
                    "MCP tools refreshed"
                else
                    "MCP request failed", fx);
            }
            for (model.mcp_servers[0..model.mcp_server_count]) |server| {
                if (server.enabled and server.state == .idle) {
                    _ = startMcpHelper(model, server.id, null, fx);
                    break;
                }
            }
        },
        .mcp_timeout => |timer| {
            if (timer.key != mcp_timeout_key or model.mcp_operation == .none) return;
            fx.cancel(mcp_helper_key);
        },
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
        .dismiss_toast => |timer| {
            if (timer.key == toast_timer_key) {
                model.toast_len = 0;
                model.clear_confirm_thread_id = 0;
            }
        },
        .toggle_notifications => {
            model.notifications_enabled = !model.notifications_enabled;
            model.markMetaDirty();
        },
        .check_updates => checkUpdates(model, fx),
        .open_update => {
            if (model.update_state == .available and model.update_url_len > 0) model.open_update_requested = true else checkUpdates(model, fx);
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
            if (response.key == updates_request) {
                receiveUpdateCheck(model, response);
                return;
            }
            const thread_id = requestThreadId(response.key) orelse return;
            const completed = receive(model, response, fx);
            if (completed) if (model.threadById(thread_id)) |thread| completeThreadResponse(model, thread);
            markLatestAssistantDirty(model, thread_id);
        },
        .chrome_changed => |chrome| {
            model.header_height = @max(header_natural_height, chrome.insets.top);
        },
    }
}

fn stopActiveRequest(model: *Model, fx: *Effects) void {
    const thread = model.activeThread() orelse return;
    if (!thread.sending) return;
    fx.cancel(requestKey(thread.id));
    fx.cancel(requestBodyKey(thread.id));
    thread.setStatus("Stopping…");
}

fn restoreUserMessageToDraft(model: *Model, thread: *Thread, user_index: usize) bool {
    if (thread.sending or user_index >= thread.message_count or thread.messages[user_index].role != .user) return false;
    const from_message_id = thread.messages[user_index].id;
    for (thread.draft_attachments[0..thread.draft_attachment_count]) |*attachment| attachment.deinit(model.allocator);
    thread.draft_attachment_count = 0;
    thread.draft_buffer.set(thread.messages[user_index].content());
    const attachment_count = thread.messages[user_index].attachment_count;
    for (thread.messages[user_index].attachments[0..attachment_count], 0..) |attachment, index| {
        thread.draft_attachments[index] = attachment;
        thread.messages[user_index].attachments[index] = .{};
    }
    thread.draft_attachment_count = attachment_count;
    thread.messages[user_index].attachment_count = 0;
    var removed_cost: u64 = 0;
    for (thread.messages[user_index..thread.message_count]) |message| removed_cost +|= message.cost_micros;
    thread.total_cost_micros -|= removed_cost;
    for (thread.messages[user_index..thread.message_count]) |*message| message.deinit(model.allocator);
    thread.message_count = user_index;
    thread.stream_message_index = null;
    thread.stream_pending_len = 0;
    thread.stream_flush_scheduled = false;
    thread.stream_failed = false;
    thread.clearStatus();
    model.markMessagesTruncated(thread.id, from_message_id);
    return true;
}

fn editMessage(model: *Model, message_id: u32, fx: *Effects) void {
    const thread = model.activeThread() orelse return;
    for (thread.messages[0..thread.message_count], 0..) |message, index| {
        if (message.id != message_id or message.role != .user) continue;
        if (restoreUserMessageToDraft(model, thread, index)) {
            model.focusComposer();
            model.showToast("Message ready to edit", fx);
        }
        return;
    }
}

fn retryMessage(model: *Model, assistant_message_id: u32, fx: *Effects) void {
    const thread = model.activeThread() orelse return;
    if (thread.sending) {
        thread.setStatus("Stop the current response before retrying");
        return;
    }
    var assistant_index: ?usize = null;
    for (thread.messages[0..thread.message_count], 0..) |message, index| {
        if (message.id == assistant_message_id and message.role == .assistant) assistant_index = index;
    }
    var index = assistant_index orelse return;
    while (index > 0) {
        index -= 1;
        if (thread.messages[index].role != .user) continue;
        if (!restoreUserMessageToDraft(model, thread, index)) return;
        const before = model.next_message_id;
        sendThread(model, thread, fx);
        if (model.next_message_id != before) model.markMessageDirty(thread.id, before);
        return;
    }
}

fn completeThreadResponse(model: *Model, thread: *Thread) void {
    if (thread.id == model.active_thread_id) return;
    thread.unread = true;
    if (model.notifications_enabled) model.pending_notification_thread_id = thread.id;
}

fn markLatestAssistantDirty(model: *Model, thread_id: u32) void {
    const thread = model.threadByIdConst(thread_id) orelse return;
    if (thread.message_count == 0) return;
    const message = thread.messages[thread.message_count - 1];
    if (message.role == .assistant) model.markMessageDirty(thread_id, message.id);
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
        model.showToast("Response copied", fx);
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
        target.setTitle(source.title());
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

fn receiveConnectionExit(model: *Model, exit_event: native_sdk.EffectExit) void {
    const unavailable = exit_event.reason == .spawn_failed or exit_event.code == 127;
    const connected = exit_event.reason == .exited and exit_event.code == 0;
    switch (exit_event.key) {
        codex_status_key => model.codex_connection = if (connected) .connected else if (unavailable) .unavailable else .disconnected,
        claude_status_key => model.claude_connection = if (connected) .connected else if (unavailable) .unavailable else .disconnected,
        codex_login_key => {
            model.codex_connection = if (connected) .connected else if (unavailable) .unavailable else .failed;
            if (connected) {
                if (model.threadById(model.codex_login_thread_id)) |thread| {
                    Model.configureThreadModel(thread, .codex_subscription, "");
                    model.markThreadDirty(thread.id);
                }
                if (model.onboarding_open) {
                    model.onboarding_open = false;
                    model.credential_action = .complete_onboarding;
                }
            }
            model.codex_login_thread_id = 0;
        },
        claude_login_key => {
            model.claude_connection = if (connected) .connected else if (unavailable) .unavailable else .failed;
            if (connected) {
                if (model.threadById(model.claude_login_thread_id)) |thread| {
                    Model.configureThreadModel(thread, .claude_subscription, "");
                    model.markThreadDirty(thread.id);
                }
                if (model.onboarding_open) {
                    model.onboarding_open = false;
                    model.credential_action = .complete_onboarding;
                }
            }
            model.claude_login_thread_id = 0;
        },
        else => {},
    }
}

fn startMcpHelper(model: *Model, server_id: u32, tool_index: ?usize, fx: *Effects) bool {
    if (model.mcp_operation != .none or model.executable_path_len == 0) return false;
    const server = model.mcpServerById(server_id) orelse return false;
    if (!server.enabled) return false;
    var input_storage: [native_sdk.max_effect_stdin_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&input_storage);
    const mode: mcp.HelperMode = if (tool_index == null) .discover else .call;
    const tool_name = if (tool_index) |index| model.mcp_tools[index].name() else "";
    const arguments = if (tool_index != null) model.mcp_arguments_buffer.text() else "{}";
    mcp.writeHelperInput(&writer, server.command(), tool_name, arguments) catch {
        server.state = .failed;
        server.setStatus("Command or arguments are too large");
        return false;
    };
    fx.spawn(.{
        .key = mcp_helper_key,
        .argv = &.{ model.executablePath(), "--mcp-helper", @tagName(mode) },
        .stdin = writer.buffered(),
        .output = .collect,
        .on_exit = Effects.exitMsg(.mcp_exit),
    });
    fx.startTimer(.{ .key = mcp_timeout_key, .interval_ms = mcp_timeout_ms, .on_fire = Effects.timerMsg(.mcp_timeout) });
    model.mcp_operation = if (mode == .discover) .discover else .call;
    model.mcp_operation_server_id = server_id;
    model.mcp_operation_thread_id = model.active_thread_id;
    server.state = .connecting;
    server.setStatus(if (mode == .discover) "Discovering tools…" else "Running tool…");
    return true;
}

fn receiveMcpExit(model: *Model, exit_event: native_sdk.EffectExit, fx: *Effects) bool {
    if (exit_event.key != mcp_helper_key or model.mcp_operation == .none) return false;
    fx.cancelTimer(mcp_timeout_key);
    const operation = model.mcp_operation;
    const server_id = model.mcp_operation_server_id;
    const thread_id = model.mcp_operation_thread_id;
    model.mcp_operation = .none;
    model.mcp_operation_server_id = 0;
    model.mcp_operation_thread_id = 0;
    const server = model.mcpServerById(server_id) orelse return false;
    if (exit_event.reason != .exited or exit_event.code != 0 or exit_event.output_truncated) {
        server.state = .failed;
        const detail = std.mem.trim(u8, exit_event.stderr_tail, " \t\r\n");
        server.setStatus(if (exit_event.reason == .cancelled)
            "Connection timed out"
        else if (detail.len > 0)
            detail[0..utf8PrefixLen(detail, 120)]
        else
            "MCP server could not complete the request");
        return false;
    }
    switch (operation) {
        .discover => {
            var discovered: [mcp.max_tools]mcp.Tool = undefined;
            const count = mcp.parseTools(model.allocator, exit_event.output, server_id, &discovered) catch {
                server.state = .failed;
                server.setStatus("Server returned an invalid tool list");
                return false;
            };
            model.removeMcpToolsForServer(server_id);
            const available = model.mcp_tools.len - model.mcp_tool_count;
            const accepted = @min(count, available);
            @memcpy(model.mcp_tools[model.mcp_tool_count..][0..accepted], discovered[0..accepted]);
            model.mcp_tool_count += accepted;
            server.tool_count = accepted;
            server.state = .connected;
            server.setStatus(if (accepted == count) "Connected" else "Connected · some tools omitted");
            return true;
        },
        .call => {
            if (!model.mcpToolSelected()) return false;
            const tool = model.mcp_tools[model.mcp_selected_tool];
            var result_storage: [mcp.max_result_bytes]u8 = undefined;
            const result = mcp.formatCallResult(model.allocator, exit_event.output, &result_storage) catch {
                server.state = .failed;
                server.setStatus("Server returned an invalid tool result");
                return false;
            };
            server.state = .connected;
            server.setStatus("Connected");
            if (result.is_error) {
                const thread = model.threadById(thread_id) orelse return false;
                thread.setStatus(result_storage[0..result.len]);
                return false;
            }
            const thread = model.threadById(thread_id) orelse return false;
            var draft_storage: [max_draft_bytes]u8 = undefined;
            var draft_writer: std.Io.Writer = .fixed(&draft_storage);
            const raw_existing = std.mem.trim(u8, thread.draft(), " \t\r\n");
            const existing = if (std.mem.startsWith(u8, raw_existing, "/mcp ")) "" else raw_existing;
            if (existing.len > 0) {
                draft_writer.writeAll(existing) catch {};
                draft_writer.writeAll("\n\n") catch {};
            }
            draft_writer.print("[MCP result · {s}.{s}]\n", .{ server.name(), tool.name() }) catch {};
            const remaining = draft_storage.len - draft_writer.buffered().len;
            const result_len = utf8PrefixLen(result_storage[0..result.len], remaining);
            draft_writer.writeAll(result_storage[0..result_len]) catch {};
            thread.draft_buffer.set(draft_writer.buffered());
            model.markThreadDirty(thread.id);
            model.settings_open = false;
            model.mcp_selected_tool = std.math.maxInt(usize);
            model.mcp_arguments_buffer.clear();
            thread.clearStatus();
            model.focusComposer();
            return true;
        },
        .none => return false,
    }
}

fn submitDraft(model: *Model, fx: *Effects) void {
    if (startMcpDraft(model, fx)) return;
    const thread_id = model.active_thread_id;
    const before = model.next_message_id;
    send(model, fx);
    if (model.next_message_id != before) model.markMessageDirty(thread_id, before);
}

fn startMcpDraft(model: *Model, fx: *Effects) bool {
    const thread = model.activeThread() orelse return false;
    const draft = std.mem.trim(u8, thread.draft(), " \t\r\n");
    if (!std.mem.startsWith(u8, draft, "/mcp ")) return false;
    if (model.mcp_operation != .none) {
        thread.setStatus("Another MCP request is already running");
        return true;
    }
    var parts = std.mem.tokenizeScalar(u8, draft[5..], ' ');
    const server_text = parts.next() orelse {
        thread.setStatus("Use /mcp <server id> <tool name> <JSON object>");
        return true;
    };
    const tool_name = parts.next() orelse {
        thread.setStatus("Choose an MCP tool from Settings first");
        return true;
    };
    const arguments = std.mem.trim(u8, parts.rest(), " \t\r\n");
    const server_id = std.fmt.parseInt(u32, server_text, 10) catch {
        thread.setStatus("The MCP server id is invalid");
        return true;
    };
    var tool_index: ?usize = null;
    for (model.mcp_tools[0..model.mcp_tool_count], 0..) |*tool, index| {
        if (tool.server_id == server_id and std.mem.eql(u8, tool.name(), tool_name)) tool_index = index;
    }
    const index = tool_index orelse {
        thread.setStatus("That MCP tool is no longer available; refresh it in Settings");
        return true;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, model.allocator, arguments, .{}) catch {
        thread.setStatus("MCP arguments must be a valid JSON object");
        return true;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        thread.setStatus("MCP arguments must be a JSON object");
        return true;
    }
    model.mcp_arguments_buffer.set(arguments);
    model.mcp_selected_tool = index;
    if (startMcpHelper(model, server_id, index, fx))
        thread.setStatus("Running MCP tool…")
    else
        thread.setStatus("Could not start the MCP tool");
    return true;
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

fn isSubscriptionChoice(choice: ModelChoice) bool {
    return choice == .codex_subscription or choice == .claude_subscription;
}

fn hasContextAttachments(thread: *const Thread) bool {
    const first = thread.message_count -| provider_context_messages;
    for (thread.messages[first..thread.message_count]) |message| if (message.attachment_count > 0) return true;
    return false;
}

fn startAttachmentRequest(model: *Model, thread: *Thread, fx: *Effects) bool {
    const body = model.buildAttachmentRequest(thread) orelse {
        thread.setStatus("Attachments could not be prepared; use text, supported images, or a PDF under 640 KB total");
        return false;
    };
    defer model.allocator.free(body);
    var nonce: u64 = undefined;
    std.c.arc4random_buf(@ptrCast(&nonce), @sizeOf(u64));
    const path = std.fmt.bufPrint(&thread.request_path_storage, "/tmp/superchat-request-{d}-{x}.json", .{ thread.id, nonce }) catch {
        thread.setStatus("The temporary attachment request could not be created");
        return false;
    };
    thread.request_path_len = path.len;
    fx.writeFile(.{
        .key = requestBodyKey(thread.id),
        .path = path,
        .bytes = body,
        .on_result = Effects.fileMsg(.request_body_written),
    });
    thread.sending = true;
    thread.stream_message_index = null;
    thread.stream_failed = false;
    thread.setStatus("Preparing attachments…");
    return true;
}

fn receiveRequestBodyWritten(model: *Model, result: native_sdk.EffectFileResult, fx: *Effects) void {
    const thread_id = requestBodyThreadId(result.key) orelse return;
    const thread = model.threadById(thread_id) orelse return;
    if (!thread.sending) return;
    if (result.outcome != .ok) {
        thread.sending = false;
        thread.request_path_len = 0;
        thread.setStatus("The attachment request could not be prepared on disk");
        return;
    }
    const path = thread.requestPath();
    if (path.len == 0) {
        thread.sending = false;
        thread.setStatus("The temporary attachment request could not be opened");
        return;
    }
    var auth_storage: [max_api_key_bytes + 40]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_storage, "header = \"Authorization: Bearer {s}\"\n", .{model.apiKey()}) catch {
        thread.sending = false;
        thread.setStatus("The OpenRouter API key is too long");
        return;
    };
    fx.spawn(.{
        .key = requestKey(thread.id),
        .argv = &.{ "/bin/zsh", "-lc", openrouter_curl_script, "superchat", path },
        .stdin = auth,
        .max_line_bytes = max_stream_line_bytes,
        .on_line = Effects.lineMsg(.stream_line),
        .on_exit = Effects.exitMsg(.openrouter_exit),
    });
    thread.setStatus("Thinking…");
}

fn buildHarnessPrompt(model: *Model, thread: *const Thread) ?[]const u8 {
    const header = "You are the assistant in Superchat. Answer the conversation directly. Do not inspect files or run tools.\n";
    const footer = "\n\nAssistant:\n";
    const limit = native_sdk.max_effect_stdin_bytes;
    var first = thread.message_count;
    var used = header.len + footer.len;
    var index = thread.message_count;
    while (index > 0) {
        const candidate = index - 1;
        const message = &thread.messages[candidate];
        const prefix = if (message.role == .user) "\n\nUser:\n" else "\n\nAssistant:\n";
        const needed = prefix.len + message.content().len;
        if (used + needed > limit) {
            if (first == thread.message_count) first = candidate;
            break;
        }
        first = candidate;
        used += needed;
        index = candidate;
        if (thread.message_count - first == provider_context_messages) break;
    }

    var writer: std.Io.Writer = .fixed(model.request_storage[0..limit]);
    writer.writeAll(header) catch return null;
    for (thread.messages[first..thread.message_count]) |*message| {
        const prefix = if (message.role == .user) "\n\nUser:\n" else "\n\nAssistant:\n";
        writer.writeAll(prefix) catch return null;
        const remaining = limit - writer.buffered().len -| footer.len;
        const content_len = utf8PrefixLen(message.content(), remaining);
        writer.writeAll(message.content()[0..content_len]) catch return null;
        for (message.attachments[0..message.attachment_count]) |*attachment| {
            if (attachment.kind != .text or attachment.bytes.len == 0 or !std.unicode.utf8ValidateSlice(attachment.bytes)) continue;
            const attachment_prefix = "\n\nAttached text file:\n";
            if (writer.buffered().len + attachment_prefix.len + footer.len >= limit) break;
            writer.writeAll(attachment_prefix) catch return null;
            const file_remaining = limit - writer.buffered().len -| footer.len;
            const file_len = utf8PrefixLen(attachment.bytes, file_remaining);
            writer.writeAll(attachment.bytes[0..file_len]) catch return null;
        }
    }
    writer.writeAll(footer) catch return null;
    return writer.buffered();
}

fn startHarnessRequest(model: *Model, thread: *Thread, fx: *Effects) bool {
    const prompt = buildHarnessPrompt(model, thread) orelse {
        thread.setStatus("Conversation could not be prepared for the provider harness");
        return false;
    };
    switch (thread.model_choice) {
        .codex_subscription => {
            var argv: [28][]const u8 = undefined;
            var count: usize = 0;
            const base = [_][]const u8{ "/bin/zsh", "-lc", codex_runner_script, "superchat", "exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--sandbox", "read-only", "--skip-git-repo-check", "-C", "/tmp" };
            for (base) |arg| {
                argv[count] = arg;
                count += 1;
            }
            const last = &thread.messages[thread.message_count - 1];
            for (last.attachments[0..last.attachment_count]) |*attachment| {
                if (attachment.kind != .image) continue;
                argv[count] = "--image";
                argv[count + 1] = attachment.path();
                count += 2;
            }
            argv[count] = "-";
            count += 1;
            fx.spawn(.{
                .key = requestKey(thread.id),
                .argv = argv[0..count],
                .stdin = prompt,
                .max_line_bytes = max_stream_line_bytes,
                .on_line = Effects.lineMsg(.harness_line),
                .on_exit = Effects.exitMsg(.harness_exit),
            });
        },
        .claude_subscription => fx.spawn(.{
            .key = requestKey(thread.id),
            .argv = &.{ "/bin/zsh", "-lc", claude_chat_script, "superchat" },
            .stdin = prompt,
            .max_line_bytes = max_stream_line_bytes,
            .on_line = Effects.lineMsg(.harness_line),
            .on_exit = Effects.exitMsg(.harness_exit),
        }),
        else => return false,
    }
    thread.sending = true;
    thread.stream_message_index = null;
    thread.stream_failed = false;
    thread.setStatus("Thinking…");
    return true;
}

fn sendThread(model: *Model, thread: *Thread, fx: *Effects) void {
    if (thread.sending) return;
    model.expandSnippetDraft(thread);
    if ((thread.draft_buffer.isEmpty() and thread.draft_attachment_count == 0) or thread.model_buffer.isEmpty()) return;
    if (thread.model_choice == .claude_subscription and !model.dev_mode) {
        thread.setStatus("The experimental Claude connection is disabled in public builds");
        return;
    }
    if (thread.model_choice == .codex_subscription and model.codex_connection != .connected) {
        thread.setStatus("Connect Codex in Settings before sending");
        return;
    }
    if (thread.model_choice == .claude_subscription and model.claude_connection != .connected) {
        thread.setStatus("Connect Claude in Settings before sending");
        return;
    }
    if (!isSubscriptionChoice(thread.model_choice) and model.api_key_len == 0) return;
    if (thread.model_choice == .codex_subscription) {
        for (thread.draft_attachments[0..thread.draft_attachment_count]) |attachment| {
            if (attachment.kind == .pdf) {
                thread.setStatus("Codex accepts images and text files here; use OpenRouter for PDFs");
                return;
            }
        }
    }
    if (thread.model_choice == .claude_subscription) {
        for (thread.draft_attachments[0..thread.draft_attachment_count]) |attachment| {
            if (attachment.kind != .text) {
                thread.setStatus("The experimental Claude connection currently accepts text files only");
                return;
            }
        }
    }
    if (!thread.appendMessage(model.allocator, &model.next_message_id, .user, thread.draft())) return;
    thread.draft_buffer.clear();
    thread.request_started_ms = model.clock.wallMs();
    thread.request_prompt_tokens = 0;
    thread.request_completion_tokens = 0;
    thread.request_cost_micros = 0;

    if (isSubscriptionChoice(thread.model_choice)) {
        _ = startHarnessRequest(model, thread, fx);
        return;
    }

    if (hasContextAttachments(thread)) {
        _ = startAttachmentRequest(model, thread, fx);
        return;
    }

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
    const is_data = std.mem.startsWith(u8, event_line, "data:");
    if (!is_data and event_line[0] != '{') return;
    const payload = if (is_data)
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
    if (parsed.value.usage) |usage| {
        thread.request_prompt_tokens = usage.prompt_tokens;
        thread.request_completion_tokens = usage.completion_tokens;
        if (usage.cost > 0 and usage.cost < 1_000_000) thread.request_cost_micros = @intFromFloat(@round(usage.cost * 1_000_000.0));
    }
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

fn queueHarnessText(model: *Model, thread: *Thread, key: u64, content: []const u8, fx: *Effects) void {
    if (!thread.queueStreamDelta(model.allocator, content)) {
        thread.stream_failed = true;
        thread.setStatus("Response exceeded the 64 KiB safety limit");
        fx.cancel(key);
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

fn receiveHarnessLine(model: *Model, line: native_sdk.EffectLine, fx: *Effects) void {
    const thread_id = requestThreadId(line.key) orelse return;
    const thread = model.threadById(thread_id) orelse return;
    if (!thread.sending) return;
    if (line.truncated or line.dropped_before > 0) {
        thread.stream_failed = true;
        thread.setStatus("Provider output was incomplete; request cancelled");
        fx.cancel(line.key);
        return;
    }

    var scratch = std.heap.FixedBufferAllocator.init(&model.stream_parse_storage);
    switch (thread.model_choice) {
        .codex_subscription => {
            var parsed = std.json.parseFromSlice(CodexStreamEvent, scratch.allocator(), line.line, .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.type, "item.completed")) return;
            const item = parsed.value.item orelse return;
            if (!std.mem.eql(u8, item.type, "agent_message") or item.text.len == 0) return;
            thread.setActiveModel("Codex · ChatGPT");
            queueHarnessText(model, thread, line.key, item.text, fx);
        },
        .claude_subscription => {
            var parsed = std.json.parseFromSlice(ClaudeStreamEvent, scratch.allocator(), line.line, .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            if (std.mem.eql(u8, parsed.value.type, "result") and parsed.value.is_error) {
                thread.stream_failed = true;
                thread.setStatus(if (parsed.value.result.len > 0) parsed.value.result else "Claude could not complete the request");
                return;
            }
            if (!std.mem.eql(u8, parsed.value.type, "stream_event")) return;
            const event = parsed.value.event orelse return;
            if (!std.mem.eql(u8, event.type, "content_block_delta")) return;
            const delta = event.delta orelse return;
            if (!std.mem.eql(u8, delta.type, "text_delta") or delta.text.len == 0) return;
            thread.setActiveModel("Claude · Sonnet");
            queueHarnessText(model, thread, line.key, delta.text, fx);
        },
        else => {},
    }
}

fn finalizeResponseMetrics(model: *Model, thread: *Thread) void {
    const index = thread.stream_message_index orelse return;
    if (index >= thread.message_count) return;
    const message = &thread.messages[index];
    const response_model = if (thread.active_model_len > 0) thread.active_model_storage[0..thread.active_model_len] else thread.modelName();
    message.response_model_len = utf8PrefixLen(response_model, message.response_model_storage.len);
    @memcpy(message.response_model_storage[0..message.response_model_len], response_model[0..message.response_model_len]);
    const elapsed = @max(model.clock.wallMs() - thread.request_started_ms, 0);
    message.latency_ms = @intCast(@min(elapsed, std.math.maxInt(u32)));
    message.prompt_tokens = thread.request_prompt_tokens;
    message.completion_tokens = thread.request_completion_tokens;
    thread.total_cost_micros -|= message.cost_micros;
    message.cost_micros = thread.request_cost_micros;
    thread.total_cost_micros +|= message.cost_micros;
}

fn receiveHarnessExit(model: *Model, exit_event: native_sdk.EffectExit, fx: *Effects) bool {
    const thread_id = requestThreadId(exit_event.key) orelse return false;
    const thread = model.threadById(thread_id) orelse return false;
    const unavailable = exit_event.reason == .spawn_failed or exit_event.code == 127;
    const succeeded = exit_event.reason == .exited and exit_event.code == 0;
    if (exit_event.reason != .cancelled) switch (thread.model_choice) {
        .codex_subscription => model.codex_connection = if (succeeded) .connected else if (unavailable) .unavailable else .disconnected,
        .claude_subscription => model.claude_connection = if (succeeded) .connected else if (unavailable) .unavailable else .disconnected,
        else => {},
    };
    if (thread.stream_flush_scheduled) fx.cancelTimer(streamFlushKey(thread.id));
    if (thread.stream_pending_len > 0 and !thread.flushStreamDelta(model.allocator, &model.next_message_id)) {
        thread.stream_failed = true;
        thread.setStatus("Response exceeded the 64 KiB safety limit");
    }
    const received_content = thread.stream_message_index != null;
    finalizeResponseMetrics(model, thread);
    thread.sending = false;
    thread.stream_message_index = null;
    if (exit_event.reason == .cancelled) {
        thread.setStatus("Request cancelled");
        return false;
    }
    if (exit_event.dropped_lines > 0) {
        thread.stream_failed = true;
        thread.setStatus("Provider output was incomplete");
        return false;
    }
    if (exit_event.reason != .exited or exit_event.code != 0) {
        if (thread.stream_failed) return false;
        thread.setStatus(switch (thread.model_choice) {
            .codex_subscription => if (unavailable) "Codex CLI not found; install Codex or the ChatGPT app" else "Codex request failed; reconnect it in Settings",
            .claude_subscription => if (unavailable) "Claude CLI not found; install it, then retry" else "Claude request failed; reconnect it in Settings",
            else => "Provider request failed",
        });
        return false;
    }
    if (thread.stream_failed) return false;
    if (!received_content) {
        thread.setStatus("The provider returned no text");
        return false;
    }
    thread.clearStatus();
    return true;
}

fn receiveOpenRouterExit(model: *Model, exit_event: native_sdk.EffectExit, fx: *Effects) bool {
    const thread_id = requestThreadId(exit_event.key) orelse return false;
    const thread = model.threadById(thread_id) orelse return false;
    thread.request_path_len = 0;
    if (thread.stream_flush_scheduled) fx.cancelTimer(streamFlushKey(thread.id));
    if (thread.stream_pending_len > 0 and !thread.flushStreamDelta(model.allocator, &model.next_message_id)) {
        thread.stream_failed = true;
        thread.setStatus("Response exceeded the 64 KiB safety limit");
    }
    const received_content = thread.stream_message_index != null;
    finalizeResponseMetrics(model, thread);
    thread.sending = false;
    thread.stream_message_index = null;
    if (thread.stream_failed) return false;
    if (exit_event.reason == .cancelled) {
        thread.setStatus("Request cancelled");
        return false;
    }
    if (exit_event.dropped_lines > 0) {
        thread.setStatus("OpenRouter output was incomplete");
        return false;
    }
    if (exit_event.reason != .exited or exit_event.code != 0) {
        thread.setStatus("OpenRouter could not complete the attachment request");
        return false;
    }
    if (!received_content) {
        thread.setStatus("OpenRouter returned no text");
        return false;
    }
    thread.clearStatus();
    return true;
}

fn receive(model: *Model, response: native_sdk.EffectResponse, fx: *Effects) bool {
    const target_thread_id = requestThreadId(response.key) orelse return false;
    const thread = model.threadById(target_thread_id) orelse return false;
    if (thread.stream_flush_scheduled) fx.cancelTimer(streamFlushKey(thread.id));
    if (thread.stream_pending_len > 0 and !thread.flushStreamDelta(model.allocator, &model.next_message_id)) {
        thread.stream_failed = true;
        thread.setStatus("Response exceeded the 64 KiB safety limit");
    }
    finalizeResponseMetrics(model, thread);
    return receiveThread(thread, response);
}

fn receiveThread(thread: *Thread, response: native_sdk.EffectResponse) bool {
    thread.sending = false;
    const received_content = thread.stream_message_index != null;
    thread.stream_message_index = null;
    if (response.dropped_before > 0) {
        thread.stream_failed = true;
        thread.setStatus("Streaming response was incomplete");
    }
    if (response.outcome != .ok) {
        if (thread.stream_failed) return false;
        thread.setStatus(switch (response.outcome) {
            .rejected => "The request was rejected before it started",
            .connect_failed => "Could not connect to OpenRouter",
            .tls_failed => "OpenRouter's secure connection failed",
            .protocol_failed => "The connection ended unexpectedly",
            .timed_out => "OpenRouter took too long to respond",
            .cancelled => "Request cancelled",
            .ok => unreachable,
        });
        return false;
    }
    if (response.status < 200 or response.status >= 300) {
        if (thread.stream_failed) return false;
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
            return false;
        }
        var status_buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&status_buffer, "OpenRouter returned HTTP {d}", .{response.status}) catch "OpenRouter request failed";
        thread.setStatus(text);
        return false;
    }
    if (thread.stream_failed) return false;
    if (!received_content) {
        thread.setStatus("OpenRouter returned no text");
        return false;
    }
    thread.clearStatus();
    return true;
}

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");
pub const CompiledAppView = blk: {
    @setEvalBranchQuota(1_000_000);
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
            if (!usesPersistentCredentialStore(self.chat.model.dev_mode)) {
                // Debug/ad-hoc binaries change signing identity frequently.
                // Keep their keys in memory so they never trigger Keychain's
                // access prompt for the production credential item.
                self.chat.model.onboarding_open = shouldShowOnboarding(true, self.chat.model.force_onboarding, self.chat.model.api_key_len > 0, false);
            } else {
                // An explicit launch-time environment key wins; otherwise
                // restore the release credential from macOS Keychain.
                if (self.chat.model.api_key_len == 0) {
                    var buffer: [max_api_key_bytes]u8 = undefined;
                    if (runtime.getCredential(.{ .service = credential_service, .account = credential_account }, &buffer) catch null) |secret| {
                        self.chat.model.setApiKey(secret);
                    }
                }
                var onboarding_buffer: [8]u8 = undefined;
                const onboarding_complete = (runtime.getCredential(.{ .service = credential_service, .account = onboarding_account }, &onboarding_buffer) catch null) != null;
                self.chat.model.onboarding_open = shouldShowOnboarding(false, self.chat.model.force_onboarding, self.chat.model.api_key_len > 0, onboarding_complete);
            }
        }

        try self.inner.event(runtime, value);
        if (value == .files_dropped) {
            const drop = value.files_dropped;
            try self.chat.dispatch(runtime, drop.window_id, .{ .files_dropped = drop });
        }
        if (self.chat.model.file_picker_requested) {
            self.chat.model.file_picker_requested = false;
            var paths_buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
            const filters = [_]native_sdk.platform.FileFilter{
                .{ .name = "Images, PDFs, and text files", .extensions = &.{ "png", "jpg", "jpeg", "webp", "gif", "pdf", "txt", "md", "json", "csv", "tsv", "xml", "yaml", "yml", "html", "css", "js", "jsx", "ts", "tsx", "zig", "py", "rb", "go", "rs", "java", "c", "h", "cpp", "hpp", "swift", "kt", "sh", "sql", "toml", "ini", "log", "rtf" } },
            };
            const selected = runtime.showOpenDialog(.{
                .title = "Attach to Superchat",
                .filters = &filters,
                .allow_multiple = true,
            }, &paths_buffer) catch null;
            if (selected) |result| {
                if (result.count > 0) {
                    var paths: [16][]const u8 = undefined;
                    var count: usize = 0;
                    var split = std.mem.splitScalar(u8, result.paths, '\n');
                    while (split.next()) |path| {
                        if (path.len == 0 or count == paths.len) continue;
                        paths[count] = path;
                        count += 1;
                    }
                    if (count > 0) try self.chat.dispatch(runtime, 1, .{ .files_dropped = .{ .window_id = 1, .view_label = canvas_label, .paths = paths[0..count] } });
                }
            }
        }
        if (self.chat.model.export_request != .none) {
            const kind = self.chat.model.export_request;
            self.chat.model.export_request = .none;
            const filters = [_]native_sdk.platform.FileFilter{.{
                .name = if (kind == .thread_markdown) "Markdown" else "JSON",
                .extensions = if (kind == .thread_markdown) &.{"md"} else &.{"json"},
            }};
            var path_buffer: [native_sdk.platform.max_dialog_path_bytes]u8 = undefined;
            const selected = runtime.showSaveDialog(.{
                .title = if (kind == .thread_markdown) "Export chat" else "Export Superchat workspace",
                .default_name = if (kind == .thread_markdown) "superchat-chat.md" else "superchat-workspace.json",
                .filters = &filters,
            }, &path_buffer) catch null;
            if (selected) |path| {
                self.flushPersistence();
                var record = persistence.ExportRecord{
                    .kind = if (kind == .thread_markdown) .thread_markdown else .workspace_json,
                    .thread_id = self.chat.model.export_thread_id,
                    .path_len = @min(path.len, 1024),
                };
                @memcpy(record.path[0..record.path_len], path[0..record.path_len]);
                if (self.persistence_worker.enqueueExport(record)) {
                    try self.chat.dispatch(runtime, 1, .export_started);
                } else {
                    try self.chat.dispatch(runtime, 1, .{ .export_finished = false });
                }
            }
        }
        if (self.chat.model.search_request_pending) {
            self.chat.model.search_request_pending = false;
            const query = std.mem.trim(u8, self.chat.model.search_buffer.text(), " \t\r\n");
            if (query.len >= 2) {
                var request = persistence.SearchRequest{
                    .generation = self.chat.model.search_generation,
                    .query_len = @min(query.len, persistence.max_search_query_bytes),
                    .limit = max_search_results,
                };
                @memcpy(request.query[0..request.query_len], query[0..request.query_len]);
                if (!self.persistence_worker.enqueue(.{ .search = request })) self.chat.model.search_loading = false;
            }
        }
        if (self.persistence_worker.takeSearchResult()) |result_value| {
            var result = result_value;
            const model = &self.chat.model;
            if (result.generation == model.search_generation) {
                model.search_result_count = @min(result.page.hits.len, model.search_results.len);
                for (result.page.hits[0..model.search_result_count], 0..) |hit, index| {
                    var entry = SearchEntry{ .thread_id = hit.thread_id };
                    entry.title_len = utf8PrefixLen(hit.title, entry.title_storage.len);
                    @memcpy(entry.title_storage[0..entry.title_len], hit.title[0..entry.title_len]);
                    entry.snippet_len = utf8PrefixLen(hit.snippet, entry.snippet_storage.len);
                    @memcpy(entry.snippet_storage[0..entry.snippet_len], hit.snippet[0..entry.snippet_len]);
                    model.search_results[index] = entry;
                }
                model.search_loading = false;
            }
            result.page.deinit(model.allocator);
            if (self.chat.installed) try self.chat.rebuild(runtime, self.chat.canvas_window_id);
        }
        if (self.chat.model.history_request_thread_id != 0) {
            const thread_id = self.chat.model.history_request_thread_id;
            self.chat.model.history_request_thread_id = 0;
            if (self.chat.model.threadByIdConst(thread_id)) |thread| {
                if (thread.message_count > 0) {
                    const queued = self.persistence_worker.enqueue(.{ .load_history = .{
                        .thread_id = thread_id,
                        .before_id = thread.messages[0].id,
                        .limit = history_page_size,
                    } });
                    if (!queued) {
                        if (self.chat.model.threadById(thread_id)) |mutable_thread| mutable_thread.history_loading = false;
                        self.chat.model.setStatus("Local history is busy; try again in a moment");
                    }
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
                        var message = Message{
                            .id = history.id,
                            .role = if (history.role == @intFromEnum(Role.assistant)) .assistant else .user,
                            .content_storage = history.content,
                            .content_len = history.content.len,
                            .latency_ms = history.latency_ms,
                            .prompt_tokens = history.prompt_tokens,
                            .completion_tokens = history.completion_tokens,
                            .cost_micros = history.cost_micros,
                        };
                        message.response_model_len = utf8PrefixLen(history.response_model, message.response_model_storage.len);
                        @memcpy(message.response_model_storage[0..message.response_model_len], history.response_model[0..message.response_model_len]);
                        for (history.attachments[0..history.attachment_count], 0..) |attachment, attachment_index| {
                            if (attachment.kind >= std.meta.fields(AttachmentKind).len) continue;
                            var restored = Attachment{ .kind = @enumFromInt(attachment.kind) };
                            restored.path_len = utf8PrefixLen(attachment.path, restored.path_storage.len);
                            @memcpy(restored.path_storage[0..restored.path_len], attachment.path[0..restored.path_len]);
                            restored.name_len = utf8PrefixLen(attachment.name, restored.name_storage.len);
                            @memcpy(restored.name_storage[0..restored.name_len], attachment.name[0..restored.name_len]);
                            message.attachments[attachment_index] = restored;
                            message.attachment_count += 1;
                        }
                        thread.messages[index] = message;
                        result.page.messages[index].content = @constCast(&[_]u8{});
                        if (result.page.messages[index].response_model.len > 0) model.allocator.free(result.page.messages[index].response_model);
                        result.page.messages[index].response_model = @constCast(&[_]u8{});
                    }
                    thread.message_count += count;
                    thread.has_older_messages = result.page.has_more;
                }
                thread.history_loading = false;
            }
            result.page.deinit(model.allocator);
            if (self.chat.installed) try self.chat.rebuild(runtime, self.chat.canvas_window_id);
        }
        if (self.persistence_worker.takeExportResult()) |success| {
            try self.chat.dispatch(runtime, 1, .{ .export_finished = success });
        }
        if (self.chat.model.pending_notification_thread_id != 0) {
            const thread_id = self.chat.model.pending_notification_thread_id;
            self.chat.model.pending_notification_thread_id = 0;
            if (self.chat.model.threadByIdConst(thread_id)) |thread| {
                runtime.showNotification(.{
                    .title = "Response ready",
                    .subtitle = "Superchat",
                    .body = thread.title(),
                }) catch {};
            }
        }
        if (self.chat.model.open_update_requested) {
            self.chat.model.open_update_requested = false;
            runtime.openExternalUrl(self.chat.model.update_url_storage[0..self.chat.model.update_url_len]) catch {
                self.chat.model.setStatus("Could not open the GitHub release page");
                if (self.chat.installed) try self.chat.rebuild(runtime, self.chat.canvas_window_id);
            };
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
        if (self.chat.model.snippets_dirty) {
            var set = persistence.SnippetSet{};
            set.count = self.chat.model.snippet_count;
            for (self.chat.model.snippets[0..self.chat.model.snippet_count], 0..) |*snippet, index| set.snippets[index] = persistence.SnippetRecord.from(snippet);
            if (self.persistence_worker.enqueueSnippets(set)) self.chat.model.snippets_dirty = false;
        }
        if (self.chat.model.mcp_servers_dirty) {
            var set = persistence.McpServerSet{};
            set.count = self.chat.model.mcp_server_count;
            for (self.chat.model.mcp_servers[0..self.chat.model.mcp_server_count], 0..) |*server, index| {
                set.servers[index] = persistence.McpServerRecord.from(server);
            }
            if (self.persistence_worker.enqueueMcpServers(set)) self.chat.model.mcp_servers_dirty = false;
        }
        const action = self.chat.model.credential_action;
        self.chat.model.credential_action = .none;
        if (!usesPersistentCredentialStore(self.chat.model.dev_mode)) {
            if (action == .save) {
                self.chat.model.setStatus("Key is active for this development session");
                if (self.chat.installed) try self.chat.rebuild(runtime, self.chat.canvas_window_id);
            }
        } else switch (action) {
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
            self.chat.model.search_loading = false;
            self.chat.model.search_request_pending = false;
            for (self.chat.model.threads[0..self.chat.model.thread_count]) |*thread| thread.history_loading = false;
            self.chat.model.setStatus("The local database stopped responding");
            if (self.chat.installed) try self.chat.rebuild(runtime, self.chat.canvas_window_id);
        }
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *SecureChatApp = @ptrCast(@alignCast(context));
        for (self.chat.model.threads[0..self.chat.model.thread_count]) |*thread| {
            if (thread.stream_pending_len > 0) {
                _ = thread.flushStreamDelta(self.chat.model.allocator, &self.chat.model.next_message_id);
                markLatestAssistantDirty(&self.chat.model, thread.id);
            } else {
                self.chat.model.markThreadDirty(thread.id);
            }
        }
        self.chat.model.markMetaDirty();
        self.flushPersistence();
        self.persistence_worker.stopAndDestroy();
        try self.inner.stop(runtime);
    }

    fn enqueueDirtyMessages(self: *SecureChatApp, model: *const Model) void {
        for (model.persistence_messages[0..model.persistence_message_count]) |dirty| {
            const thread = model.threadByIdConst(dirty.thread_id) orelse continue;
            for (thread.messages[0..thread.message_count]) |message| {
                if (message.id != dirty.message_id) continue;
                _ = self.persistence_worker.enqueueMessage(persistence.MessageRecord.from(thread.id, &message));
                break;
            }
        }
    }

    fn flushPersistence(self: *SecureChatApp) void {
        const model = &self.chat.model;
        var required: usize = 0;
        if (model.persistence_structure_dirty) {
            required = model.persistence_truncate_count + model.project_count + model.thread_count + model.persistence_message_count + 2;
        } else {
            required = model.persistence_truncate_count + model.persistence_clear_thread_count + model.persistence_thread_count + model.persistence_message_count + @intFromBool(model.persistence_meta_dirty);
        }
        if (required == 0 or !self.persistence_worker.canEnqueue(required)) return;

        for (0..model.persistence_truncate_count) |index| {
            const truncation = model.persistence_truncations[index];
            _ = self.persistence_worker.enqueue(.{ .truncate_messages = .{
                .thread_id = truncation.thread_id,
                .from_message_id = truncation.from_message_id,
            } });
        }

        if (model.persistence_structure_dirty) {
            for (model.projects[0..model.project_count], 0..) |project, position| {
                _ = self.persistence_worker.enqueue(.{ .upsert_project = persistence.ProjectRecord.from(&project, position) });
            }
            for (model.threads[0..model.thread_count], 0..) |thread, position| {
                _ = self.persistence_worker.enqueueThread(persistence.ThreadRecord.from(&thread, position));
            }
            self.enqueueDirtyMessages(model);
            var reconcile = persistence.ReconcileRecord{};
            for (model.projects[0..model.project_count]) |project| {
                reconcile.project_ids[reconcile.project_count] = project.id;
                reconcile.project_count += 1;
            }
            for (model.threads[0..model.thread_count]) |thread| {
                reconcile.thread_ids[reconcile.thread_count] = thread.id;
                reconcile.thread_count += 1;
            }
            _ = self.persistence_worker.enqueueReconcile(reconcile);
        } else {
            for (model.persistence_clear_thread_ids[0..model.persistence_clear_thread_count]) |thread_id| {
                _ = self.persistence_worker.enqueue(.{ .clear_messages = thread_id });
            }
            for (model.persistence_thread_ids[0..model.persistence_thread_count]) |thread_id| {
                for (model.threads[0..model.thread_count], 0..) |thread, position| {
                    if (thread.id != thread_id) continue;
                    _ = self.persistence_worker.enqueueThread(persistence.ThreadRecord.from(&thread, position));
                    break;
                }
            }
            self.enqueueDirtyMessages(model);
        }
        if (model.persistence_meta_dirty) {
            _ = self.persistence_worker.enqueue(.{ .meta = .{
                .active_project_id = model.active_project_id,
                .active_thread_id = model.active_thread_id,
                .next_project_id = model.next_project_id,
                .next_thread_id = model.next_thread_id,
                .next_message_id = model.next_message_id,
                .notifications_enabled = model.notifications_enabled,
            } });
        }
        model.persistence_structure_dirty = false;
        model.persistence_meta_dirty = false;
        model.persistence_thread_count = 0;
        model.persistence_message_count = 0;
        model.persistence_clear_thread_count = 0;
        model.persistence_truncate_count = 0;
    }
};

// -------------------------------------------------------------------- app

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--mcp-helper")) {
        const mode = std.meta.stringToEnum(mcp.HelperMode, args[2]) orelse return error.InvalidArguments;
        var input: [native_sdk.max_effect_stdin_bytes]u8 = undefined;
        var input_len: usize = 0;
        while (input_len < input.len) {
            const slices: [1][]u8 = .{input[input_len..]};
            const count = std.Io.File.stdin().readStreaming(init.io, &slices) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (count == 0) break;
            input_len += count;
        }
        var output: std.Io.Writer.Allocating = .init(init.arena.allocator());
        try mcp.runHelper(init.io, init.arena.allocator(), mode, input[0..input_len], &output.writer);
        try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
        return;
    }
    const api_key = init.environ_map.get("OPENROUTER_API_KEY") orelse "";
    const dev_mode_value = init.environ_map.get("SUPERCHAT_DEV_MODE") orelse "";
    const dev_mode = builtin.mode == .Debug or std.mem.eql(u8, dev_mode_value, "1") or std.ascii.eqlIgnoreCase(dev_mode_value, "true");
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
        .init_fx = initEffects,
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
    var executable_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_path_len = try std.process.executablePath(init.io, &executable_path_buffer);
    app_state.model.setExecutablePath(executable_path_buffer[0..executable_path_len]);
    const persistence_worker = try persistence.Worker.create(std.heap.page_allocator, database, init.io);
    database_owned = false;
    var secure_app = SecureChatApp{ .inner = app_state.app(), .chat = app_state, .persistence_worker = persistence_worker };

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
            .navigation = .{
                .allowed_origins = &.{ "zero://inline", "zero://app" },
                .external_links = .{ .action = .open_system_browser, .allowed_urls = &allowed_external_urls },
            },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
