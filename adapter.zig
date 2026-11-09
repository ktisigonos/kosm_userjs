//! Firefox's `user.js`: one `user_pref("name", value);` line per pref. A pref holds a
//! bool, a 32-bit integer or a string, so a color or a joined value is written as a string and a
//! float is refused. Prefs are flat: a table's entries are prefs named by their whole name.

const std = @import("std");
const kosm = @import("kosm");
const parser = @import("parser.zig");

/// The adapter for `user.js` files; enables `generate`, `block` and `edit`. It claims no
/// extension, since `.js` is JavaScript: apps pass `.lang = "userjs"`.
pub const adapter: kosm.Adapter = .{
    .name = "userjs",
    .default_format = .{ .color = .hex, .boolean = .true_false },
    .format = format,
    .parser = parser.parse,
    .serialize = serialize,
    .comment = .{ .line = "//" },
};

/// Longest joined value kosm renders into one string.
const max_value_length = 64 * 1024;

fn serialize(writer: *std.Io.Writer, root: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    if (root != .table) return context.unsupported("a user.js is a table of prefs, not a {s}", .{@tagName(root)});
    for (root.table) |entry| {
        try writer.writeAll("user_pref(");
        try writeString(writer, entry.key);
        try writer.writeAll(", ");
        try writeValue(writer, entry.key, entry.value, context);
        try writer.writeAll(");\n");
    }
}

/// Writes one value; with `parser`, enables `edit`.
fn format(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    try writeValue(writer, "value", value, context);
}

fn writeValue(writer: *std.Io.Writer, name: []const u8, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .string => |text| try writeString(writer, text),
        .raw => |text| try writer.writeAll(text),
        .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| {
            if (std.math.cast(i32, integer) == null)
                return context.unsupported("'{s}': {d} does not fit a Firefox integer pref (32 bits)", .{ name, integer });
            try writer.print("{d}", .{integer});
        },
        .float => return context.unsupported("'{s}': Firefox prefs hold no floats; pass the number as a string", .{name}),
        .color, .joined => {
            var buffer: [max_value_length]u8 = undefined;
            var rendered: std.Io.Writer = .fixed(&buffer);
            writePlain(&rendered, name, value, context) catch |err| switch (err) {
                error.WriteFailed => return context.unsupported("'{s}': the value is longer than {d} bytes", .{ name, max_value_length }),
                error.UnsupportedValue => return error.UnsupportedValue,
            };
            try writeString(writer, rendered.buffered());
        },
        .list, .table => return context.unsupported("'{s}': a pref holds one plain value, not a {s}", .{ name, @tagName(value) }),
    }
}

/// A value's text inside a string: parts of a joined value are written back to back.
fn writePlain(writer: *std.Io.Writer, name: []const u8, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .string, .raw => |text| try writer.writeAll(text),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try context.writeFloat(writer, float),
        .boolean => |boolean| try context.writeBoolean(writer, boolean),
        .color => |color| try context.writeColor(writer, color),
        .joined => |parts| for (parts) |part| try writePlain(writer, name, part, context),
        .list, .table => return context.unsupported("'{s}': a pref holds one plain value, not a {s}", .{ name, @tagName(value) }),
    }
}

/// A JavaScript string in double quotes, with the escapes Firefox's pref parser reads.
fn writeString(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try writer.print("\\x{x:0>2}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

const testing = std.testing;

fn serializeForTest(root: kosm.Value, output: *std.Io.Writer.Allocating) !void {
    var context: kosm.Adapter.Context = .{ .format = adapter.default_format.resolve() };
    try serialize(&output.writer, root, &context);
}

test "prefs are user_pref lines, colors and joined values as strings" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const root: kosm.Value = .{ .table = &.{
        .{ .key = "zen.theme.accent-color", .value = .{ .color = try kosm.Color.parseHex("#268078") } },
        .{ .key = "zen.view.window.scheme", .value = .{ .integer = 0 } },
        .{ .key = "toolkit.legacyUserProfileCustomizations.stylesheets", .value = .{ .boolean = true } },
        .{ .key = "layout.css.devPixelsPerPx", .value = .{ .joined = &.{.{ .float = 1.25 }} } },
        .{ .key = "dom.offset", .value = .{ .integer = -2147483648 } },
    } };
    try serializeForTest(root, &output);
    try testing.expectEqualStrings(
        \\user_pref("zen.theme.accent-color", "#268078");
        \\user_pref("zen.view.window.scheme", 0);
        \\user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
        \\user_pref("layout.css.devPixelsPerPx", "1.25");
        \\user_pref("dom.offset", -2147483648);
        \\
    , output.written());
}

test "strings are escaped so Firefox reads them back unchanged" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = .{ .format = adapter.default_format.resolve() };
    try format(&output.writer, .{ .string = "say \"hi\"\\\n\t\u{1}" }, &context);
    try testing.expectEqualStrings("\"say \\\"hi\\\"\\\\\\n\\t\\x01\"", output.written());
}

test "booleans are always true or false, whatever the file's boolean spelling" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = .{ .format = (kosm.Format{ .boolean = .yes_no }).orElse(adapter.default_format).resolve() };
    try format(&output.writer, .{ .boolean = false }, &context);
    try testing.expectEqualStrings("false", output.written());
}

test "values a pref cannot hold are refused, naming the pref" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = .{ .format = adapter.default_format.resolve() };
    try testing.expectError(error.UnsupportedValue, serialize(&output.writer, .{ .table = &.{.{ .key = "a.b", .value = .{ .float = 1.5 } }} }, &context));
    try testing.expectEqualStrings("'a.b': Firefox prefs hold no floats; pass the number as a string", context.message());
    try testing.expectError(error.UnsupportedValue, serialize(&output.writer, .{ .table = &.{.{ .key = "a.c", .value = .{ .integer = 2147483648 } }} }, &context));
    try testing.expectEqualStrings("'a.c': 2147483648 does not fit a Firefox integer pref (32 bits)", context.message());
    try testing.expectError(error.UnsupportedValue, serialize(&output.writer, .{ .table = &.{.{ .key = "a", .value = .{ .table = &.{} } }} }, &context));
    try testing.expectEqualStrings("'a': a pref holds one plain value, not a table", context.message());
}

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    plan: kosm.Plan,
    diagnostics: kosm.Diagnostics = .{},
    warnings: kosm.Warnings = undefined,
    home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    output: kosm.Output = undefined,

    fn init(fixture: *Fixture, path: []const u8, contents: []const u8) !void {
        fixture.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .plan = .init(testing.allocator, testing.io) };
        if (std.Io.Dir.path.dirname(path)) |parent| try fixture.tmp.dir.createDirPath(testing.io, parent);
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = contents });
        fixture.warnings = .init(fixture.arena.allocator());
        const length = try fixture.tmp.dir.realPath(testing.io, &fixture.home_buffer);
        fixture.output = .{
            .allocator = fixture.arena.allocator(),
            .home = fixture.home_buffer[0..length],
            .adapters = &.{adapter},
            .plan = &fixture.plan,
            .diagnostics = &fixture.diagnostics,
            .warnings = &fixture.warnings,
            .app = "zen",
        };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.plan.deinit();
        fixture.arena.deinit();
        fixture.tmp.cleanup();
    }
};

const real_user_js =
    \\/******
    \\ * name: my user.js
    \\ ******/
    \\user_pref("browser.startup.page", 3); // resume the session
    \\user_pref("zen.theme.accent-color", '#080808');
    \\user_pref("zen.view.window.scheme",0);
    \\
    \\// look
    \\user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", false);
    \\
;

test "edit changes only the values' bytes of a real user.js, by quoted pref name" {
    var fixture: Fixture = undefined;
    try fixture.init(".zen/a.default/user.js", real_user_js);
    defer fixture.deinit();
    var prefs = try fixture.output.edit(.{ .files = "~/.zen/*/user.js", .lang = "userjs" });
    try prefs.set("\"zen.theme.accent-color\"", kosm.hex("268078"));
    try prefs.set("\"zen.view.window.scheme\"", 1);
    try prefs.set("\"toolkit.legacyUserProfileCustomizations.stylesheets\"", true);
    try testing.expectError(error.NoMatch, prefs.set("\"zen.theme.gradient\"", true));
    try testing.expectError(error.NoMatch, prefs.set("zen.theme.accent-color", kosm.hex("268078")));

    try testing.expectEqualStrings(
        \\/******
        \\ * name: my user.js
        \\ ******/
        \\user_pref("browser.startup.page", 3); // resume the session
        \\user_pref("zen.theme.accent-color", "#268078");
        \\user_pref("zen.view.window.scheme",1);
        \\
        \\// look
        \\user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
        \\
    , fixture.plan.files.items[0].new);
}

test "a block of prefs keeps the user's own prefs around it" {
    var fixture: Fixture = undefined;
    try fixture.init(".zen/a.default/user.js", "user_pref(\"browser.startup.page\", 3);\n");
    defer fixture.deinit();
    try fixture.output.block(.{ .file = "~/.zen/a.default/user.js", .id = "zen", .lang = "userjs" }, kosm.Value{ .table = &.{
        .{ .key = "zen.view.window.scheme", .value = .{ .integer = 0 } },
    } });
    try testing.expectEqualStrings(
        \\user_pref("browser.startup.page", 3);
        \\// kosm:begin zen
        \\user_pref("zen.view.window.scheme", 0);
        \\// kosm:end
        \\
    , fixture.plan.files.items[0].new);
}
