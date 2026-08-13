//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const Server = @import("server.zig").Server;
pub const ServerError = @import("server.zig").Error;
pub const Method = @import("server.zig").Method;
