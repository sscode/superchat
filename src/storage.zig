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

const max_history_attachments = 4;

pub const HistoryAttachment = struct {
    kind: u8 = 0,
    path: []u8 = @constCast(&[_]u8{}),
    name: []u8 = @constCast(&[_]u8{}),
};

pub const HistoryMessage = struct {
    id: u32,
    role: u8,
    content: []u8,
    response_model: []u8 = @constCast(&[_]u8{}),
    latency_ms: u32 = 0,
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    cost_micros: u64 = 0,
    attachments: [max_history_attachments]HistoryAttachment = [_]HistoryAttachment{.{}} ** max_history_attachments,
    attachment_count: usize = 0,
};

pub const HistoryPage = struct {
    messages: []HistoryMessage,
    has_more: bool,

    pub fn deinit(page: *HistoryPage, allocator: std.mem.Allocator) void {
        for (page.messages) |message| {
            if (message.content.len > 0) allocator.free(message.content);
            if (message.response_model.len > 0) allocator.free(message.response_model);
            for (message.attachments[0..message.attachment_count]) |attachment| {
                if (attachment.path.len > 0) allocator.free(attachment.path);
                if (attachment.name.len > 0) allocator.free(attachment.name);
            }
        }
        if (page.messages.len > 0) allocator.free(page.messages);
        page.messages = &.{};
    }
};

pub const SearchHit = struct {
    thread_id: u32,
    message_id: u32,
    title: []u8,
    snippet: []u8,
};

pub const SearchPage = struct {
    hits: []SearchHit,

    pub fn deinit(page: *SearchPage, allocator: std.mem.Allocator) void {
        for (page.hits) |hit| {
            allocator.free(hit.title);
            allocator.free(hit.snippet);
        }
        if (page.hits.len > 0) allocator.free(page.hits);
        page.hits = &.{};
    }
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
        const version = try database.schemaVersion();
        if (version > 0 and version < 5) try database.backup(path, version);
        try database.migrate(version);
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

    fn migrate(database: *Database, previous_version: i64) Error!void {
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
            \\  response_model TEXT NOT NULL DEFAULT '',
            \\  latency_ms INTEGER NOT NULL DEFAULT 0,
            \\  prompt_tokens INTEGER NOT NULL DEFAULT 0,
            \\  completion_tokens INTEGER NOT NULL DEFAULT 0,
            \\  cost_micros INTEGER NOT NULL DEFAULT 0,
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
            \\CREATE TABLE IF NOT EXISTS model_cache (
            \\  slug TEXT PRIMARY KEY,
            \\  label TEXT NOT NULL,
            \\  favorite INTEGER NOT NULL DEFAULT 0,
            \\  updated_at_ms INTEGER NOT NULL DEFAULT 0
            \\);
            \\CREATE TABLE IF NOT EXISTS app_preferences (
            \\  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            \\  notifications_enabled INTEGER NOT NULL DEFAULT 1
            \\);
            \\CREATE TABLE IF NOT EXISTS attachments (
            \\  thread_id INTEGER NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
            \\  message_id INTEGER NOT NULL DEFAULT 0,
            \\  position INTEGER NOT NULL,
            \\  kind INTEGER NOT NULL,
            \\  path TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  PRIMARY KEY(thread_id,message_id,position)
            \\);
            \\CREATE TABLE IF NOT EXISTS prompt_snippets (
            \\  id INTEGER PRIMARY KEY,
            \\  name TEXT NOT NULL UNIQUE,
            \\  body TEXT NOT NULL,
            \\  position INTEGER NOT NULL
            \\);
            \\COMMIT;
        );
        if (previous_version > 0 and previous_version < 4) {
            if (!try database.hasColumn("messages", "response_model")) try database.exec("ALTER TABLE messages ADD COLUMN response_model TEXT NOT NULL DEFAULT '';");
            if (!try database.hasColumn("messages", "latency_ms")) try database.exec("ALTER TABLE messages ADD COLUMN latency_ms INTEGER NOT NULL DEFAULT 0;");
            if (!try database.hasColumn("messages", "prompt_tokens")) try database.exec("ALTER TABLE messages ADD COLUMN prompt_tokens INTEGER NOT NULL DEFAULT 0;");
            if (!try database.hasColumn("messages", "completion_tokens")) try database.exec("ALTER TABLE messages ADD COLUMN completion_tokens INTEGER NOT NULL DEFAULT 0;");
            if (!try database.hasColumn("messages", "cost_micros")) try database.exec("ALTER TABLE messages ADD COLUMN cost_micros INTEGER NOT NULL DEFAULT 0;");
        }
        try database.exec("PRAGMA user_version = 5;");
    }

    fn backup(database: *Database, path: []const u8, version: i64) Error!void {
        var backup_path: [1100:0]u8 = undefined;
        const rendered = std.fmt.bufPrint(backup_path[0 .. backup_path.len - 1], "{s}.backup-v{d}", .{ path, version }) catch return error.PathTooLong;
        backup_path[rendered.len] = 0;
        var destination: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(&backup_path, &destination, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK or destination == null) {
            if (destination) |opened| _ = c.sqlite3_close(opened);
            return error.OpenFailed;
        }
        defer _ = c.sqlite3_close(destination.?);
        const operation = c.sqlite3_backup_init(destination.?, "main", database.handle, "main") orelse return error.SqlFailed;
        const step = c.sqlite3_backup_step(operation, -1);
        const finish = c.sqlite3_backup_finish(operation);
        if ((step != c.SQLITE_DONE and step != c.SQLITE_OK) or finish != c.SQLITE_OK) return error.SqlFailed;
    }

    pub fn setSchemaVersionForTest(database: *Database, version: u32) Error!void {
        var sql: [64:0]u8 = undefined;
        const rendered = std.fmt.bufPrint(sql[0 .. sql.len - 1], "PRAGMA user_version = {d};", .{version}) catch return error.SqlFailed;
        sql[rendered.len] = 0;
        try database.exec(&sql);
    }

    pub fn upsertCachedModel(database: *Database, slug: []const u8, label: []const u8, favorite: bool, updated_at_ms: i64) Error!void {
        const statement = try database.prepare(
            "INSERT INTO model_cache(slug,label,favorite,updated_at_ms) VALUES(?1,?2,?3,?4) " ++
                "ON CONFLICT(slug) DO UPDATE SET label=excluded.label,favorite=excluded.favorite,updated_at_ms=excluded.updated_at_ms;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, slug);
        try bindText(statement, 2, label);
        try bindInt(statement, 3, @intFromBool(favorite));
        try bindInt(statement, 4, updated_at_ms);
        try stepDone(statement);
    }

    pub fn loadCachedModels(database: *Database, model: anytype) Error!void {
        const statement = try database.prepare("SELECT slug,label,favorite FROM model_cache ORDER BY favorite DESC,updated_at_ms DESC LIMIT 32;");
        defer _ = c.sqlite3_finalize(statement);
        model.model_catalog_count = 0;
        while (model.model_catalog_count < model.model_catalog.len) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            var entry: @TypeOf(model.model_catalog[0]) = .{ .favorite = c.sqlite3_column_int(statement, 2) != 0 };
            setFixed(&entry.slug_storage, &entry.slug_len, textColumn(statement, 0));
            setFixed(&entry.label_storage, &entry.label_len, textColumn(statement, 1));
            model.model_catalog[model.model_catalog_count] = entry;
            model.model_catalog_count += 1;
        }
    }

    pub fn schemaVersion(database: *Database) Error!i64 {
        const statement = try database.prepare("PRAGMA user_version;");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.SqlFailed;
        return c.sqlite3_column_int64(statement, 0);
    }

    fn hasColumn(database: *Database, table: []const u8, column: []const u8) Error!bool {
        var sql: [96:0]u8 = undefined;
        const rendered = std.fmt.bufPrint(sql[0 .. sql.len - 1], "PRAGMA table_info({s});", .{table}) catch return error.SqlFailed;
        sql[rendered.len] = 0;
        const statement = try database.prepare(&sql);
        defer _ = c.sqlite3_finalize(statement);
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) return false;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            if (std.mem.eql(u8, textColumn(statement, 1), column)) return true;
        }
    }

    pub fn messageCount(database: *Database, thread_id: u32) Error!usize {
        const statement = try database.prepare("SELECT COUNT(*) FROM messages WHERE thread_id=?1;");
        defer _ = c.sqlite3_finalize(statement);
        try bindInt(statement, 1, thread_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.SqlFailed;
        return intColumn(usize, statement, 0);
    }

    pub fn loadHistoryBefore(database: *Database, allocator: std.mem.Allocator, thread_id: u32, before_id: u32, limit: usize) (Error || std.mem.Allocator.Error)!HistoryPage {
        const statement = try database.prepare(
            "SELECT id,role,content,response_model,latency_ms,prompt_tokens,completion_tokens,cost_micros FROM messages WHERE thread_id=?1 AND id<?2 ORDER BY id DESC LIMIT ?3;",
        );
        defer _ = c.sqlite3_finalize(statement);
        const attachment_statement = try database.prepare("SELECT kind,path,name FROM attachments WHERE thread_id=?1 AND message_id=?2 ORDER BY position LIMIT 4;");
        defer _ = c.sqlite3_finalize(attachment_statement);
        try bindInt(statement, 1, thread_id);
        try bindInt(statement, 2, before_id);
        try bindInt(statement, 3, limit + 1);
        var messages: std.ArrayList(HistoryMessage) = .empty;
        errdefer {
            for (messages.items) |message| {
                allocator.free(message.content);
                if (message.response_model.len > 0) allocator.free(message.response_model);
                for (message.attachments[0..message.attachment_count]) |attachment| {
                    allocator.free(attachment.path);
                    allocator.free(attachment.name);
                }
            }
            messages.deinit(allocator);
        }
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            const content = try allocator.dupe(u8, textColumn(statement, 2));
            errdefer allocator.free(content);
            const response_model = try allocator.dupe(u8, textColumn(statement, 3));
            errdefer allocator.free(response_model);
            var message = HistoryMessage{
                .id = intColumn(u32, statement, 0),
                .role = intColumn(u8, statement, 1),
                .content = content,
                .response_model = response_model,
                .latency_ms = intColumn(u32, statement, 4),
                .prompt_tokens = intColumn(u32, statement, 5),
                .completion_tokens = intColumn(u32, statement, 6),
                .cost_micros = intColumn(u64, statement, 7),
            };
            errdefer for (message.attachments[0..message.attachment_count]) |attachment| {
                allocator.free(attachment.path);
                allocator.free(attachment.name);
            };
            try bindInt(attachment_statement, 1, thread_id);
            try bindInt(attachment_statement, 2, message.id);
            while (message.attachment_count < message.attachments.len) {
                const attachment_result = c.sqlite3_step(attachment_statement);
                if (attachment_result == c.SQLITE_DONE) break;
                if (attachment_result != c.SQLITE_ROW) return error.SqlFailed;
                const path = try allocator.dupe(u8, textColumn(attachment_statement, 1));
                errdefer allocator.free(path);
                const name = try allocator.dupe(u8, textColumn(attachment_statement, 2));
                errdefer allocator.free(name);
                message.attachments[message.attachment_count] = .{
                    .kind = intColumn(u8, attachment_statement, 0),
                    .path = path,
                    .name = name,
                };
                message.attachment_count += 1;
            }
            reset(attachment_statement);
            try messages.append(allocator, message);
        }
        const has_more = messages.items.len > limit;
        if (has_more) {
            const removed = messages.pop().?;
            allocator.free(removed.content);
            if (removed.response_model.len > 0) allocator.free(removed.response_model);
            for (removed.attachments[0..removed.attachment_count]) |attachment| {
                allocator.free(attachment.path);
                allocator.free(attachment.name);
            }
        }
        std.mem.reverse(HistoryMessage, messages.items);
        return .{ .messages = try messages.toOwnedSlice(allocator), .has_more = has_more };
    }

    pub fn search(database: *Database, allocator: std.mem.Allocator, query: []const u8, limit: usize) (Error || std.mem.Allocator.Error)!SearchPage {
        const statement = try database.prepare(
            "SELECT thread_id,message_id,title,snippet FROM (" ++
                "SELECT t.id AS thread_id,m.id AS message_id,t.title AS title,substr(replace(m.content,char(10),' '),1,180) AS snippet " ++
                "FROM messages AS m JOIN threads AS t ON t.id=m.thread_id JOIN projects AS p ON p.id=t.project_id " ++
                "WHERE t.archived_at_ms=0 AND p.archived_at_ms=0 AND instr(lower(m.content),lower(?1))>0 " ++
                "UNION ALL " ++
                "SELECT t.id AS thread_id,0 AS message_id,t.title AS title,'Chat title' AS snippet " ++
                "FROM threads AS t JOIN projects AS p ON p.id=t.project_id " ++
                "WHERE t.archived_at_ms=0 AND p.archived_at_ms=0 AND instr(lower(t.title),lower(?1))>0" ++
                ") ORDER BY message_id DESC LIMIT ?2;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, query);
        try bindInt(statement, 2, limit);
        var hits: std.ArrayList(SearchHit) = .empty;
        errdefer {
            for (hits.items) |hit| {
                allocator.free(hit.title);
                allocator.free(hit.snippet);
            }
            hits.deinit(allocator);
        }
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            const title = try allocator.dupe(u8, textColumn(statement, 2));
            errdefer allocator.free(title);
            const snippet = try allocator.dupe(u8, textColumn(statement, 3));
            errdefer allocator.free(snippet);
            try hits.append(allocator, .{
                .thread_id = intColumn(u32, statement, 0),
                .message_id = intColumn(u32, statement, 1),
                .title = title,
                .snippet = snippet,
            });
        }
        return .{ .hits = try hits.toOwnedSlice(allocator) };
    }

    pub fn begin(database: *Database) Error!void {
        try database.exec("BEGIN IMMEDIATE;");
    }

    pub fn commit(database: *Database) Error!void {
        try database.exec("COMMIT;");
    }

    pub fn rollback(database: *Database) void {
        database.exec("ROLLBACK;") catch {};
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

    pub fn upsertProject(database: *Database, id: u32, name: []const u8, archived_at_ms: i64, position: usize) Error!void {
        const statement = try database.prepare(
            "INSERT INTO projects(id,name,archived_at_ms,position) VALUES(?1,?2,?3,?4) " ++
                "ON CONFLICT(id) DO UPDATE SET name=excluded.name,archived_at_ms=excluded.archived_at_ms,position=excluded.position;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindInt(statement, 1, id);
        try bindText(statement, 2, name);
        try bindInt(statement, 3, archived_at_ms);
        try bindInt(statement, 4, position);
        try stepDone(statement);
    }

    pub fn upsertThread(database: *Database, id: u32, project_id: u32, title: []const u8, archived_at_ms: i64, position: usize, draft: []const u8, model_choice: u8, model_slug: []const u8, active_model: []const u8) Error!void {
        const statement = try database.prepare(
            "INSERT INTO threads(id,project_id,title,archived_at_ms,position,draft,model_choice,model_slug,active_model) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9) " ++
                "ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,title=excluded.title,archived_at_ms=excluded.archived_at_ms,position=excluded.position,draft=excluded.draft,model_choice=excluded.model_choice,model_slug=excluded.model_slug,active_model=excluded.active_model;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindInt(statement, 1, id);
        try bindInt(statement, 2, project_id);
        try bindText(statement, 3, title);
        try bindInt(statement, 4, archived_at_ms);
        try bindInt(statement, 5, position);
        try bindText(statement, 6, draft);
        try bindInt(statement, 7, model_choice);
        try bindText(statement, 8, model_slug);
        try bindText(statement, 9, active_model);
        try stepDone(statement);
    }

    pub fn upsertMessage(database: *Database, id: u32, thread_id: u32, role: u8, content: []const u8) Error!void {
        try database.upsertMessageWithMetrics(id, thread_id, role, content, "", 0, 0, 0, 0);
    }

    pub fn upsertMessageWithMetrics(database: *Database, id: u32, thread_id: u32, role: u8, content: []const u8, response_model: []const u8, latency_ms: u32, prompt_tokens: u32, completion_tokens: u32, cost_micros: u64) Error!void {
        const statement = try database.prepare(
            "INSERT INTO messages(id,thread_id,role,content,response_model,latency_ms,prompt_tokens,completion_tokens,cost_micros,position) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?1) " ++
                "ON CONFLICT(id) DO UPDATE SET thread_id=excluded.thread_id,role=excluded.role,content=excluded.content,response_model=excluded.response_model,latency_ms=excluded.latency_ms,prompt_tokens=excluded.prompt_tokens,completion_tokens=excluded.completion_tokens,cost_micros=excluded.cost_micros;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindInt(statement, 1, id);
        try bindInt(statement, 2, thread_id);
        try bindInt(statement, 3, role);
        try bindText(statement, 4, content);
        try bindText(statement, 5, response_model);
        try bindInt(statement, 6, latency_ms);
        try bindInt(statement, 7, prompt_tokens);
        try bindInt(statement, 8, completion_tokens);
        try bindInt(statement, 9, cost_micros);
        try stepDone(statement);
    }

    pub fn replaceSnippets(database: *Database, snippets: anytype) Error!void {
        try database.exec("DELETE FROM prompt_snippets;");
        const statement = try database.prepare("INSERT INTO prompt_snippets(id,name,body,position) VALUES(?1,?2,?3,?4);");
        defer _ = c.sqlite3_finalize(statement);
        for (snippets, 0..) |*snippet, position| {
            try bindInt(statement, 1, snippet.id);
            try bindText(statement, 2, snippet.name());
            try bindText(statement, 3, snippet.body());
            try bindInt(statement, 4, position);
            try stepDone(statement);
            reset(statement);
        }
    }

    pub fn replaceAttachments(database: *Database, thread_id: u32, message_id: u32, attachments: anytype) Error!void {
        const clear = try database.prepare("DELETE FROM attachments WHERE thread_id=?1 AND message_id=?2;");
        defer _ = c.sqlite3_finalize(clear);
        try bindInt(clear, 1, thread_id);
        try bindInt(clear, 2, message_id);
        try stepDone(clear);

        const insert = try database.prepare("INSERT INTO attachments(thread_id,message_id,position,kind,path,name) VALUES(?1,?2,?3,?4,?5,?6);");
        defer _ = c.sqlite3_finalize(insert);
        for (attachments, 0..) |*attachment, position| {
            try bindInt(insert, 1, thread_id);
            try bindInt(insert, 2, message_id);
            try bindInt(insert, 3, position);
            try bindInt(insert, 4, attachmentKindValue(attachment));
            try bindText(insert, 5, attachmentPathValue(attachment));
            try bindText(insert, 6, attachmentNameValue(attachment));
            try stepDone(insert);
            reset(insert);
        }
    }

    pub fn clearMessages(database: *Database, thread_id: u32) Error!void {
        const attachments = try database.prepare("DELETE FROM attachments WHERE thread_id=?1 AND message_id<>0;");
        defer _ = c.sqlite3_finalize(attachments);
        try bindInt(attachments, 1, thread_id);
        try stepDone(attachments);
        const statement = try database.prepare("DELETE FROM messages WHERE thread_id=?1;");
        defer _ = c.sqlite3_finalize(statement);
        try bindInt(statement, 1, thread_id);
        try stepDone(statement);
    }

    pub fn truncateMessages(database: *Database, thread_id: u32, from_message_id: u32) Error!void {
        const attachments = try database.prepare("DELETE FROM attachments WHERE thread_id=?1 AND message_id>=?2;");
        defer _ = c.sqlite3_finalize(attachments);
        try bindInt(attachments, 1, thread_id);
        try bindInt(attachments, 2, from_message_id);
        try stepDone(attachments);
        const messages = try database.prepare("DELETE FROM messages WHERE thread_id=?1 AND id>=?2;");
        defer _ = c.sqlite3_finalize(messages);
        try bindInt(messages, 1, thread_id);
        try bindInt(messages, 2, from_message_id);
        try stepDone(messages);
    }

    pub fn saveMeta(database: *Database, active_project_id: u32, active_thread_id: u32, next_project_id: u32, next_thread_id: u32, next_message_id: u32) Error!void {
        const statement = try database.prepare(
            "INSERT INTO workspace_meta(singleton,active_project_id,active_thread_id,next_project_id,next_thread_id,next_message_id) VALUES(1,?1,?2,?3,?4,?5) " ++
                "ON CONFLICT(singleton) DO UPDATE SET active_project_id=excluded.active_project_id,active_thread_id=excluded.active_thread_id,next_project_id=excluded.next_project_id,next_thread_id=excluded.next_thread_id,next_message_id=excluded.next_message_id;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindInt(statement, 1, active_project_id);
        try bindInt(statement, 2, active_thread_id);
        try bindInt(statement, 3, next_project_id);
        try bindInt(statement, 4, next_thread_id);
        try bindInt(statement, 5, next_message_id);
        try stepDone(statement);
    }

    pub fn savePreferences(database: *Database, notifications_enabled: bool) Error!void {
        const statement = try database.prepare(
            "INSERT INTO app_preferences(singleton,notifications_enabled) VALUES(1,?1) " ++
                "ON CONFLICT(singleton) DO UPDATE SET notifications_enabled=excluded.notifications_enabled;",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindInt(statement, 1, @intFromBool(notifications_enabled));
        try stepDone(statement);
    }

    pub fn reconcile(database: *Database, project_ids: []const u32, thread_ids: []const u32) Error!void {
        const threads = try database.prepare("SELECT id FROM threads;");
        defer _ = c.sqlite3_finalize(threads);
        var stale_threads: [24]u32 = undefined;
        var stale_thread_count: usize = 0;
        while (true) {
            const result = c.sqlite3_step(threads);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            const id = intColumn(u32, threads, 0);
            if (!containsId(thread_ids, id) and stale_thread_count < stale_threads.len) {
                stale_threads[stale_thread_count] = id;
                stale_thread_count += 1;
            }
        }
        for (stale_threads[0..stale_thread_count]) |id| try database.deleteById("DELETE FROM threads WHERE id=?1;", id);

        const projects = try database.prepare("SELECT id FROM projects;");
        defer _ = c.sqlite3_finalize(projects);
        var stale_projects: [8]u32 = undefined;
        var stale_project_count: usize = 0;
        while (true) {
            const result = c.sqlite3_step(projects);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            const id = intColumn(u32, projects, 0);
            if (!containsId(project_ids, id) and stale_project_count < stale_projects.len) {
                stale_projects[stale_project_count] = id;
                stale_project_count += 1;
            }
        }
        for (stale_projects[0..stale_project_count]) |id| try database.deleteById("DELETE FROM projects WHERE id=?1;", id);
    }

    fn deleteById(database: *Database, sql: [*:0]const u8, id: u32) Error!void {
        const statement = try database.prepare(sql);
        defer _ = c.sqlite3_finalize(statement);
        try bindInt(statement, 1, id);
        try stepDone(statement);
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
            try database.replaceAttachments(thread.id, 0, thread.draft_attachments[0..thread.draft_attachment_count]);
        }

        const message_statement = try database.prepare("INSERT INTO messages(id,thread_id,role,content,response_model,latency_ms,prompt_tokens,completion_tokens,cost_micros,position) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10);");
        defer _ = c.sqlite3_finalize(message_statement);
        for (model.threads[0..model.thread_count]) |*thread| {
            for (thread.messages[0..thread.message_count], 0..) |*message, position| {
                try bindInt(message_statement, 1, message.id);
                try bindInt(message_statement, 2, thread.id);
                try bindInt(message_statement, 3, @intFromEnum(message.role));
                try bindText(message_statement, 4, message.content());
                try bindText(message_statement, 5, message.responseModel());
                try bindInt(message_statement, 6, message.latency_ms);
                try bindInt(message_statement, 7, message.prompt_tokens);
                try bindInt(message_statement, 8, message.completion_tokens);
                try bindInt(message_statement, 9, message.cost_micros);
                try bindInt(message_statement, 10, position);
                try stepDone(message_statement);
                reset(message_statement);
                try database.replaceAttachments(thread.id, message.id, message.attachments[0..message.attachment_count]);
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
        try database.savePreferences(model.notifications_enabled);
        try database.replaceSnippets(model.snippets[0..model.snippet_count]);
        try database.exec("COMMIT;");
    }

    pub fn load(database: *Database, model: anytype) Error!bool {
        try database.loadCachedModels(model);
        model.project_count = 0;
        model.thread_count = 0;

        const projects = try database.prepare("SELECT id,name,archived_at_ms FROM projects ORDER BY position,id;");
        defer _ = c.sqlite3_finalize(projects);
        while (true) {
            const result = c.sqlite3_step(projects);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            if (!model.ensureProjectCapacity(model.project_count + 1)) return error.InvalidData;
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
            if (!model.ensureThreadCapacity(model.thread_count + 1)) return error.InvalidData;
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

        // Keep the complete transcript durable and hydrate a generous initial
        // page. Older pages are queried on demand, independently of the
        // provider's small context window.
        const messages = try database.prepare(
            "SELECT m.id,m.thread_id,m.role,m.content,m.response_model,m.latency_ms,m.prompt_tokens,m.completion_tokens,m.cost_micros FROM messages AS m " ++
                "WHERE m.id IN (SELECT recent.id FROM messages AS recent WHERE recent.thread_id=m.thread_id ORDER BY recent.id DESC LIMIT 50) " ++
                "ORDER BY m.thread_id,m.id;",
        );
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
            if (!thread.ensureMessageCapacity(model.allocator, thread.message_count + 1)) return error.InvalidData;
            const role_value = intColumn(u8, messages, 2);
            if (role_value >= std.meta.fields(@TypeOf(thread.messages[0].role)).len) return error.InvalidData;
            var message: @TypeOf(thread.messages[0]) = .{
                .id = intColumn(u32, messages, 0),
                .role = @enumFromInt(role_value),
            };
            const content = textColumn(messages, 3);
            message.content_storage = model.allocator.dupe(u8, content) catch return error.InvalidData;
            message.content_len = content.len;
            setFixed(&message.response_model_storage, &message.response_model_len, textColumn(messages, 4));
            message.latency_ms = intColumn(u32, messages, 5);
            message.prompt_tokens = intColumn(u32, messages, 6);
            message.completion_tokens = intColumn(u32, messages, 7);
            message.cost_micros = intColumn(u64, messages, 8);
            thread.messages[thread.message_count] = message;
            thread.message_count += 1;
        }
        for (model.threads[0..model.thread_count]) |*thread| {
            thread.has_older_messages = thread.message_count == 50;
        }

        const attachments = try database.prepare("SELECT thread_id,message_id,kind,path,name FROM attachments ORDER BY thread_id,message_id,position;");
        defer _ = c.sqlite3_finalize(attachments);
        while (true) {
            const result = c.sqlite3_step(attachments);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            const thread_id = intColumn(u32, attachments, 0);
            const message_id = intColumn(u32, attachments, 1);
            var target_thread: ?*@TypeOf(model.threads[0]) = null;
            for (model.threads[0..model.thread_count]) |*thread| {
                if (thread.id == thread_id) target_thread = thread;
            }
            const thread = target_thread orelse continue;
            const kind_value = intColumn(u8, attachments, 2);
            if (message_id == 0) {
                if (thread.draft_attachment_count == thread.draft_attachments.len or kind_value >= std.meta.fields(@TypeOf(thread.draft_attachments[0].kind)).len) continue;
                var attachment: @TypeOf(thread.draft_attachments[0]) = .{ .kind = @enumFromInt(kind_value) };
                setFixed(&attachment.path_storage, &attachment.path_len, textColumn(attachments, 3));
                setFixed(&attachment.name_storage, &attachment.name_len, textColumn(attachments, 4));
                thread.draft_attachments[thread.draft_attachment_count] = attachment;
                thread.draft_attachment_count += 1;
                continue;
            }
            for (thread.messages[0..thread.message_count]) |*message| {
                if (message.id != message_id or message.attachment_count == message.attachments.len or kind_value >= std.meta.fields(@TypeOf(message.attachments[0].kind)).len) continue;
                var attachment: @TypeOf(message.attachments[0]) = .{ .kind = @enumFromInt(kind_value) };
                setFixed(&attachment.path_storage, &attachment.path_len, textColumn(attachments, 3));
                setFixed(&attachment.name_storage, &attachment.name_len, textColumn(attachments, 4));
                message.attachments[message.attachment_count] = attachment;
                message.attachment_count += 1;
            }
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
        const preferences = try database.prepare("SELECT notifications_enabled FROM app_preferences WHERE singleton=1;");
        defer _ = c.sqlite3_finalize(preferences);
        if (c.sqlite3_step(preferences) == c.SQLITE_ROW) model.notifications_enabled = c.sqlite3_column_int(preferences, 0) != 0;
        const snippets = try database.prepare("SELECT id,name,body FROM prompt_snippets ORDER BY position,id;");
        defer _ = c.sqlite3_finalize(snippets);
        model.snippet_count = 0;
        model.next_snippet_id = 1;
        while (model.snippet_count < model.snippets.len) {
            const result = c.sqlite3_step(snippets);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            var snippet: @TypeOf(model.snippets[0]) = .{ .id = intColumn(u32, snippets, 0) };
            setFixed(&snippet.name_storage, &snippet.name_len, textColumn(snippets, 1));
            setFixed(&snippet.body_storage, &snippet.body_len, textColumn(snippets, 2));
            model.snippets[model.snippet_count] = snippet;
            model.snippet_count += 1;
            model.next_snippet_id = @max(model.next_snippet_id, snippet.id +| 1);
        }
        model.ensureDefaultSnippets();
        return true;
    }

    pub fn exportThreadMarkdown(database: *Database, allocator: std.mem.Allocator, io: std.Io, thread_id: u32, path: []const u8) !void {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        const writer = &output.writer;
        const thread = try database.prepare("SELECT title,model_slug FROM threads WHERE id=?1;");
        defer _ = c.sqlite3_finalize(thread);
        try bindInt(thread, 1, thread_id);
        if (c.sqlite3_step(thread) != c.SQLITE_ROW) return error.InvalidData;
        try writer.print("# {s}\n\nModel: `{s}`\n\n", .{ textColumn(thread, 0), textColumn(thread, 1) });

        const messages = try database.prepare("SELECT role,content,response_model,latency_ms,prompt_tokens,completion_tokens,cost_micros FROM messages WHERE thread_id=?1 ORDER BY position,id;");
        defer _ = c.sqlite3_finalize(messages);
        try bindInt(messages, 1, thread_id);
        while (true) {
            const result = c.sqlite3_step(messages);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            const assistant = intColumn(u8, messages, 0) == 1;
            try writer.print("## {s}\n\n{s}\n\n", .{ if (assistant) "Assistant" else "You", textColumn(messages, 1) });
            if (assistant) {
                const response_model = textColumn(messages, 2);
                const latency_ms = intColumn(u32, messages, 3);
                const prompt_tokens = intColumn(u32, messages, 4);
                const completion_tokens = intColumn(u32, messages, 5);
                const cost_micros = intColumn(u64, messages, 6);
                if (response_model.len > 0 or latency_ms > 0 or prompt_tokens + completion_tokens > 0 or cost_micros > 0) {
                    try writer.writeByte('*');
                    var wrote_detail = false;
                    if (response_model.len > 0) {
                        try writer.writeAll(response_model);
                        wrote_detail = true;
                    }
                    if (latency_ms > 0) {
                        if (wrote_detail) try writer.writeAll(" · ");
                        try writer.print("{d:.1}s", .{@as(f64, @floatFromInt(latency_ms)) / 1000.0});
                        wrote_detail = true;
                    }
                    if (prompt_tokens > 0 or completion_tokens > 0) {
                        if (wrote_detail) try writer.writeAll(" · ");
                        try writer.print("{d} in / {d} out", .{ prompt_tokens, completion_tokens });
                        wrote_detail = true;
                    }
                    if (cost_micros > 0) {
                        if (wrote_detail) try writer.writeAll(" · ");
                        try writer.print("${d:.6}", .{@as(f64, @floatFromInt(cost_micros)) / 1_000_000.0});
                    }
                    try writer.writeAll("*\n\n");
                }
            }
        }
        try writeExport(io, path, output.written());
    }

    pub fn exportWorkspaceJson(database: *Database, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        const writer = &output.writer;
        try writer.writeAll("{\"format\":\"superchat-workspace\",\"version\":1,\"meta\":");
        const meta = try database.prepare("SELECT active_project_id,active_thread_id,next_project_id,next_thread_id,next_message_id FROM workspace_meta WHERE singleton=1;");
        defer _ = c.sqlite3_finalize(meta);
        if (c.sqlite3_step(meta) == c.SQLITE_ROW) {
            try writer.print("{{\"active_project_id\":{d},\"active_thread_id\":{d},\"next_project_id\":{d},\"next_thread_id\":{d},\"next_message_id\":{d}}}", .{
                intColumn(u32, meta, 0), intColumn(u32, meta, 1), intColumn(u32, meta, 2), intColumn(u32, meta, 3), intColumn(u32, meta, 4),
            });
        } else {
            try writer.writeAll("null");
        }
        const preferences = try database.prepare("SELECT notifications_enabled FROM app_preferences WHERE singleton=1;");
        defer _ = c.sqlite3_finalize(preferences);
        const notifications_enabled = c.sqlite3_step(preferences) != c.SQLITE_ROW or c.sqlite3_column_int(preferences, 0) != 0;
        try writer.print(",\"preferences\":{{\"notifications_enabled\":{s}}},\"cached_models\":[", .{if (notifications_enabled) "true" else "false"});
        const cached_models = try database.prepare("SELECT slug,label,favorite,updated_at_ms FROM model_cache ORDER BY updated_at_ms DESC,slug;");
        defer _ = c.sqlite3_finalize(cached_models);
        var first = true;
        while (true) {
            const result = c.sqlite3_step(cached_models);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("{\"slug\":");
            try std.json.Stringify.value(textColumn(cached_models, 0), .{}, writer);
            try writer.writeAll(",\"label\":");
            try std.json.Stringify.value(textColumn(cached_models, 1), .{}, writer);
            try writer.print(",\"favorite\":{s},\"updated_at_ms\":{d}}}", .{ if (c.sqlite3_column_int(cached_models, 2) != 0) "true" else "false", intColumn(i64, cached_models, 3) });
        }
        try writer.writeAll("],\"projects\":[");
        const projects = try database.prepare("SELECT id,name,archived_at_ms,position FROM projects ORDER BY position,id;");
        defer _ = c.sqlite3_finalize(projects);
        first = true;
        while (true) {
            const result = c.sqlite3_step(projects);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{{\"id\":{d},\"name\":", .{intColumn(u32, projects, 0)});
            try std.json.Stringify.value(textColumn(projects, 1), .{}, writer);
            try writer.print(",\"archived_at_ms\":{d},\"position\":{d}}}", .{ intColumn(i64, projects, 2), intColumn(usize, projects, 3) });
        }
        try writer.writeAll("],\"threads\":[");
        const threads = try database.prepare("SELECT id,project_id,title,archived_at_ms,position,draft,model_choice,model_slug,active_model FROM threads ORDER BY position,id;");
        defer _ = c.sqlite3_finalize(threads);
        first = true;
        while (true) {
            const result = c.sqlite3_step(threads);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{{\"id\":{d},\"project_id\":{d},\"title\":", .{ intColumn(u32, threads, 0), intColumn(u32, threads, 1) });
            try std.json.Stringify.value(textColumn(threads, 2), .{}, writer);
            try writer.print(",\"archived_at_ms\":{d},\"position\":{d},\"draft\":", .{ intColumn(i64, threads, 3), intColumn(usize, threads, 4) });
            try std.json.Stringify.value(textColumn(threads, 5), .{}, writer);
            try writer.print(",\"model_choice\":{d},\"model_slug\":", .{intColumn(u8, threads, 6)});
            try std.json.Stringify.value(textColumn(threads, 7), .{}, writer);
            try writer.writeAll(",\"active_model\":");
            try std.json.Stringify.value(textColumn(threads, 8), .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"messages\":[");
        const messages = try database.prepare("SELECT id,thread_id,role,content,response_model,latency_ms,prompt_tokens,completion_tokens,cost_micros,position FROM messages ORDER BY thread_id,position,id;");
        defer _ = c.sqlite3_finalize(messages);
        first = true;
        while (true) {
            const result = c.sqlite3_step(messages);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{{\"id\":{d},\"thread_id\":{d},\"role\":{d},\"content\":", .{ intColumn(u32, messages, 0), intColumn(u32, messages, 1), intColumn(u8, messages, 2) });
            try std.json.Stringify.value(textColumn(messages, 3), .{}, writer);
            try writer.writeAll(",\"response_model\":");
            try std.json.Stringify.value(textColumn(messages, 4), .{}, writer);
            try writer.print(",\"latency_ms\":{d},\"prompt_tokens\":{d},\"completion_tokens\":{d},\"cost_micros\":{d},\"position\":{d}}}", .{
                intColumn(u32, messages, 5), intColumn(u32, messages, 6), intColumn(u32, messages, 7), intColumn(u64, messages, 8), intColumn(usize, messages, 9),
            });
        }
        try writer.writeAll("],\"attachments\":[");
        const attachments = try database.prepare("SELECT thread_id,message_id,position,kind,path,name FROM attachments ORDER BY thread_id,message_id,position;");
        defer _ = c.sqlite3_finalize(attachments);
        first = true;
        while (true) {
            const result = c.sqlite3_step(attachments);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{{\"thread_id\":{d},\"message_id\":{d},\"position\":{d},\"kind\":{d},\"path\":", .{
                intColumn(u32, attachments, 0), intColumn(u32, attachments, 1), intColumn(usize, attachments, 2), intColumn(u8, attachments, 3),
            });
            try std.json.Stringify.value(textColumn(attachments, 4), .{}, writer);
            try writer.writeAll(",\"name\":");
            try std.json.Stringify.value(textColumn(attachments, 5), .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"snippets\":[");
        const snippets = try database.prepare("SELECT id,name,body,position FROM prompt_snippets ORDER BY position,id;");
        defer _ = c.sqlite3_finalize(snippets);
        first = true;
        while (true) {
            const result = c.sqlite3_step(snippets);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.SqlFailed;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{{\"id\":{d},\"name\":", .{intColumn(u32, snippets, 0)});
            try std.json.Stringify.value(textColumn(snippets, 1), .{}, writer);
            try writer.writeAll(",\"body\":");
            try std.json.Stringify.value(textColumn(snippets, 2), .{}, writer);
            try writer.print(",\"position\":{d}}}", .{intColumn(usize, snippets, 3)});
        }
        try writer.writeAll("]}");
        try writeExport(io, path, output.written());
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

fn writeExport(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

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

fn attachmentKindValue(attachment: anytype) u8 {
    return switch (@typeInfo(@TypeOf(attachment.kind))) {
        .@"enum" => @intCast(@intFromEnum(attachment.kind)),
        else => @intCast(attachment.kind),
    };
}

fn attachmentPathValue(attachment: anytype) []const u8 {
    if (@hasField(@TypeOf(attachment.*), "path_storage")) return attachment.path();
    return attachment.path[0..attachment.path_len];
}

fn attachmentNameValue(attachment: anytype) []const u8 {
    if (@hasField(@TypeOf(attachment.*), "name_storage")) return attachment.name();
    return attachment.name[0..attachment.name_len];
}

fn containsId(ids: []const u32, target: u32) bool {
    for (ids) |id| if (id == target) return true;
    return false;
}

fn setFixed(storage: anytype, len: *usize, value: []const u8) void {
    var copy_len = @min(storage.len, value.len);
    if (copy_len < value.len) {
        while (copy_len > 0 and value[copy_len] & 0xc0 == 0x80) copy_len -= 1;
    }
    @memcpy(storage[0..copy_len], value[0..copy_len]);
    len.* = copy_len;
}
