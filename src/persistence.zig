const std = @import("std");
const storage = @import("storage.zig");
const mcp = @import("mcp.zig");

pub const max_project_name_bytes = 48;
pub const max_project_instructions_bytes = 4000;
pub const max_project_knowledge_bytes = 48 * 1024;
pub const max_project_file_names_bytes = 512;
pub const max_thread_title_bytes = 80;
pub const max_draft_bytes = 5000;
pub const max_model_bytes = 128;
pub const max_message_bytes = 64 * 1024;
pub const max_attachments_per_message = 4;
pub const max_attachment_path_bytes = 1024;
pub const max_attachment_name_bytes = 128;
pub const max_projects = 4096;
pub const max_threads = 4096;
pub const max_visible_messages = 50;
pub const max_search_query_bytes = 160;
pub const max_snippets = 16;
pub const max_snippet_name_bytes = 32;
pub const max_snippet_body_bytes = 1200;
const queue_capacity = 512;

pub const ProjectRecord = struct {
    id: u32,
    name: [max_project_name_bytes]u8 = undefined,
    name_len: usize = 0,
    instructions: [max_project_instructions_bytes]u8 = undefined,
    instructions_len: usize = 0,
    knowledge: [max_project_knowledge_bytes]u8 = undefined,
    knowledge_len: usize = 0,
    file_names: [max_project_file_names_bytes]u8 = undefined,
    file_names_len: usize = 0,
    archived_at_ms: i64,
    position: usize,

    pub fn from(project: anytype, position: usize) ProjectRecord {
        var record = ProjectRecord{ .id = project.id, .archived_at_ms = project.archived_at_ms, .position = position };
        record.name_len = copyText(&record.name, project.name());
        record.instructions_len = copyText(&record.instructions, project.instructions());
        record.knowledge_len = copyText(&record.knowledge, project.knowledge());
        record.file_names_len = copyText(&record.file_names, project.fileNames());
        return record;
    }
};

pub const ThreadRecord = struct {
    id: u32,
    project_id: u32,
    title: [max_thread_title_bytes]u8 = undefined,
    title_len: usize = 0,
    archived_at_ms: i64,
    position: usize,
    draft: [max_draft_bytes]u8 = undefined,
    draft_len: usize = 0,
    model_choice: u8,
    model_slug: [max_model_bytes]u8 = undefined,
    model_slug_len: usize = 0,
    active_model: [max_model_bytes]u8 = undefined,
    active_model_len: usize = 0,
    attachments: [max_attachments_per_message]AttachmentRecord = [_]AttachmentRecord{.{}} ** max_attachments_per_message,
    attachment_count: usize = 0,

    pub fn from(thread: anytype, position: usize) ThreadRecord {
        var record = ThreadRecord{
            .id = thread.id,
            .project_id = thread.project_id,
            .archived_at_ms = thread.archived_at_ms,
            .position = position,
            .model_choice = @intFromEnum(thread.model_choice),
        };
        record.title_len = copyText(&record.title, thread.title());
        record.draft_len = copyText(&record.draft, thread.draft());
        record.model_slug_len = copyText(&record.model_slug, thread.modelName());
        record.active_model_len = copyText(&record.active_model, thread.active_model_storage[0..thread.active_model_len]);
        record.attachment_count = thread.draft_attachment_count;
        for (thread.draft_attachments[0..thread.draft_attachment_count], 0..) |*attachment, index| record.attachments[index] = AttachmentRecord.from(attachment);
        return record;
    }
};

pub const AttachmentRecord = struct {
    kind: u8 = 0,
    path: [max_attachment_path_bytes]u8 = undefined,
    path_len: usize = 0,
    name: [max_attachment_name_bytes]u8 = undefined,
    name_len: usize = 0,

    pub fn from(attachment: anytype) AttachmentRecord {
        var record = AttachmentRecord{ .kind = @intFromEnum(attachment.kind) };
        record.path_len = copyText(&record.path, attachment.path());
        record.name_len = copyText(&record.name, attachment.name());
        return record;
    }
};

pub const MessageRecord = struct {
    id: u32,
    thread_id: u32,
    role: u8,
    content: [max_message_bytes]u8 = undefined,
    content_len: usize = 0,
    response_model: [max_model_bytes]u8 = undefined,
    response_model_len: usize = 0,
    latency_ms: u32 = 0,
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    cost_micros: u64 = 0,
    attachments: [max_attachments_per_message]AttachmentRecord = [_]AttachmentRecord{.{}} ** max_attachments_per_message,
    attachment_count: usize = 0,

    pub fn from(thread_id: u32, message: anytype) MessageRecord {
        var record = MessageRecord{ .id = message.id, .thread_id = thread_id, .role = @intFromEnum(message.role) };
        record.content_len = copyText(&record.content, message.content());
        record.response_model_len = copyText(&record.response_model, message.responseModel());
        record.latency_ms = message.latency_ms;
        record.prompt_tokens = message.prompt_tokens;
        record.completion_tokens = message.completion_tokens;
        record.cost_micros = message.cost_micros;
        record.attachment_count = message.attachment_count;
        for (message.attachments[0..message.attachment_count], 0..) |*attachment, index| record.attachments[index] = AttachmentRecord.from(attachment);
        return record;
    }
};

pub const SnippetRecord = struct {
    id: u32 = 0,
    name_storage: [max_snippet_name_bytes]u8 = undefined,
    name_len: usize = 0,
    body_storage: [max_snippet_body_bytes]u8 = undefined,
    body_len: usize = 0,

    pub fn from(snippet: anytype) SnippetRecord {
        var record = SnippetRecord{ .id = snippet.id };
        record.name_len = copyText(&record.name_storage, snippet.name());
        record.body_len = copyText(&record.body_storage, snippet.body());
        return record;
    }

    pub fn name(record: *const SnippetRecord) []const u8 {
        return record.name_storage[0..record.name_len];
    }

    pub fn body(record: *const SnippetRecord) []const u8 {
        return record.body_storage[0..record.body_len];
    }
};

pub const SnippetSet = struct {
    snippets: [max_snippets]SnippetRecord = undefined,
    count: usize = 0,
};

pub const McpServerRecord = struct {
    id: u32 = 0,
    name_storage: [mcp.max_server_name_bytes]u8 = undefined,
    name_len: usize = 0,
    command_storage: [mcp.max_command_bytes]u8 = undefined,
    command_len: usize = 0,
    enabled: bool = true,

    pub fn from(server: anytype) McpServerRecord {
        var record = McpServerRecord{ .id = server.id, .enabled = server.enabled };
        record.name_len = copyText(&record.name_storage, server.name());
        record.command_len = copyText(&record.command_storage, server.command());
        return record;
    }

    pub fn name(record: *const McpServerRecord) []const u8 {
        return record.name_storage[0..record.name_len];
    }

    pub fn command(record: *const McpServerRecord) []const u8 {
        return record.command_storage[0..record.command_len];
    }
};

pub const McpServerSet = struct {
    servers: [mcp.max_servers]McpServerRecord = undefined,
    count: usize = 0,
};

pub const ExportKind = enum { thread_markdown, workspace_json };

pub const ExportRecord = struct {
    kind: ExportKind,
    thread_id: u32 = 0,
    path: [1024]u8 = undefined,
    path_len: usize = 0,
};

pub const MetaRecord = struct {
    active_project_id: u32,
    active_thread_id: u32,
    next_project_id: u32,
    next_thread_id: u32,
    next_message_id: u32,
    notifications_enabled: bool,
};

pub const CachedModelRecord = struct {
    slug: [max_model_bytes]u8 = undefined,
    slug_len: usize = 0,
    label: [96]u8 = undefined,
    label_len: usize = 0,
    favorite: bool,
    updated_at_ms: i64,

    pub fn from(entry: anytype, updated_at_ms: i64) CachedModelRecord {
        var record = CachedModelRecord{ .favorite = entry.favorite, .updated_at_ms = updated_at_ms };
        record.slug_len = copyText(&record.slug, entry.slug());
        record.label_len = copyText(&record.label, entry.label());
        return record;
    }
};

pub const ReconcileRecord = struct {
    project_ids: [max_projects]u32 = undefined,
    project_count: usize = 0,
    thread_ids: [max_threads]u32 = undefined,
    thread_count: usize = 0,
};

pub const TruncateMessages = struct {
    thread_id: u32,
    from_message_id: u32,
};

pub const SearchRequest = struct {
    generation: u32,
    query: [max_search_query_bytes]u8 = undefined,
    query_len: usize,
    limit: usize,
};

pub const Command = union(enum) {
    upsert_project: *ProjectRecord,
    upsert_thread: *ThreadRecord,
    upsert_message: *MessageRecord,
    clear_messages: u32,
    truncate_messages: TruncateMessages,
    reconcile: *ReconcileRecord,
    meta: MetaRecord,
    purge_expired: i64,
    load_history: struct { thread_id: u32, before_id: u32, limit: usize },
    search: SearchRequest,
    upsert_cached_model: CachedModelRecord,
    save_snippets: *SnippetSet,
    save_mcp_servers: *McpServerSet,
    export_file: *ExportRecord,
};

pub const HistoryResult = struct {
    thread_id: u32,
    page: storage.HistoryPage,
};

pub const SearchResult = struct {
    generation: u32,
    page: storage.SearchPage,
};

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(mutex: *SpinMutex) void {
        while (!mutex.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(mutex: *SpinMutex) void {
        mutex.inner.unlock();
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    database: storage.Database,
    io: std.Io,
    queue: [queue_capacity]Command = undefined,
    head: usize = 0,
    count: usize = 0,
    mutex: SpinMutex = .{},
    stopping: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    wake: std.Io.Event = .unset,
    thread: ?std.Thread = null,
    history_result: ?HistoryResult = null,
    search_result: ?SearchResult = null,
    export_result: ?bool = null,

    pub fn create(allocator: std.mem.Allocator, database: storage.Database, io: std.Io) !*Worker {
        const worker = try allocator.create(Worker);
        errdefer allocator.destroy(worker);
        worker.* = .{ .allocator = allocator, .database = database, .io = io };
        worker.thread = try std.Thread.spawn(.{}, run, .{worker});
        return worker;
    }

    pub fn enqueue(worker: *Worker, command: Command) bool {
        worker.mutex.lock();
        defer worker.mutex.unlock();
        if (worker.count == queue_capacity) return false;
        worker.queue[(worker.head + worker.count) % queue_capacity] = command;
        worker.count += 1;
        worker.wake.set(worker.io);
        return true;
    }

    pub fn enqueueMessage(worker: *Worker, record: MessageRecord) bool {
        return worker.enqueueOwned(record, .upsert_message);
    }

    pub fn enqueueProject(worker: *Worker, record: ProjectRecord) bool {
        return worker.enqueueOwned(record, .upsert_project);
    }

    pub fn enqueueThread(worker: *Worker, record: ThreadRecord) bool {
        return worker.enqueueOwned(record, .upsert_thread);
    }

    pub fn enqueueReconcile(worker: *Worker, record: ReconcileRecord) bool {
        return worker.enqueueOwned(record, .reconcile);
    }

    pub fn enqueueSnippets(worker: *Worker, record: SnippetSet) bool {
        return worker.enqueueOwned(record, .save_snippets);
    }

    pub fn enqueueMcpServers(worker: *Worker, record: McpServerSet) bool {
        return worker.enqueueOwned(record, .save_mcp_servers);
    }

    pub fn enqueueExport(worker: *Worker, record: ExportRecord) bool {
        return worker.enqueueOwned(record, .export_file);
    }

    fn enqueueOwned(worker: *Worker, record: anytype, comptime tag: std.meta.Tag(Command)) bool {
        const Record = @TypeOf(record);
        const owned = worker.allocator.create(Record) catch {
            worker.failed.store(true, .release);
            return false;
        };
        owned.* = record;
        if (worker.enqueue(@unionInit(Command, @tagName(tag), owned))) return true;
        worker.allocator.destroy(owned);
        return false;
    }

    pub fn canEnqueue(worker: *Worker, command_count: usize) bool {
        worker.mutex.lock();
        defer worker.mutex.unlock();
        return command_count <= queue_capacity - worker.count;
    }

    pub fn hasFailed(worker: *const Worker) bool {
        return worker.failed.load(.acquire);
    }

    pub fn takeHistoryResult(worker: *Worker) ?HistoryResult {
        worker.mutex.lock();
        defer worker.mutex.unlock();
        const result = worker.history_result;
        worker.history_result = null;
        return result;
    }

    pub fn takeSearchResult(worker: *Worker) ?SearchResult {
        worker.mutex.lock();
        defer worker.mutex.unlock();
        const result = worker.search_result;
        worker.search_result = null;
        return result;
    }

    pub fn takeExportResult(worker: *Worker) ?bool {
        worker.mutex.lock();
        defer worker.mutex.unlock();
        const result = worker.export_result;
        worker.export_result = null;
        return result;
    }

    pub fn stopAndDestroy(worker: *Worker) void {
        worker.stopping.store(true, .release);
        worker.wake.set(worker.io);
        if (worker.thread) |thread| thread.join();
        if (worker.history_result) |*result| result.page.deinit(worker.allocator);
        if (worker.search_result) |*result| result.page.deinit(worker.allocator);
        worker.database.close();
        const allocator = worker.allocator;
        allocator.destroy(worker);
    }

    fn pop(worker: *Worker) ?Command {
        worker.mutex.lock();
        defer worker.mutex.unlock();
        if (worker.count == 0) return null;
        const command = worker.queue[worker.head];
        worker.head = (worker.head + 1) % queue_capacity;
        worker.count -= 1;
        return command;
    }

    fn isEmpty(worker: *Worker) bool {
        worker.mutex.lock();
        defer worker.mutex.unlock();
        return worker.count == 0;
    }

    fn run(worker: *Worker) void {
        while (!worker.stopping.load(.acquire) or !worker.isEmpty()) {
            const first = worker.pop() orelse blk: {
                worker.wake.reset();
                if (worker.pop()) |command| break :blk command;
                if (worker.stopping.load(.acquire)) break;
                worker.wake.waitUncancelable(worker.io);
                continue;
            };
            if (isReadCommand(first)) {
                worker.apply(first) catch worker.failed.store(true, .release);
                continue;
            }
            worker.database.begin() catch {
                worker.deinitCommand(first);
                worker.failed.store(true, .release);
                continue;
            };
            var batch_failed = false;
            worker.apply(first) catch {
                batch_failed = true;
            };
            while (!batch_failed) {
                const command = worker.pop() orelse break;
                worker.apply(command) catch {
                    batch_failed = true;
                };
            }
            if (batch_failed) {
                worker.database.rollback();
                worker.failed.store(true, .release);
            } else {
                worker.database.commit() catch {
                    worker.database.rollback();
                    worker.failed.store(true, .release);
                };
            }
        }
    }

    fn apply(worker: *Worker, command: Command) !void {
        switch (command) {
            .upsert_project => |record| {
                defer worker.allocator.destroy(record);
                try worker.database.upsertProject(record.id, record.name[0..record.name_len], record.instructions[0..record.instructions_len], record.knowledge[0..record.knowledge_len], record.file_names[0..record.file_names_len], record.archived_at_ms, record.position);
            },
            .upsert_thread => |record| {
                defer worker.allocator.destroy(record);
                try worker.database.upsertThread(
                    record.id,
                    record.project_id,
                    record.title[0..record.title_len],
                    record.archived_at_ms,
                    record.position,
                    record.draft[0..record.draft_len],
                    record.model_choice,
                    record.model_slug[0..record.model_slug_len],
                    record.active_model[0..record.active_model_len],
                );
                try worker.database.replaceAttachments(record.id, 0, record.attachments[0..record.attachment_count]);
            },
            .upsert_message => |record| {
                defer worker.allocator.destroy(record);
                try worker.database.upsertMessageWithMetrics(record.id, record.thread_id, record.role, record.content[0..record.content_len], record.response_model[0..record.response_model_len], record.latency_ms, record.prompt_tokens, record.completion_tokens, record.cost_micros);
                try worker.database.replaceAttachments(record.thread_id, record.id, record.attachments[0..record.attachment_count]);
            },
            .clear_messages => |thread_id| try worker.database.clearMessages(thread_id),
            .truncate_messages => |request| try worker.database.truncateMessages(request.thread_id, request.from_message_id),
            .reconcile => |record| {
                defer worker.allocator.destroy(record);
                try worker.database.reconcile(record.project_ids[0..record.project_count], record.thread_ids[0..record.thread_count]);
            },
            .meta => |record| {
                try worker.database.saveMeta(record.active_project_id, record.active_thread_id, record.next_project_id, record.next_thread_id, record.next_message_id);
                try worker.database.savePreferences(record.notifications_enabled);
            },
            .purge_expired => |cutoff_ms| try worker.database.purgeExpired(cutoff_ms),
            .load_history => |request| {
                const page = try worker.database.loadHistoryBefore(worker.allocator, request.thread_id, request.before_id, request.limit);
                worker.mutex.lock();
                defer worker.mutex.unlock();
                if (worker.history_result) |*previous| previous.page.deinit(worker.allocator);
                worker.history_result = .{ .thread_id = request.thread_id, .page = page };
            },
            .search => |request| {
                const page = try worker.database.search(worker.allocator, request.query[0..request.query_len], request.limit);
                worker.mutex.lock();
                defer worker.mutex.unlock();
                if (worker.search_result) |*previous| previous.page.deinit(worker.allocator);
                worker.search_result = .{ .generation = request.generation, .page = page };
            },
            .upsert_cached_model => |record| try worker.database.upsertCachedModel(
                record.slug[0..record.slug_len],
                record.label[0..record.label_len],
                record.favorite,
                record.updated_at_ms,
            ),
            .save_snippets => |record| {
                defer worker.allocator.destroy(record);
                try worker.database.replaceSnippets(record.snippets[0..record.count]);
            },
            .save_mcp_servers => |record| {
                defer worker.allocator.destroy(record);
                try worker.database.replaceMcpServers(record.servers[0..record.count]);
            },
            .export_file => |record| {
                defer worker.allocator.destroy(record);
                const success = blk: {
                    const path = record.path[0..record.path_len];
                    switch (record.kind) {
                        .thread_markdown => worker.database.exportThreadMarkdown(worker.allocator, worker.io, record.thread_id, path) catch break :blk false,
                        .workspace_json => worker.database.exportWorkspaceJson(worker.allocator, worker.io, path) catch break :blk false,
                    }
                    break :blk true;
                };
                worker.mutex.lock();
                defer worker.mutex.unlock();
                worker.export_result = success;
            },
        }
    }

    fn deinitCommand(worker: *Worker, command: Command) void {
        switch (command) {
            .upsert_project => |record| worker.allocator.destroy(record),
            .upsert_thread => |record| worker.allocator.destroy(record),
            .upsert_message => |record| worker.allocator.destroy(record),
            .reconcile => |record| worker.allocator.destroy(record),
            .save_snippets => |record| worker.allocator.destroy(record),
            .save_mcp_servers => |record| worker.allocator.destroy(record),
            .export_file => |record| worker.allocator.destroy(record),
            else => {},
        }
    }
};

fn isReadCommand(command: Command) bool {
    return switch (command) {
        .load_history, .search, .export_file => true,
        else => false,
    };
}

fn copyText(destination: []u8, source: []const u8) usize {
    const len = @min(destination.len, source.len);
    @memcpy(destination[0..len], source[0..len]);
    return len;
}
