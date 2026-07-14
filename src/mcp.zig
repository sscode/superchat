const std = @import("std");

pub const protocol_version = "2025-11-25";
pub const max_servers = 8;
pub const max_tools = 48;
pub const max_server_name_bytes = 48;
pub const max_command_bytes = 768;
pub const max_tool_name_bytes = 128;
pub const max_tool_title_bytes = 96;
pub const max_tool_description_bytes = 320;
pub const max_tool_schema_bytes = 4096;
pub const max_arguments_bytes = 4096;
pub const max_result_bytes = 16 * 1024;
const max_rpc_line_bytes = 256 * 1024;
const helper_timeout_ms = 18_000;

pub const ConnectionState = enum { idle, connecting, connected, failed };

pub const Server = struct {
    id: u32 = 0,
    name_storage: [max_server_name_bytes]u8 = undefined,
    name_len: usize = 0,
    command_storage: [max_command_bytes]u8 = undefined,
    command_len: usize = 0,
    enabled: bool = true,
    state: ConnectionState = .idle,
    tool_count: usize = 0,
    status_storage: [128]u8 = undefined,
    status_len: usize = 0,

    pub fn name(server: *const Server) []const u8 {
        return server.name_storage[0..server.name_len];
    }

    pub fn command(server: *const Server) []const u8 {
        return server.command_storage[0..server.command_len];
    }

    pub fn status(server: *const Server) []const u8 {
        return server.status_storage[0..server.status_len];
    }

    pub fn setName(server: *Server, value: []const u8) void {
        server.name_len = copyText(&server.name_storage, value);
    }

    pub fn setCommand(server: *Server, value: []const u8) void {
        server.command_len = copyText(&server.command_storage, value);
    }

    pub fn setStatus(server: *Server, value: []const u8) void {
        server.status_len = copyText(&server.status_storage, value);
    }
};

pub const Tool = struct {
    server_id: u32 = 0,
    name_storage: [max_tool_name_bytes]u8 = undefined,
    name_len: usize = 0,
    title_storage: [max_tool_title_bytes]u8 = undefined,
    title_len: usize = 0,
    description_storage: [max_tool_description_bytes]u8 = undefined,
    description_len: usize = 0,
    schema_storage: [max_tool_schema_bytes]u8 = undefined,
    schema_len: usize = 0,

    pub fn name(tool: *const Tool) []const u8 {
        return tool.name_storage[0..tool.name_len];
    }

    pub fn title(tool: *const Tool) []const u8 {
        return tool.title_storage[0..tool.title_len];
    }

    pub fn description(tool: *const Tool) []const u8 {
        return tool.description_storage[0..tool.description_len];
    }

    pub fn schema(tool: *const Tool) []const u8 {
        return tool.schema_storage[0..tool.schema_len];
    }
};

pub const HelperMode = enum { discover, call };

pub const HelperRequest = struct {
    command: []const u8,
    tool: []const u8 = "",
    arguments: std.json.Value = .{ .object = .empty },
};

pub const RpcError = struct {
    code: i64 = 0,
    message: []const u8 = "MCP request failed",
};

const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: std.json.Value,
};

const InitializeEnvelope = struct {
    result: ?InitializeResult = null,
    @"error": ?RpcError = null,
};

pub const ToolDefinition = struct {
    name: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
    inputSchema: std.json.Value,
};

pub const ToolsResult = struct {
    tools: []const ToolDefinition = &.{},
};

pub const ToolsEnvelope = struct {
    result: ?ToolsResult = null,
    @"error": ?RpcError = null,
};

pub const ContentItem = struct {
    type: []const u8 = "",
    text: []const u8 = "",
};

pub const CallResult = struct {
    content: []const ContentItem = &.{},
    isError: bool = false,
    structuredContent: ?std.json.Value = null,
};

pub const CallEnvelope = struct {
    result: ?CallResult = null,
    @"error": ?RpcError = null,
};

pub fn parseTools(allocator: std.mem.Allocator, response: []const u8, server_id: u32, destination: []Tool) !usize {
    var parsed = try std.json.parseFromSlice(ToolsEnvelope, allocator, response, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.@"error" != null) return error.ProtocolError;
    const result = parsed.value.result orelse return error.InvalidResponse;
    var count: usize = 0;
    for (result.tools) |definition| {
        if (count == destination.len or definition.name.len == 0) break;
        var tool = Tool{ .server_id = server_id };
        tool.name_len = copyText(&tool.name_storage, definition.name);
        const title = if (definition.title.len > 0) definition.title else definition.name;
        tool.title_len = copyText(&tool.title_storage, title);
        tool.description_len = copyText(&tool.description_storage, definition.description);
        var schema_writer: std.Io.Writer.Allocating = .init(allocator);
        defer schema_writer.deinit();
        std.json.Stringify.value(definition.inputSchema, .{}, &schema_writer.writer) catch continue;
        tool.schema_len = copyText(&tool.schema_storage, schema_writer.written());
        destination[count] = tool;
        count += 1;
    }
    return count;
}

pub fn formatCallResult(allocator: std.mem.Allocator, response: []const u8, destination: []u8) !struct { len: usize, is_error: bool } {
    var parsed = try std.json.parseFromSlice(CallEnvelope, allocator, response, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.@"error") |rpc_error| {
        const len = copyText(destination, rpc_error.message);
        return .{ .len = len, .is_error = true };
    }
    const result = parsed.value.result orelse return error.InvalidResponse;
    var writer: std.Io.Writer = .fixed(destination);
    var wrote_text = false;
    for (result.content) |item| {
        if (!std.mem.eql(u8, item.type, "text") or item.text.len == 0) continue;
        if (wrote_text) writer.writeAll("\n\n") catch break;
        writer.writeAll(item.text) catch break;
        wrote_text = true;
    }
    if (!wrote_text) {
        if (result.structuredContent) |structured| {
            std.json.Stringify.value(structured, .{ .whitespace = .indent_2 }, &writer) catch return error.ResultTooLarge;
        } else {
            writer.writeAll("Tool completed without text output.") catch return error.ResultTooLarge;
        }
    }
    return .{ .len = writer.buffered().len, .is_error = result.isError };
}

pub fn writeHelperInput(writer: *std.Io.Writer, command: []const u8, tool: []const u8, arguments: []const u8) !void {
    try writer.writeAll("{\"command\":");
    try std.json.Stringify.value(command, .{}, writer);
    try writer.writeAll(",\"tool\":");
    try std.json.Stringify.value(tool, .{}, writer);
    try writer.writeAll(",\"arguments\":");
    try writer.writeAll(if (arguments.len > 0) arguments else "{}");
    try writer.writeByte('}');
}

pub fn runHelper(io: std.Io, allocator: std.mem.Allocator, mode: HelperMode, input: []const u8, output: *std.Io.Writer) !void {
    var request = try std.json.parseFromSlice(HelperRequest, allocator, input, .{ .ignore_unknown_fields = true });
    defer request.deinit();
    if (request.value.command.len == 0 or request.value.command.len > max_command_bytes) return error.InvalidCommand;
    if (mode == .call and request.value.tool.len == 0) return error.InvalidTool;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/zsh", "-lc", request.value.command },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var child_done: std.atomic.Value(bool) = .init(false);
    var child_timed_out: std.atomic.Value(bool) = .init(false);
    const child_id = child.id orelse return error.MissingProcessId;
    const watchdog = try std.Thread.spawn(.{}, timeoutChild, .{ &child_done, &child_timed_out, child_id, io });
    defer {
        child_done.store(true, .release);
        if (child.stdin) |stdin_file| stdin_file.close(io);
        child.stdin = null;
        std.posix.kill(child_id, .KILL) catch {};
        _ = child.wait(io) catch {};
        watchdog.join();
    }

    const stdin_file = child.stdin orelse return error.MissingPipe;
    const stdout_file = child.stdout orelse return error.MissingPipe;
    var reader = LineReader{};

    try stdin_file.writeStreamingAll(io, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"" ++ protocol_version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"Superchat\",\"version\":\"0.1.1\"}}}\n");
    const initialize_response = try reader.readResponse(io, stdout_file, 1);
    var initialized = try std.json.parseFromSlice(InitializeEnvelope, allocator, initialize_response, .{ .ignore_unknown_fields = true });
    defer initialized.deinit();
    if (initialized.value.@"error" != null) return error.InitializeFailed;
    const initialize_result = initialized.value.result orelse return error.InvalidResponse;
    if (!std.mem.eql(u8, initialize_result.protocolVersion, protocol_version)) return error.UnsupportedProtocolVersion;
    if (initialize_result.capabilities != .object or initialize_result.capabilities.object.get("tools") == null) return error.ToolsUnsupported;
    try stdin_file.writeStreamingAll(io, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n");

    var request_writer: std.Io.Writer.Allocating = .init(allocator);
    defer request_writer.deinit();
    if (mode == .discover) {
        try request_writer.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n");
    } else {
        try request_writer.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":");
        try std.json.Stringify.value(request.value.tool, .{}, &request_writer.writer);
        try request_writer.writer.writeAll(",\"arguments\":");
        try std.json.Stringify.value(request.value.arguments, .{}, &request_writer.writer);
        try request_writer.writer.writeAll("}}\n");
    }
    try stdin_file.writeStreamingAll(io, request_writer.written());
    const response = try reader.readResponse(io, stdout_file, 2);
    if (child_timed_out.load(.acquire)) return error.TimedOut;
    try output.writeAll(response);
}

fn timeoutChild(done: *std.atomic.Value(bool), timed_out: *std.atomic.Value(bool), child_id: std.posix.pid_t, io: std.Io) void {
    const interval_ms = 100;
    var elapsed: u64 = 0;
    while (elapsed < helper_timeout_ms) : (elapsed += interval_ms) {
        if (done.load(.acquire)) return;
        std.Io.sleep(io, .fromMilliseconds(interval_ms), .awake) catch return;
    }
    if (done.load(.acquire)) return;
    timed_out.store(true, .release);
    std.posix.kill(child_id, .KILL) catch {};
}

const LineReader = struct {
    storage: [max_rpc_line_bytes]u8 = undefined,
    len: usize = 0,

    fn readResponse(reader: *LineReader, io: std.Io, file: std.Io.File, expected_id: i64) ![]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, reader.storage[0..reader.len], '\n')) |newline| {
                const line = reader.storage[0..newline];
                var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, line, .{}) catch {
                    reader.consume(newline + 1);
                    continue;
                };
                defer parsed.deinit();
                const id_matches = if (parsed.value == .object)
                    if (parsed.value.object.get("id")) |id| id == .integer and id.integer == expected_id else false
                else
                    false;
                if (id_matches) return line;
                reader.consume(newline + 1);
                continue;
            }
            if (reader.len == reader.storage.len) return error.ResponseTooLarge;
            var chunk: [4096]u8 = undefined;
            const slices: [1][]u8 = .{chunk[0..@min(chunk.len, reader.storage.len - reader.len)]};
            const count = try file.readStreaming(io, &slices);
            if (count == 0) return error.UnexpectedEndOfStream;
            @memcpy(reader.storage[reader.len..][0..count], chunk[0..count]);
            reader.len += count;
        }
    }

    fn consume(reader: *LineReader, count: usize) void {
        if (count >= reader.len) {
            reader.len = 0;
            return;
        }
        std.mem.copyForwards(u8, reader.storage[0 .. reader.len - count], reader.storage[count..reader.len]);
        reader.len -= count;
    }
};

fn copyText(destination: []u8, source: []const u8) usize {
    const len = @min(destination.len, source.len);
    @memcpy(destination[0..len], source[0..len]);
    return len;
}

test "tool discovery preserves schemas" {
    const response =
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"weather","title":"Weather","description":"Current conditions","inputSchema":{"type":"object","properties":{"city":{"type":"string"}}}}]}}
    ;
    var tools: [2]Tool = undefined;
    const count = try parseTools(std.testing.allocator, response, 7, &tools);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u32, 7), tools[0].server_id);
    try std.testing.expectEqualStrings("weather", tools[0].name());
    try std.testing.expect(std.mem.indexOf(u8, tools[0].schema(), "city") != null);
}

test "tool call results become bounded text" {
    const response =
        \\{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"72 F and sunny"}],"isError":false}}
    ;
    var output: [128]u8 = undefined;
    const result = try formatCallResult(std.testing.allocator, response, &output);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("72 F and sunny", output[0..result.len]);
}
