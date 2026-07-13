const std = @import("std");
const storage = @import("storage.zig");

pub const max_project_name_bytes = 48;
pub const max_thread_title_bytes = 80;
pub const max_draft_bytes = 5000;
pub const max_model_bytes = 128;
pub const max_message_bytes = 64 * 1024;
pub const max_projects = 4096;
pub const max_threads = 4096;
pub const max_visible_messages = 50;
const queue_capacity = 512;

pub const ProjectRecord = struct {
    id: u32,
    name: [max_project_name_bytes]u8 = undefined,
    name_len: usize = 0,
    archived_at_ms: i64,
    position: usize,

    pub fn from(project: anytype, position: usize) ProjectRecord {
        var record = ProjectRecord{ .id = project.id, .archived_at_ms = project.archived_at_ms, .position = position };
        record.name_len = copyText(&record.name, project.name());
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
        return record;
    }
};

pub const MessageRecord = struct {
    id: u32,
    thread_id: u32,
    role: u8,
    content: [max_message_bytes]u8 = undefined,
    content_len: usize = 0,

    pub fn from(thread_id: u32, message: anytype) MessageRecord {
        var record = MessageRecord{ .id = message.id, .thread_id = thread_id, .role = @intFromEnum(message.role) };
        record.content_len = copyText(&record.content, message.content());
        return record;
    }
};

pub const MetaRecord = struct {
    active_project_id: u32,
    active_thread_id: u32,
    next_project_id: u32,
    next_thread_id: u32,
    next_message_id: u32,
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

pub const Command = union(enum) {
    upsert_project: ProjectRecord,
    upsert_thread: ThreadRecord,
    upsert_message: MessageRecord,
    clear_messages: u32,
    reconcile: ReconcileRecord,
    meta: MetaRecord,
    purge_expired: i64,
    load_history: struct { thread_id: u32, before_id: u32, limit: usize },
    upsert_cached_model: CachedModelRecord,
};

pub const HistoryResult = struct {
    thread_id: u32,
    page: storage.HistoryPage,
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

    pub fn stopAndDestroy(worker: *Worker) void {
        worker.stopping.store(true, .release);
        worker.wake.set(worker.io);
        if (worker.thread) |thread| thread.join();
        if (worker.history_result) |*result| result.page.deinit(worker.allocator);
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
            worker.database.begin() catch {
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
            .upsert_project => |record| try worker.database.upsertProject(record.id, record.name[0..record.name_len], record.archived_at_ms, record.position),
            .upsert_thread => |record| try worker.database.upsertThread(
                record.id,
                record.project_id,
                record.title[0..record.title_len],
                record.archived_at_ms,
                record.position,
                record.draft[0..record.draft_len],
                record.model_choice,
                record.model_slug[0..record.model_slug_len],
                record.active_model[0..record.active_model_len],
            ),
            .upsert_message => |record| try worker.database.upsertMessage(record.id, record.thread_id, record.role, record.content[0..record.content_len]),
            .clear_messages => |thread_id| try worker.database.clearMessages(thread_id),
            .reconcile => |record| try worker.database.reconcile(record.project_ids[0..record.project_count], record.thread_ids[0..record.thread_count]),
            .meta => |record| try worker.database.saveMeta(record.active_project_id, record.active_thread_id, record.next_project_id, record.next_thread_id, record.next_message_id),
            .purge_expired => |cutoff_ms| try worker.database.purgeExpired(cutoff_ms),
            .load_history => |request| {
                const page = try worker.database.loadHistoryBefore(worker.allocator, request.thread_id, request.before_id, request.limit);
                worker.mutex.lock();
                defer worker.mutex.unlock();
                if (worker.history_result) |*previous| previous.page.deinit(worker.allocator);
                worker.history_result = .{ .thread_id = request.thread_id, .page = page };
            },
            .upsert_cached_model => |record| try worker.database.upsertCachedModel(
                record.slug[0..record.slug_len],
                record.label[0..record.label_len],
                record.favorite,
                record.updated_at_ms,
            ),
        }
    }
};

fn copyText(destination: []u8, source: []const u8) usize {
    const len = @min(destination.len, source.len);
    @memcpy(destination[0..len], source[0..len]);
    return len;
}
