const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    OpenFailed,
    SqlFailed,
    InvalidData,
    PathTooLong,
};

pub const Database = struct {
    handle: *c.sqlite3,

    pub fn open(path: []const u8) Error!Database {
        if (path.len >= 1024) return error.PathTooLong;
        var path_z: [1024:0]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(&path_z, &handle, flags, null) != c.SQLITE_OK or handle == null) {
            if (handle) |opened| _ = c.sqlite3_close(opened);
            return error.OpenFailed;
        }
        var database = Database{ .handle = handle.? };
        errdefer database.close();
        try database.configure();
        try database.migrate();
        return database;
    }

    pub fn close(database: *Database) void {
        _ = c.sqlite3_close(database.handle);
    }

    fn configure(database: *Database) Error!void {
        _ = c.sqlite3_busy_timeout(database.handle, 2500);
        try database.exec("PRAGMA foreign_keys = ON;");
        try database.exec("PRAGMA journal_mode = WAL;");
        try database.exec("PRAGMA synchronous = NORMAL;");
    }

    fn migrate(database: *Database) Error!void {
        try database.exec(
            \\BEGIN IMMEDIATE;
            \\CREATE TABLE IF NOT EXISTS projects (
            \\  id INTEGER PRIMARY KEY,
            \\  name TEXT NOT NULL,
            \\  archived_at_ms INTEGER NOT NULL DEFAULT 0,
            \\  position INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS threads (
            \\  id INTEGER PRIMARY KEY,
            \\  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            \\  title TEXT NOT NULL,
            \\  archived_at_ms INTEGER NOT NULL DEFAULT 0,
            \\  position INTEGER NOT NULL,
            \\  draft TEXT NOT NULL DEFAULT '',
            \\  model_choice INTEGER NOT NULL DEFAULT 0,
            \\  model_slug TEXT NOT NULL DEFAULT 'openrouter/auto',
            \\  active_model TEXT NOT NULL DEFAULT ''
            \\);
            \\CREATE TABLE IF NOT EXISTS messages (
            \\  id INTEGER PRIMARY KEY,
            \\  thread_id INTEGER NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
            \\  role INTEGER NOT NULL,
            \\  content TEXT NOT NULL,
            \\  position INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS workspace_meta (
            \\  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            \\  active_project_id INTEGER NOT NULL,
            \\  active_thread_id INTEGER NOT NULL,
            \\  next_project_id INTEGER NOT NULL,
            \\  next_thread_id INTEGER NOT NULL,
            \\  next_message_id INTEGER NOT NULL
            \\);
            \\PRAGMA user_version = 1;
            \\COMMIT;
        );
    }

    pub fn schemaVersion(database: *Database) Error!i64 {
        const statement = try database.prepare("PRAGMA user_version;");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.SqlFailed;
        return c.sqlite3_column_int64(statement, 0);
    }

    pub fn purgeExpired(database: *Database, cutoff_ms: i64) Error!void {
        const projects = try database.prepare("DELETE FROM projects WHERE archived_at_ms > 0 AND archived_at_ms <= ?1;");
        defer _ = c.sqlite3_finalize(projects);
        try bindInt(projects, 1, cutoff_ms);
        try stepDone(projects);

        const threads = try database.prepare("DELETE FROM threads WHERE archived_at_ms > 0 AND archived_at_ms <= ?1;");
        defer _ = c.sqlite3_finalize(threads);
        try bindInt(threads, 1, cutoff_ms);
        try stepDone(threads);
    }

    pub fn save(database: *Database, model: anytype) Error!void {
        try database.exec("BEGIN IMMEDIATE;");
        errdefer database.exec("ROLLBACK;") catch {};
        try database.exec("DELETE FROM messages; DELETE FROM threads; DELETE FROM projects; DELETE FROM workspace_meta;");

        const project_statement = try database.prepare("INSERT INTO projects(id,name,archived_at_ms,position) VALUES(?1,?2,?3,?4);");
        defer _ = c.sqlite3_finalize(project_statement);
        for (model.projects[0..model.project_count], 0..) |*project, position| {
            try bindInt(project_statement, 1, project.id);
            try bindText(project_statement, 2, project.name());
            try bindInt(project_statement, 3, project.archived_at_ms);
            try bindInt(project_statement, 4, position);
            try stepDone(project_statement);
            reset(project_statement);
        }

        const thread_statement = try database.prepare("INSERT INTO threads(id,project_id,title,archived_at_ms,position,draft,model_choice,model_slug,active_model) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9);");
        defer _ = c.sqlite3_finalize(thread_statement);
        for (model.threads[0..model.thread_count], 0..) |*thread, position| {
            try bindInt(thread_statement, 1, thread.id);
            try bindInt(thread_statement, 2, thread.project_id);
            try bindText(thread_statement, 3, thread.title());
            try bindInt(thread_statement, 4, thread.archived_at_ms);
            try bindInt(thread_statement, 5, position);
            try bindText(thread_statement, 6, thread.draft());
            try bindInt(thread_statement, 7, @intFromEnum(thread.model_choice));
            try bindText(thread_statement, 8, thread.modelName());
            try bindText(thread_statement, 9, thread.active_model_storage[0..thread.active_model_len]);
            try stepDone(thread_statement);
            reset(thread_statement);
        }

        const message_statement = try database.prepare("INSERT INTO messages(id,thread_id,role,content,position) VALUES(?1,?2,?3,?4,?5);");
        defer _ = c.sqlite3_finalize(message_statement);
        for (model.threads[0..model.thread_count]) |*thread| {
            for (thread.messages[0..thread.message_count], 0..) |*message, position| {
                try bindInt(message_statement, 1, message.id);
                try bindInt(message_statement, 2, thread.id);
                try bindInt(message_statement, 3, @intFromEnum(message.role));
                try bindText(message_statement, 4, message.content());
                try bindInt(message_statement, 5, position);
                try stepDone(message_statement);
                reset(message_statement);
            }
        }

        const meta = try database.prepare("INSERT INTO workspace_meta VALUES(1,?1,?2,?3,?4,?5);");
        defer _ = c.sqlite3_finalize(meta);
        try bindInt(meta, 1, model.active_project_id);
        try bindInt(meta, 2, model.active_thread_id);
        try bindInt(meta, 3, model.next_project_id);
        try bindInt(meta, 4, model.next_thread_id);
        try bindInt(meta, 5, model.next_message_id);
        try stepDone(meta);
        try database.exec("COMMIT;");
    }

    pub fn load(database: *Database, model: anytype) Error!bool {
        model.project_count = 0;
        model.thread_count = 0;

        const projects = try database.prepare("SELECT id,name,archived_at_ms FROM projects ORDER BY position,id;");
        defer _ = c.sqlite3_finalize(projects);
        while (true) {
            const result = c.sqlite3_step(projects);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            if (model.project_count == model.projects.len) return error.InvalidData;
            var project: @TypeOf(model.projects[0]) = .{ .id = intColumn(u32, projects, 0) };
            setFixed(&project.name_storage, &project.name_len, textColumn(projects, 1));
            project.archived_at_ms = c.sqlite3_column_int64(projects, 2);
            model.projects[model.project_count] = project;
            model.project_count += 1;
        }
        if (model.project_count == 0) return false;

        const threads = try database.prepare("SELECT id,project_id,title,archived_at_ms,draft,model_choice,model_slug,active_model FROM threads ORDER BY position,id;");
        defer _ = c.sqlite3_finalize(threads);
        while (true) {
            const result = c.sqlite3_step(threads);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            if (model.thread_count == model.threads.len) return error.InvalidData;
            var thread: @TypeOf(model.threads[0]) = .{
                .id = intColumn(u32, threads, 0),
                .project_id = intColumn(u32, threads, 1),
            };
            setFixed(&thread.title_storage, &thread.title_len, textColumn(threads, 2));
            thread.archived_at_ms = c.sqlite3_column_int64(threads, 3);
            thread.draft_buffer.set(textColumn(threads, 4));
            const choice_value = intColumn(u8, threads, 5);
            if (choice_value >= std.meta.fields(@TypeOf(thread.model_choice)).len) return error.InvalidData;
            thread.model_choice = @enumFromInt(choice_value);
            thread.model_buffer.set(textColumn(threads, 6));
            setFixed(&thread.active_model_storage, &thread.active_model_len, textColumn(threads, 7));
            model.threads[model.thread_count] = thread;
            model.thread_count += 1;
        }

        const messages = try database.prepare("SELECT id,thread_id,role,content FROM messages ORDER BY thread_id,position,id;");
        defer _ = c.sqlite3_finalize(messages);
        while (true) {
            const result = c.sqlite3_step(messages);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            const thread_id = intColumn(u32, messages, 1);
            var target: ?*@TypeOf(model.threads[0]) = null;
            for (model.threads[0..model.thread_count]) |*thread| {
                if (thread.id == thread_id) target = thread;
            }
            const thread = target orelse return error.InvalidData;
            if (thread.message_count == thread.messages.len) return error.InvalidData;
            const role_value = intColumn(u8, messages, 2);
            if (role_value >= std.meta.fields(@TypeOf(thread.messages[0].role)).len) return error.InvalidData;
            var message: @TypeOf(thread.messages[0]) = .{
                .id = intColumn(u32, messages, 0),
                .role = @enumFromInt(role_value),
            };
            setFixed(&message.content_storage, &message.content_len, textColumn(messages, 3));
            thread.messages[thread.message_count] = message;
            thread.message_count += 1;
        }

        const meta = try database.prepare("SELECT active_project_id,active_thread_id,next_project_id,next_thread_id,next_message_id FROM workspace_meta WHERE singleton=1;");
        defer _ = c.sqlite3_finalize(meta);
        if (c.sqlite3_step(meta) == c.SQLITE_ROW) {
            model.active_project_id = intColumn(u32, meta, 0);
            model.active_thread_id = intColumn(u32, meta, 1);
            model.next_project_id = intColumn(u32, meta, 2);
            model.next_thread_id = intColumn(u32, meta, 3);
            model.next_message_id = intColumn(u32, meta, 4);
        }
        return true;
    }

    fn exec(database: *Database, sql: [*:0]const u8) Error!void {
        var message: [*c]u8 = null;
        if (c.sqlite3_exec(database.handle, sql, null, null, &message) != c.SQLITE_OK) {
            if (message != null) c.sqlite3_free(message);
            return error.SqlFailed;
        }
    }

    fn prepare(database: *Database, sql: [*:0]const u8) Error!*c.sqlite3_stmt {
        var statement: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(database.handle, sql, -1, &statement, null) != c.SQLITE_OK or statement == null) return error.SqlFailed;
        return statement.?;
    }
};

fn bindInt(statement: *c.sqlite3_stmt, index: c_int, value: anytype) Error!void {
    if (c.sqlite3_bind_int64(statement, index, @intCast(value)) != c.SQLITE_OK) return error.SqlFailed;
}

fn bindText(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) Error!void {
    if (c.sqlite3_bind_text(statement, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) return error.SqlFailed;
}

fn stepDone(statement: *c.sqlite3_stmt) Error!void {
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.SqlFailed;
}

fn reset(statement: *c.sqlite3_stmt) void {
    _ = c.sqlite3_reset(statement);
    _ = c.sqlite3_clear_bindings(statement);
}

fn textColumn(statement: *c.sqlite3_stmt, column: c_int) []const u8 {
    const pointer = c.sqlite3_column_text(statement, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(statement, column));
    return pointer[0..len];
}

fn intColumn(comptime T: type, statement: *c.sqlite3_stmt, column: c_int) T {
    return @intCast(c.sqlite3_column_int64(statement, column));
}

fn setFixed(storage: anytype, len: *usize, value: []const u8) void {
    var copy_len = @min(storage.len, value.len);
    if (copy_len < value.len) {
        while (copy_len > 0 and value[copy_len] & 0xc0 == 0x80) copy_len -= 1;
    }
    @memcpy(storage[0..copy_len], value[0..copy_len]);
    len.* = copy_len;
}
