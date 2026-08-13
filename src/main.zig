const std = @import("std");
const zerb = @import("zerb");
const zmpl = @import("zmpl").zmpl;
const httpz = @import("httpz");

// `helloDataFunc` only receives the request, so the io instance is stashed here.
var app_io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    app_io = init.io;
    var s = try zerb.Server.create(init.io, init.gpa, 8080);
    defer s.deinit();

    try s.api(.GET, "/api/hello", helloHandler);
    try s.page("/hello", &.{"hello"}, helloDataFunc);

    try s.httpzServer.listen();
}

fn helloHandler(req: *httpz.Request, res: *httpz.Response) zerb.ServerError!void {
    _ = req;
    res.body = "Hello, world!";
}

fn helloDataFunc(req: *httpz.Request) ?zmpl.Data {
    var data = zmpl.Data.init(app_io, req.arena);
    const root = data.object() catch return null;
    _ = root.put("message", data.string("Hello, World!")) catch return null;

    return data;
}
