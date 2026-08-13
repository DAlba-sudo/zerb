const std = @import("std");

const httpz = @import("httpz");
const zmpl = @import("zmpl").zmpl;

pub const Error = error{
    Generic,
};

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
};

pub const TemplateRouteContext = struct {
    templates: []const []const u8,
    data: *const fn (res: *httpz.Request) ?zmpl.Data,
};

/// This is a server struct that can be used to implement a server.
/// You can call:
///     - `.api(...)`
///     - `.page(...)`
pub const Server = struct {
    // This is the underlying httpz server that will actually
    // serve the traffic.
    httpzServer: httpz.Server(void),
    allocator: std.mem.Allocator,
    io: std.Io,
    routeMap: std.StringHashMap(TemplateRouteContext),

    // httpz.Server(void) actions are plain functions with no handler context,
    // so `templateHandler` reaches the active server through this.
    var active: ?*Server = null;

    pub fn create(io: std.Io, allocator: std.mem.Allocator, port: u16) !*Server {
        const httpzServer = try httpz.Server(void).init(io, allocator, .{
            .address = .all(port),
            .request = .{
                .max_form_count = 20,
            },
        }, {});

        const s = allocator.create(Server) catch |err| {
            return err;
        };
        s.httpzServer = httpzServer;
        s.allocator = allocator;
        s.io = io;
        s.routeMap = std.StringHashMap(TemplateRouteContext).init(allocator);
        active = s;

        return s;
    }

    pub fn deinit(self: *@This()) void {
        self.httpzServer.deinit();
        self.httpzServer.stop();
    }

    /// Call this when you want to register a function that will not be routed
    /// through the zmpl templating logic.
    pub fn api(self: *@This(), method: Method, path: []const u8, handler: fn (req: *httpz.Request, res: *httpz.Response) Error!void) !void {
        var router = try self.httpzServer.router(.{});
        switch (method) {
            .GET => router.get(path, handler, .{}),
            .POST => router.post(path, handler, .{}),
            .PUT => router.put(path, handler, .{}),
            .DELETE => router.delete(path, handler, .{}),
        }
    }

    /// Call this when you want to register a templated page.
    pub fn page(self: *@This(), path: []const u8, templates: []const []const u8, data: *const fn (res: *httpz.Request) ?zmpl.Data) !void {
        try self.routeMap.put(path, TemplateRouteContext{
            .templates = templates,
            .data = data,
        });

        var router = try self.httpzServer.router(.{});
        router.get(path, templateHandler, .{});
    }

    fn templateHandler(req: *httpz.Request, res: *httpz.Response) !void {
        const self = active orelse return;

        // We will retrieve the route context from the route map and
        // then render the templates with the data.
        if (self.routeMap.get(req.url.path)) |v| {
            // we want to read the templates
            // we want to render any relevant data
            // we want to execute it on the output writer.
            for (v.templates) |template| {
                const found = zmpl.find(template) orelse continue;
                var templateData = v.data(req) orelse zmpl.Data.init(self.io, req.arena);

                res.body = try found.render(self.io, &templateData, null, null, &.{}, .{});
            }
        }
    }
};
