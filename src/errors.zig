//! Error vocabulary shared by every route kind: the canonical error set, the
//! wire shape an error becomes, and the default mapping between the two.
const std = @import("std");
const httpz = @import("httpz");

/// Canonical error set. Any of these returned from an action maps to the
/// matching status through `defaultErrorMapper`; other errors map to 500.
pub const HttpError = error{
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    Conflict,
    UnprocessableEntity,
    Internal,
};

/// What an error becomes. Serialized as `{"error": {...}}` for `.api` routes;
/// exposed as `.error.status / .error.code / .error.message` to error
/// templates for `.htmx` and `.page` routes.
pub const ErrorResponse = struct {
    status: u16,
    /// Stable, machine-readable, snake_case (e.g. "not_found").
    code: []const u8,
    /// Human-readable. Must outlive the request (static or `req.arena`).
    message: []const u8,
    /// Optional structured payload, serialized verbatim.
    details: ?std.json.Value = null,
};

/// Default `anyerror -> ErrorResponse` table. Users compose with it from a
/// custom mapper via `else => zerb.defaultErrorMapper(err, req)`.
pub fn defaultErrorMapper(err: anyerror, req: *httpz.Request) ErrorResponse {
    _ = req;
    return switch (err) {
        error.BadRequest => .{ .status = 400, .code = "bad_request", .message = "Bad request" },
        error.Unauthorized => .{ .status = 401, .code = "unauthorized", .message = "Unauthorized" },
        error.Forbidden => .{ .status = 403, .code = "forbidden", .message = "Forbidden" },
        error.NotFound => .{ .status = 404, .code = "not_found", .message = "Not found" },
        error.Conflict => .{ .status = 409, .code = "conflict", .message = "Conflict" },
        error.UnprocessableEntity => .{ .status = 422, .code = "unprocessable", .message = "Unprocessable entity" },
        else => .{ .status = 500, .code = "internal_error", .message = "Internal server error" },
    };
}

/// The envelope written for `.api` errors and by `uncaughtError`.
pub const internal_error: ErrorResponse = .{
    .status = 500,
    .code = "internal_error",
    .message = "Internal server error",
};

test "defaultErrorMapper: canonical table" {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    const cases = [_]struct { err: anyerror, status: u16, code: []const u8 }{
        .{ .err = error.BadRequest, .status = 400, .code = "bad_request" },
        .{ .err = error.Unauthorized, .status = 401, .code = "unauthorized" },
        .{ .err = error.Forbidden, .status = 403, .code = "forbidden" },
        .{ .err = error.NotFound, .status = 404, .code = "not_found" },
        .{ .err = error.Conflict, .status = 409, .code = "conflict" },
        .{ .err = error.UnprocessableEntity, .status = 422, .code = "unprocessable" },
        .{ .err = error.Internal, .status = 500, .code = "internal_error" },
        .{ .err = error.SomethingElse, .status = 500, .code = "internal_error" },
    };
    for (cases) |c| {
        const er = defaultErrorMapper(c.err, ht.req);
        try std.testing.expectEqual(c.status, er.status);
        try std.testing.expectEqualStrings(c.code, er.code);
        try std.testing.expect(er.details == null);
    }
}
