//! htmx v4 header vocabulary. The request side is a set of typed readers over
//! the v4 request headers; the response side is `Headers`, the only place hx
//! response headers are written.
const std = @import("std");
const httpz = @import("httpz");

/// Value of `HX-Request-Type` in v4.
pub const RequestType = enum { partial, full };

/// Readers for htmx v4 request headers. Names are passed to `req.header`
/// lowercase, as httpz requires.
pub const Request = struct {
    /// `HX-Request: true`
    pub fn isHtmx(req: *const httpz.Request) bool {
        return isTrue(req.header("hx-request"));
    }

    /// `HX-Request-Type`
    pub fn requestType(req: *const httpz.Request) ?RequestType {
        const value = req.header("hx-request-type") orelse return null;
        if (std.mem.eql(u8, value, "partial")) return .partial;
        if (std.mem.eql(u8, value, "full")) return .full;
        return null;
    }

    /// `HX-Current-URL`
    pub fn currentUrl(req: *const httpz.Request) ?[]const u8 {
        return req.header("hx-current-url");
    }

    /// `HX-Source`
    pub fn source(req: *const httpz.Request) ?[]const u8 {
        return req.header("hx-source");
    }

    /// `HX-Target`
    pub fn target(req: *const httpz.Request) ?[]const u8 {
        return req.header("hx-target");
    }

    /// `HX-Boosted: true`
    pub fn boosted(req: *const httpz.Request) bool {
        return isTrue(req.header("hx-boosted"));
    }

    /// `HX-History-Restore-Request: true`
    pub fn historyRestore(req: *const httpz.Request) bool {
        return isTrue(req.header("hx-history-restore-request"));
    }

    fn isTrue(value: ?[]const u8) bool {
        const v = value orelse return false;
        return std.mem.eql(u8, v, "true");
    }
};

/// One field per htmx v4 response header. `null`/`false` means "do not
/// send". Values are raw header strings: `reswap` takes the full swap spec
/// (`"outerHTML show:top"`), `trigger` takes an event name or the JSON object
/// form, `push_url`/`replace_url` accept `"false"`.
///
/// Two places write into it: the `.htmx()` route builder (recorded once, for
/// every request) and a transformer that takes a `*Headers` parameter (per
/// request, see `Server.Transformer`). Strings are never copied here, so a
/// per-request value must be static or allocated in `req.arena`.
pub const Headers = struct {
    trigger: ?[]const u8 = null, // HX-Trigger
    location: ?[]const u8 = null, // HX-Location
    redirect: ?[]const u8 = null, // HX-Redirect
    refresh: bool = false, // HX-Refresh: true
    retarget: ?[]const u8 = null, // HX-Retarget
    reswap: ?[]const u8 = null, // HX-Reswap
    reselect: ?[]const u8 = null, // HX-Reselect
    push_url: ?[]const u8 = null, // HX-Push-Url
    replace_url: ?[]const u8 = null, // HX-Replace-Url

    /// Emits one `res.header(...)` per set field. Slices are not copied:
    /// they must be static, server-arena, or `res.arena` owned.
    pub fn apply(self: Headers, res: *httpz.Response) void {
        if (self.trigger) |v| res.header("HX-Trigger", v);
        if (self.location) |v| res.header("HX-Location", v);
        if (self.redirect) |v| res.header("HX-Redirect", v);
        if (self.refresh) res.header("HX-Refresh", "true");
        if (self.retarget) |v| res.header("HX-Retarget", v);
        if (self.reswap) |v| res.header("HX-Reswap", v);
        if (self.reselect) |v| res.header("HX-Reselect", v);
        if (self.push_url) |v| res.header("HX-Push-Url", v);
        if (self.replace_url) |v| res.header("HX-Replace-Url", v);
    }

    /// `base` with every field that is set in `over` replaced by `over`'s
    /// value. Fields `over` leaves at `null`/`false` keep `base`'s value.
    /// This is the per-request merge rule: route defaults as `base`,
    /// transformer writes as `over`.
    pub fn overlay(base: Headers, over: Headers) Headers {
        var out = base;
        inline for (std.meta.fields(Headers)) |f| {
            if (comptime f.type == bool) {
                if (@field(over, f.name)) @field(out, f.name) = true;
            } else {
                if (@field(over, f.name)) |v| @field(out, f.name) = v;
            }
        }
        return out;
    }
};

test "htmx.Request: readers" {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    try std.testing.expect(!Request.isHtmx(ht.req));
    try std.testing.expect(!Request.boosted(ht.req));
    try std.testing.expect(!Request.historyRestore(ht.req));
    try std.testing.expectEqual(null, Request.requestType(ht.req));
    try std.testing.expectEqual(null, Request.currentUrl(ht.req));

    ht.header("HX-Request", "true");
    ht.header("HX-Request-Type", "partial");
    ht.header("HX-Current-URL", "http://localhost/users");
    ht.header("HX-Source", "#btn");
    ht.header("HX-Target", "#row");
    ht.header("HX-Boosted", "true");
    ht.header("HX-History-Restore-Request", "true");

    try std.testing.expect(Request.isHtmx(ht.req));
    try std.testing.expectEqual(RequestType.partial, Request.requestType(ht.req).?);
    try std.testing.expectEqualStrings("http://localhost/users", Request.currentUrl(ht.req).?);
    try std.testing.expectEqualStrings("#btn", Request.source(ht.req).?);
    try std.testing.expectEqualStrings("#row", Request.target(ht.req).?);
    try std.testing.expect(Request.boosted(ht.req));
    try std.testing.expect(Request.historyRestore(ht.req));
}

test "htmx.Headers: apply emits only set fields" {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    const headers = Headers{
        .trigger = "user:renamed",
        .refresh = true,
        .retarget = "closest tr",
        .reswap = "outerHTML",
        .push_url = "false",
    };
    headers.apply(ht.res);

    try ht.expectHeader("HX-Trigger", "user:renamed");
    try ht.expectHeader("HX-Refresh", "true");
    try ht.expectHeader("HX-Retarget", "closest tr");
    try ht.expectHeader("HX-Reswap", "outerHTML");
    try ht.expectHeader("HX-Push-Url", "false");
    try ht.expectHeader("HX-Location", null);
    try ht.expectHeader("HX-Redirect", null);
    try ht.expectHeader("HX-Reselect", null);
    try ht.expectHeader("HX-Replace-Url", null);
}

test "htmx.Headers: overlay keeps base fields the override leaves unset" {
    const base = Headers{ .trigger = "base", .reswap = "outerHTML", .refresh = false };
    const over = Headers{ .trigger = "over", .retarget = "#x", .refresh = true };
    const merged = base.overlay(over);
    try std.testing.expectEqualStrings("over", merged.trigger.?);
    try std.testing.expectEqualStrings("outerHTML", merged.reswap.?);
    try std.testing.expectEqualStrings("#x", merged.retarget.?);
    try std.testing.expect(merged.refresh);
    try std.testing.expectEqual(null, merged.push_url);
    // An empty override is the identity.
    try std.testing.expectEqualStrings("base", base.overlay(.{}).trigger.?);
}

test "htmx.Headers: empty applies nothing" {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    (Headers{}).apply(ht.res);
    // Only Content-Length is emitted by httpz itself.
    try ht.expectHeaderCount(1);
}
