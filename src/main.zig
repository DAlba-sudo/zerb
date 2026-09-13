//! Demo application for zerb: one `.api` route, two `.htmx` routes, two
//! `.page` routes, a global middleware and a custom error mapper.
//!
//! Run with `zig build run`, then try:
//!
//!   curl -i localhost:8080/api/users/1
//!   curl -i localhost:8080/api/users/missing
//!   curl -i localhost:8080/users/1
//!   curl -i localhost:8080/users/missing              # 404 via transformer error
//!   curl -i -X POST localhost:8080/users/1/rename     # dynamic HX-Trigger
//!   curl -i -X POST localhost:8080/users/same/rename  # HX-Reswap: none
//!   curl -i -X POST localhost:8080/users/missing/rename  # 404, HX-Retarget only
//!   curl -i -X DELETE localhost:8080/users/1
//!   curl -i localhost:8080/hello
//!   curl -i localhost:8080/nope
const std = @import("std");
const httpz = @import("httpz");
const zerb = @import("zerb");

const App = struct {
    greeting: []const u8,

    pub fn find(self: *App, id: []const u8) ?User {
        _ = self;
        if (std.mem.eql(u8, id, "missing")) return null;
        return .{ .id = id, .name = "Ada" };
    }
};
const User = struct { id: []const u8, name: []const u8 };
const Ctx = struct { site: []const u8 = "zerb demo" };

const Server = zerb.Server(.{ .App = *App, .Context = Ctx });

/// Plain httpz-protocol middleware: stamps every response.
const RequestId = struct {
    pub const Config = struct { header: []const u8 = "X-Request-Id" };
    cfg: Config,

    pub fn init(cfg: Config) !RequestId {
        return .{ .cfg = cfg };
    }

    pub fn execute(self: *const RequestId, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
        _ = req;
        res.header(self.cfg.header, "static-for-brevity");
        return executor.next();
    }
};

pub fn main(init: std.process.Init) !void {
    var app = App{ .greeting = "hello" };

    const server = try Server.init(init.io, init.gpa, &app, .{
        // Full httpz.Config, untouched by zerb.
        .httpz = .{
            .address = .all(8080),
            .request = .{ .max_form_count = 20 },
        },
        .zmpl = .{
            .context = siteContext,
            .error_templates = &.{ "errors/show", "layouts/app" },
        },
        .errors = .{ .map = mapError },
    });
    defer server.deinit();

    // Middleware: global, before any route.
    const rid = try server.middleware(RequestId, .{});
    try server.use(&.{rid});

    // .api(): plain JSON. error.NotFound -> 404 {"error":{...}}.
    try server.api(.GET, "/api/users/:id", getUser, .{});

    // .htmx(): fragment "users/row" (no layout), swapped over the caller's
    // row. The builder records defaults; `renameUser` overrides HX-Trigger
    // with a per-request value, sends `HX-Reswap: none` when nothing
    // changed, and on an unknown id retargets the error body to `#errors`
    // and returns error.NotFound (404, route defaults not sent).
    _ = (try server.htmx(.POST, "/users/:id/rename", .{}))
        .templates(&.{"users/row"})
        .data("user", renameUser)
        .retarget("closest tr")
        .reswap("outerHTML")
        .trigger("user:renamed");

    // .htmx() with no template: headers only. The transformer decides
    // where the client goes next.
    _ = (try server.htmx(.DELETE, "/users/:id", .{}))
        .data("user", deleteUser)
        .trigger("user:deleted");

    // .page(): "users/show" inside "layouts/app". `loadUser` is the same
    // `!?T` transformer shape without `hx`; error.NotFound -> 404 page.
    _ = (try server.page("/users/:id", &.{ "users/show", "layouts/app" }, .{}))
        .data("user", loadUser)
        .data("greeting", greeting);

    _ = (try server.page("/hello", &.{ "hello", "layouts/app" }, .{}))
        .data("message", greeting);

    std.log.info("zerb demo listening on http://localhost:8080", .{});
    try server.listen();
}

fn getUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id") orelse return error.BadRequest;
    const user = app.find(id) orelse return error.NotFound;
    try res.json(user, .{});
}

/// `!?T`: a missing user is a 404, not a template error.
fn loadUser(app: *App, req: *httpz.Request) !?User {
    const id = req.param("id") orelse return error.BadRequest;
    return app.find(id) orelse error.NotFound;
}

/// `!?T` plus the per-request htmx headers. Strings written into `hx`
/// are not copied, so dynamic values live in `req.arena`.
fn renameUser(app: *App, req: *httpz.Request, hx: *zerb.htmx.Headers) !?User {
    const id = req.param("id") orelse return error.BadRequest;
    const user = app.find(id) orelse {
        // The error page replaces the contents of #errors instead of the row.
        hx.retarget = "#errors";
        hx.reswap = "innerHTML";
        return error.NotFound;
    };
    if (std.mem.eql(u8, id, "same")) {
        // Nothing changed: keep the row, skip the event.
        hx.reswap = "none";
        return user;
    }
    hx.trigger = try std.fmt.allocPrint(req.arena, "{{\"user:renamed\":{{\"id\":\"{s}\"}}}}", .{id});
    return user;
}

/// Header-only route: the value returned is never rendered (no template),
/// so `?void` says so; the headers are the whole response.
fn deleteUser(app: *App, req: *httpz.Request, hx: *zerb.htmx.Headers) !?void {
    const id = req.param("id") orelse return error.BadRequest;
    _ = app.find(id) orelse return error.NotFound;
    hx.push_url = "/users";
    return {};
}

fn greeting(app: *App, req: *httpz.Request) ?[]const u8 {
    _ = req;
    return app.greeting;
}

fn siteContext(app: *App, req: *httpz.Request) Ctx {
    _ = app;
    _ = req;
    return .{};
}

fn mapError(app: *App, err: anyerror, req: *httpz.Request) zerb.ErrorResponse {
    _ = app;
    return switch (err) {
        error.UserSuspended => .{ .status = 423, .code = "user_suspended", .message = "User is suspended" },
        else => zerb.defaultErrorMapper(err, req),
    };
}
