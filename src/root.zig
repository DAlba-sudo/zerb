//! zerb: a thin layer over httpz (HTTP server) and zmpl (templates) that
//! treats htmx as a first-class response concern.
//!
//! Everything user code touches is either a top-level declaration here or a
//! member of `zerb.Server(spec)`. See `docs/interface-design.md`.
const std = @import("std");

const server = @import("server.zig");
const errors = @import("errors.zig");

/// The single comptime configuration. Everything else is runtime config.
pub const Spec = server.Spec;

/// Methods zerb routes on. Anything else goes through `Server.router()`.
pub const Method = server.Method;

/// `zerb.Server(spec)`: the server type for one `Spec`.
pub const Server = server.Server;

/// Canonical error set; see `defaultErrorMapper`.
pub const HttpError = errors.HttpError;

/// What an error becomes on the wire.
pub const ErrorResponse = errors.ErrorResponse;

/// Default `anyerror -> ErrorResponse` table.
pub const defaultErrorMapper = errors.defaultErrorMapper;

/// htmx v4 request readers and response headers.
pub const htmx = @import("htmx.zig");

/// Adapter that runs any httpz middleware only for `HX-Request: true`.
pub const HtmxOnly = @import("middleware.zig").HtmxOnly;

test {
    std.testing.refAllDecls(@This());
    _ = @import("server.zig");
    _ = @import("errors.zig");
    _ = @import("htmx.zig");
    _ = @import("middleware.zig");
}
