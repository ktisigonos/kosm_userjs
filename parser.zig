//! Reads a `user.js` into the tree kosm matches paths against: every
//! `user_pref("name", value);` statement is one entry of the file's table, keyed by the pref's
//! whole name as spelled between its quotes. A value's bytes are its literal, quotes included.
//! `//`, `/* */` and `#` comments are skipped, as Firefox skips them.

const std = @import("std");
const kosm = @import("kosm");
const Node = kosm.Adapter.Node;

/// An adapter `parser`: the file as one table of prefs. Nodes point into `source`.
pub fn parse(allocator: std.mem.Allocator, source: []const u8, context: *kosm.Adapter.Context) kosm.Adapter.ParseError!Node {
    var reader: Reader = .{ .source = source, .context = context };
    var entries: std.ArrayList(Node) = .empty;
    while (try reader.skipBlank()) {
        try entries.append(allocator, try reader.statement());
    }
    return .{ .key = null, .kind = .table, .position = 0, .value = .{ .start = 0, .end = source.len }, .children = entries.items };
}

const Reader = struct {
    source: []const u8,
    context: *kosm.Adapter.Context,
    index: usize = 0,

    /// Skips whitespace and comments; false at the end of the file.
    fn skipBlank(reader: *Reader) kosm.Adapter.ParseError!bool {
        const source = reader.source;
        while (reader.index < source.len) {
            const rest = source[reader.index..];
            if (std.ascii.isWhitespace(rest[0])) {
                reader.index += 1;
            } else if (std.mem.startsWith(u8, rest, "//") or rest[0] == '#') {
                reader.index = std.mem.indexOfScalarPos(u8, source, reader.index, '\n') orelse source.len;
            } else if (std.mem.startsWith(u8, rest, "/*")) {
                const close = std.mem.indexOfPos(u8, source, reader.index + 2, "*/") orelse
                    return reader.fail("a /* comment is never closed", .{});
                reader.index = close + 2;
            } else return true;
        }
        return false;
    }

    /// `user_pref("name", value);`
    fn statement(reader: *Reader) kosm.Adapter.ParseError!Node {
        const start = reader.index;
        while (reader.index < reader.source.len and isNameByte(reader.source[reader.index])) reader.index += 1;
        const function = reader.source[start..reader.index];
        if (!std.mem.eql(u8, function, "user_pref")) {
            if (function.len == 0) return reader.fail("expected user_pref(\"name\", value);", .{});
            return reader.fail("'{s}' is not allowed in user.js, only user_pref", .{function});
        }
        try reader.expect('(');
        const name = try reader.string() orelse return reader.fail("expected the pref's name as a string", .{});
        try reader.expect(',');
        _ = try reader.skipBlank();
        const value = try reader.literal();
        try reader.expect(')');
        try reader.expect(';');
        return .{
            .key = reader.source[name.start + 1 .. name.end - 1],
            .kind = .scalar,
            .position = name.start,
            .value = value,
        };
    }

    fn expect(reader: *Reader, byte: u8) kosm.Adapter.ParseError!void {
        const after_previous = reader.index;
        _ = try reader.skipBlank();
        if (reader.index >= reader.source.len or reader.source[reader.index] != byte) {
            // The line where the missing byte belonged, not the next line's.
            reader.index = after_previous;
            return reader.fail("expected '{c}'", .{byte});
        }
        reader.index += 1;
    }

    /// A string, `true`, `false` or an integer; its bytes.
    fn literal(reader: *Reader) kosm.Adapter.ParseError!kosm.Adapter.Range {
        if (try reader.string()) |range| return range;
        const start = reader.index;
        const source = reader.source;
        if (reader.index < source.len and (source[reader.index] == '-' or source[reader.index] == '+')) reader.index += 1;
        const digits_start = reader.index;
        while (reader.index < source.len and std.ascii.isDigit(source[reader.index])) reader.index += 1;
        if (reader.index < source.len and source[reader.index] == '.' and reader.index > digits_start)
            return reader.fail("Firefox prefs hold no floats; write the number as a string", .{});
        if (reader.index > digits_start) return .{ .start = start, .end = reader.index };
        reader.index = start;
        while (reader.index < source.len and isNameByte(source[reader.index])) reader.index += 1;
        const word = source[start..reader.index];
        if (std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false")) return .{ .start = start, .end = reader.index };
        return reader.fail("a pref's value is a string, an integer, true or false", .{});
    }

    /// A string in `"` or `'` with `\` escapes, quotes included; null when none starts here.
    fn string(reader: *Reader) kosm.Adapter.ParseError!?kosm.Adapter.Range {
        _ = try reader.skipBlank();
        const source = reader.source;
        if (reader.index >= source.len) return null;
        const quote = source[reader.index];
        if (quote != '"' and quote != '\'') return null;
        const start = reader.index;
        reader.index += 1;
        while (reader.index < source.len) : (reader.index += 1) {
            switch (source[reader.index]) {
                '\\' => reader.index += 1,
                '\n' => break,
                else => |byte| if (byte == quote) {
                    reader.index += 1;
                    return .{ .start = start, .end = reader.index };
                },
            }
        }
        reader.index = start;
        return reader.fail("a string is never closed", .{});
    }

    fn fail(reader: *const Reader, comptime format: []const u8, arguments: anytype) error{InvalidSyntax} {
        const line = 1 + std.mem.count(u8, reader.source[0..@min(reader.index, reader.source.len)], "\n");
        return reader.context.invalidSyntax("line {d}: " ++ format, .{line} ++ arguments);
    }
};

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

const testing = std.testing;

fn parseForTest(allocator: std.mem.Allocator, source: []const u8) !Node {
    var context: kosm.Adapter.Context = .{ .format = kosm.Format.kosm_default };
    return parse(allocator, source, &context);
}

fn valueText(source: []const u8, node: Node) []const u8 {
    return source[node.value.?.start..node.value.?.end];
}

test "every user_pref is an entry keyed by its whole name, comments skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source =
        \\// arkenfox-style header
        \\/* a block
        \\   comment with user_pref("not.a.pref", 1); inside */
        \\user_pref("zen.theme.accent-color", "#080808");
        \\user_pref( 'browser.display.background_color' ,'#000000' ) ;
        \\  # an old-style comment
        \\user_pref("zen.view.window.scheme", 0); user_pref("layout.css.devPixelsPerPx", "1.25");
        \\user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true); // trailing comment
        \\user_pref("browser.startup.homepage", "https://example.com/\"quoted\"");
        \\user_pref("dom.offset", -12);
    ;
    const root = try parseForTest(arena.allocator(), source);
    const entries = root.children;
    try testing.expectEqual(7, entries.len);
    try testing.expectEqualStrings("zen.theme.accent-color", entries[0].key.?);
    try testing.expectEqualStrings("\"#080808\"", valueText(source, entries[0]));
    try testing.expectEqualStrings("browser.display.background_color", entries[1].key.?);
    try testing.expectEqualStrings("'#000000'", valueText(source, entries[1]));
    try testing.expectEqualStrings("0", valueText(source, entries[2]));
    try testing.expectEqualStrings("layout.css.devPixelsPerPx", entries[3].key.?);
    try testing.expectEqualStrings("true", valueText(source, entries[4]));
    try testing.expectEqualStrings("\"https://example.com/\\\"quoted\\\"\"", valueText(source, entries[5]));
    try testing.expectEqualStrings("-12", valueText(source, entries[6]));
}

test "an empty file or one of only comments has no prefs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(0, (try parseForTest(arena.allocator(), "")).children.len);
    try testing.expectEqual(0, (try parseForTest(arena.allocator(), "// only\n/* comments */\n")).children.len);
}

test "what Firefox would not read is an error naming the line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = .{ .format = kosm.Format.kosm_default };
    const cases = [_][2][]const u8{
        .{ "user_pref(\"a\", 1);\npref(\"b\", 2);\n", "line 2: 'pref' is not allowed in user.js, only user_pref" },
        .{ "user_pref(\"a\", 1)\n", "line 1: expected ';'" },
        .{ "user_pref(\"a\", 1.5);", "line 1: Firefox prefs hold no floats; write the number as a string" },
        .{ "user_pref(\"a\", yes);", "line 1: a pref's value is a string, an integer, true or false" },
        .{ "user_pref(\"a, 1);", "line 1: a string is never closed" },
        .{ "user_pref(a, 1);", "line 1: expected the pref's name as a string" },
        .{ "\n\n/* open", "line 3: a /* comment is never closed" },
        .{ "\"stray\"", "line 1: expected user_pref(\"name\", value);" },
    };
    for (cases) |case| {
        try testing.expectError(error.InvalidSyntax, parse(arena.allocator(), case[0], &context));
        try testing.expectEqualStrings(case[1], context.message());
    }
}
