//! Firefox's user.js: the `userjs` adapter, for Firefox and the browsers built on it (D96).

const std = @import("std");

/// Reads and writes `user.js` files.
pub const adapter = @import("adapter.zig").adapter;

test {
    std.testing.refAllDecls(@This());
    _ = @import("adapter.zig");
    _ = @import("parser.zig");
}
