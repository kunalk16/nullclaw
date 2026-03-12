const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

pub const ProbeResult = struct {
    live_ok: bool,
    reason: []const u8,
};

pub const codex_model_fallbacks = [_][]const u8{
    "gpt-5.4",
    "gpt-5.3-codex",
    "gpt-5.3-codex-spark",
    "gpt-5.2-codex",
    "gpt-5.2",
    "gpt-5.1-codex-max",
    "gpt-5.1-codex",
    "gpt-5.1",
    "gpt-5-codex",
    "gpt-5",
    "gpt-5.1-codex-mini",
    "gpt-5-codex-mini",
};

pub const DEFAULT_CODEX_MODEL = codex_model_fallbacks[0];

const CommandRunResult = struct {
    stdout: []u8,
    stderr: []u8,
    success: bool,
};

pub fn freeOwnedStrings(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

pub fn loadCodexModels(allocator: std.mem.Allocator) ![][]const u8 {
    return loadCodexModelsInner(allocator) catch dupeFallbackModels(allocator);
}

pub fn probeCodexCli(allocator: std.mem.Allocator) ProbeResult {
    const command = resolveCodexCommand(allocator) orelse return .{
        .live_ok = false,
        .reason = "codex_cli_missing",
    };
    defer allocator.free(command);

    const result = runCommand(allocator, command, &.{ "login", "status" }) catch return .{
        .live_ok = false,
        .reason = "codex_cli_probe_failed",
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (!result.success) {
        return .{
            .live_ok = false,
            .reason = "codex_cli_not_authenticated",
        };
    }

    return .{
        .live_ok = true,
        .reason = "ok",
    };
}

pub fn probeOpenAiCodex(allocator: std.mem.Allocator) ProbeResult {
    if (hasOpenAiCodexCredential(allocator)) {
        return .{
            .live_ok = true,
            .reason = "ok",
        };
    }

    return .{
        .live_ok = false,
        .reason = "codex_auth_missing",
    };
}

pub fn hasOpenAiCodexCredential(allocator: std.mem.Allocator) bool {
    if (hasNullclawOpenAiCodexTokens(allocator)) return true;
    return hasCodexCliTokens(allocator);
}

pub fn resolveCodexCommand(allocator: std.mem.Allocator) ?[]u8 {
    const binary_name = if (builtin.os.tag == .windows) "codex.exe" else "codex";

    if (resolveFromPath(allocator, binary_name)) |command| return command;

    const static_candidates = [_][]const u8{
        if (builtin.os.tag == .windows) "C:\\Program Files\\Codex\\codex.exe" else "/opt/homebrew/bin/codex",
        if (builtin.os.tag == .windows) "C:\\Program Files (x86)\\Codex\\codex.exe" else "/usr/local/bin/codex",
        if (builtin.os.tag == .windows) "C:\\codex\\codex.exe" else "/usr/bin/codex",
    };
    for (static_candidates) |candidate| {
        if (fileExists(candidate)) {
            return allocator.dupe(u8, candidate) catch null;
        }
    }

    const home = platform.getHomeDir(allocator) catch return null;
    defer allocator.free(home);
    const home_candidates = [_][]const u8{
        ".local/bin",
        "bin",
        ".bun/bin",
        ".npm-global/bin",
    };
    for (home_candidates) |candidate_dir| {
        const candidate = std.fs.path.join(allocator, &.{ home, candidate_dir, binary_name }) catch continue;
        if (fileExists(candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }

    return null;
}

fn dupeFallbackModels(allocator: std.mem.Allocator) ![][]const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }

    for (codex_model_fallbacks) |model| {
        try result.append(allocator, try allocator.dupe(u8, model));
    }
    return result.toOwnedSlice(allocator);
}

fn loadCodexModelsInner(allocator: std.mem.Allocator) ![][]const u8 {
    const path = try resolveCodexStatePath(allocator, "models_cache.json");
    defer allocator.free(path);

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(bytes);

    return parseCodexModelsFromBytes(allocator, bytes);
}

fn parseCodexModelsFromBytes(allocator: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    const parsed = try std.json.parseFromSlice(struct {
        models: []const struct {
            slug: []const u8,
            visibility: ?[]const u8 = null,
        } = &.{},
    }, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var models: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (models.items) |item| allocator.free(item);
        models.deinit(allocator);
    }

    for (parsed.value.models) |model| {
        if (model.slug.len == 0) continue;
        if (model.visibility) |visibility| {
            if (!std.mem.eql(u8, visibility, "list")) continue;
        }
        if (containsString(models.items, model.slug)) continue;
        try models.append(allocator, try allocator.dupe(u8, model.slug));
    }

    if (models.items.len == 0) return error.CodexModelsUnavailable;
    return models.toOwnedSlice(allocator);
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

fn hasNullclawOpenAiCodexTokens(allocator: std.mem.Allocator) bool {
    const path = resolveHomeRelativePath(allocator, ".nullclaw", "auth.json") catch return false;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, 1024 * 1024) catch return false;
    defer allocator.free(bytes);

    return parseNullclawOpenAiCodexCredentialFromBytes(allocator, bytes);
}

fn parseNullclawOpenAiCodexCredentialFromBytes(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return false,
    };

    const provider_val = root_obj.get("openai-codex") orelse return false;
    const provider_obj = switch (provider_val) {
        .object => |obj| obj,
        else => return false,
    };

    return hasTokenField(provider_obj, "access_token") or hasTokenField(provider_obj, "refresh_token");
}

fn hasCodexCliTokens(allocator: std.mem.Allocator) bool {
    const path = resolveCodexStatePath(allocator, "auth.json") catch return false;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, 1024 * 1024) catch return false;
    defer allocator.free(bytes);

    return parseCodexCliAuthFromBytes(allocator, bytes);
}

fn parseCodexCliAuthFromBytes(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(struct {
        tokens: ?struct {
            access_token: ?[]const u8 = null,
            refresh_token: ?[]const u8 = null,
        } = null,
    }, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    const tokens = parsed.value.tokens orelse return false;
    if (tokens.access_token) |access_token| {
        if (access_token.len > 0) return true;
    }
    if (tokens.refresh_token) |refresh_token| {
        if (refresh_token.len > 0) return true;
    }
    return false;
}

fn hasTokenField(obj: std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return false;
    return switch (value) {
        .string => |s| s.len > 0,
        else => false,
    };
}

fn resolveCodexStatePath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    return resolveHomeRelativePath(allocator, ".codex", filename);
}

fn resolveHomeRelativePath(allocator: std.mem.Allocator, dir_name: []const u8, filename: []const u8) ![]u8 {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, dir_name, filename });
}

fn resolveFromPath(allocator: std.mem.Allocator, binary_name: []const u8) ?[]u8 {
    const env_path = std.process.getEnvVarOwned(allocator, "PATH") catch return null;
    defer allocator.free(env_path);

    const separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var path_it = std.mem.splitScalar(u8, env_path, separator);
    while (path_it.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = std.fs.path.join(allocator, &.{ entry, binary_name }) catch continue;
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        const file = std.fs.openFileAbsolute(path, .{}) catch return false;
        file.close();
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn runCommand(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) !CommandRunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, command);
    try argv.appendSlice(allocator, args);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .success = switch (result.term) {
            .Exited => |code| code == 0,
            else => false,
        },
    };
}

test "parseCodexModelsFromBytes parses visible model slugs" {
    const allocator = std.testing.allocator;
    const models = try parseCodexModelsFromBytes(allocator,
        \\{
        \\  "models": [
        \\    { "slug": "gpt-5.4", "visibility": "list" },
        \\    { "slug": "gpt-5.3-codex", "visibility": "hidden" },
        \\    { "slug": "gpt-5.2-codex", "visibility": "list" },
        \\    { "slug": "gpt-5.4", "visibility": "list" }
        \\  ]
        \\}
    );
    defer freeOwnedStrings(allocator, models);

    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gpt-5.4", models[0]);
    try std.testing.expectEqualStrings("gpt-5.2-codex", models[1]);
}

test "parseCodexCliAuthFromBytes accepts access token" {
    try std.testing.expect(parseCodexCliAuthFromBytes(std.testing.allocator,
        \\{
        \\  "tokens": {
        \\    "access_token": "abc",
        \\    "refresh_token": ""
        \\  }
        \\}
    ));
}

test "parseNullclawOpenAiCodexCredentialFromBytes accepts refresh token" {
    try std.testing.expect(parseNullclawOpenAiCodexCredentialFromBytes(std.testing.allocator,
        \\{
        \\  "openai-codex": {
        \\    "access_token": "",
        \\    "refresh_token": "refresh"
        \\  }
        \\}
    ));
}
