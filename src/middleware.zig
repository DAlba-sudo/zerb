//! Middleware helpers. zerb reuses httpz's middleware protocol unchanged
//! (`Config`, `init`, `execute`); the only zerb-specific concept is the
//! `HtmxOnly` adapter below, which is itself an httpz-protocol middleware.
const std = @import("std");
const httpz = @import("httpz");
const htmx = @import("htmx.zig");

/// Runs `M` only when `HX-Request: true`; other requests skip straight to
/// `executor.next()`. `Config` and `init` are forwarded unchanged, so the
/// result is registered like any other middleware:
/// `try server.middleware(zerb.HtmxOnly(M), cfg)`.
pub fn HtmxOnly(comptime M: type) type {
    return struct {
        inner: M,

        const Self = @This();

        pub const Config = M.Config;

        pub fn init(config: Config, mw: httpz.MiddlewareConfig) !Self {
            const inner = switch (comptime @typeInfo(@TypeOf(M.init)).@"fn".params.len) {
                1 => try M.init(config),
                2 => try M.init(config, mw),
                else => @compileError(@typeName(M) ++ ".init should accept 1 or 2 parameters"),
            };
            return .{ .inner = inner };
        }

        pub fn deinit(self: *Self) void {
            if (comptime std.meta.hasMethod(M, "deinit")) {
                self.inner.deinit();
            }
        }

        pub fn execute(self: *Self, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
            if (!htmx.Request.isHtmx(req)) {
                return executor.next();
            }
            return self.inner.execute(req, res, executor);
        }
    };
}

const TestExecutor = struct {
    next_calls: usize = 0,
    pub fn next(self: *TestExecutor) !void {
        self.next_calls += 1;
    }
};

const Stamp = struct {
    pub const Config = struct { value: []const u8 = "stamped" };
    cfg: Config,
    calls: usize = 0,

    pub fn init(cfg: Config) !Stamp {
        return .{ .cfg = cfg };
    }

    pub fn execute(self: *Stamp, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
        _ = req;
        self.calls += 1;
        res.header("X-Stamp", self.cfg.value);
        return executor.next();
    }
};

const TwoArgInit = struct {
    pub const Config = struct {};
    saw_arena: bool,
    pub fn init(_: Config, mw: httpz.MiddlewareConfig) !TwoArgInit {
        _ = try mw.arena.alloc(u8, 1);
        return .{ .saw_arena = true };
    }
    pub fn execute(_: *const TwoArgInit, _: *httpz.Request, _: *httpz.Response, executor: anytype) !void {
        return executor.next();
    }
};

test "HtmxOnly: skips inner middleware for non-htmx requests" {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    var mw = try HtmxOnly(Stamp).init(.{}, .{ .arena = ht.arena, .allocator = ht.arena });
    var executor = TestExecutor{};

    try mw.execute(ht.req, ht.res, &executor);
    try std.testing.expectEqual(1, executor.next_calls);
    try std.testing.expectEqual(0, mw.inner.calls);
    try ht.expectHeader("X-Stamp", null);
}

test "HtmxOnly: runs inner middleware for htmx requests" {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.header("HX-Request", "true");

    var mw = try HtmxOnly(Stamp).init(.{ .value = "yes" }, .{ .arena = ht.arena, .allocator = ht.arena });
    var executor = TestExecutor{};

    try mw.execute(ht.req, ht.res, &executor);
    try std.testing.expectEqual(1, executor.next_calls);
    try std.testing.expectEqual(1, mw.inner.calls);
    try ht.expectHeader("X-Stamp", "yes");
}

test "HtmxOnly: forwards two-argument init" {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    const mw = try HtmxOnly(TwoArgInit).init(.{}, .{ .arena = ht.arena, .allocator = ht.arena });
    try std.testing.expect(mw.inner.saw_arena);
}
