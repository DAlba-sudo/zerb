# zerb interface design: httpz + zmpl + htmx

This document is the interface contract for `zerb`, a thin layer over
[httpz](https://github.com/karlseguin/http.zig) (HTTP server) and
[zmpl](https://github.com/jetzig-framework/zmpl) (templates) that treats htmx
as a first-class *response* concern. It defines types and signatures plus one
usage example. It is not an implementation; internals (connection handling,
template compilation, the dispatch loop body) are described only where the
description is needed to make the contract unambiguous.

The current `src/server.zig` is the reference sketch this design supersedes.
The differences that matter: per-route state moves from a global
`StringHashMap` keyed by path onto httpz's own per-route `data` pointer, the
template list gets defined semantics, errors get a defined wire shape, and
htmx headers get a home.

## 0. Substrate facts this design is built on

Every signature below was checked against the pinned sources in
`build.zig.zon` (httpz `c22672f`, zmpl `ba974eb`) and against the htmx v4
reference. Where the brief's summary and the source differ, the source wins.

httpz

- `httpz.Server(H).init(io, allocator, config, handler)`; `H` may be `void`, a
  struct, or a pointer to a struct.
- With a handler that defines `dispatch(self, action, req, res)`, httpz derives
  the action type from `dispatch`'s second parameter. This is the hook zerb uses
  to keep actions in the plain `fn (req, res) !void` shape while still owning
  error handling.
- `uncaughtError(self, req, res, err) void` and `notFound(self, req, res) !void`
  are optional handler methods; `uncaughtError` is reached only when
  `Executor.next()` returns an error.
- Route config (`router.get(path, action, config)`) carries
  `data: ?*const anyopaque`, which httpz copies onto `req.route_data` before
  dispatch. This is the idiomatic per-route context slot.
- Middleware is any struct exposing `Config`, `init(config)` or
  `init(config, httpz.MiddlewareConfig)`, and
  `execute(self, req, res, executor) !void`. It is instantiated with
  `server.middleware(M, config)` and attached globally through
  `server.router(.{ .middlewares = ... })` or per route through
  `.{ .middlewares = ..., .middleware_strategy = .append | .replace }`.
  Global middlewares must be registered before routes are added.
- `req.header(name)` requires a fully lowercase name. `res.header(name, value)`
  stores both slices without copying, so values must outlive the request.
- `httpz.Config` groups: `address`, `workers`, `thread_pool`, `request`,
  `response`, `timeout`, `websocket`.

zmpl

- `zmpl.Data.init(io, gpa)` takes an `std.Io` as well as an allocator and builds
  its own arena on top of `gpa`.
- `data.object()` sets the root on first call; `value.put(key, anytype)` coerces
  any of: strings, integers, floats, bools, enums, structs, slices and arrays of
  those, optionals, and `*zmpl.Data.Value`. Strings passed this way are *not*
  copied.
- `template.render(io, data, Context: ?type, context, comptime blocks, options)`
  returns `![]const u8` allocated from `data`'s arena. `RenderOptions` has one
  field, `layout: ?Manifest.Template`. The layout renders `{{zmpl.content}}`.
- `zmpl.find(name)` matches the template *key*: its path relative to the
  templates root, forward slashes, extension stripped (`users/show.zmpl` has
  key `users/show`). `zmpl.findPrefixed(prefix, name)` restricts to one root.
- The build option is `-Dzmpl_templates_paths` (plural, a list of
  `prefix=<name>,path=<dir>` entries). The README's `-Dzmpl_templates_path` is
  stale.

htmx v4 (https://four.htmx.org/reference)

- Request headers: `HX-Request`, `HX-Request-Type`, `HX-Current-URL`,
  `HX-Source`, `HX-Target`, `HX-Boosted`, `HX-History-Restore-Request`.
- Response headers: `HX-Trigger`, `HX-Location`, `HX-Redirect`, `HX-Refresh`,
  `HX-Retarget`, `HX-Reswap`, `HX-Reselect`, `HX-Push-Url`, `HX-Replace-Url`.
  There is no `HX-Trigger-After-Settle` or `HX-Trigger-After-Swap` in v4.

## 1. Core types

Everything user code touches is either a top-level declaration of the `zerb`
module or a member of `zerb.Server(spec)`. The comptime `Spec` is the only
knob that changes signatures.

```zig
const std = @import("std");
const httpz = @import("httpz");
const zmpl = @import("zmpl").zmpl;

/// The single comptime configuration. Everything else is runtime config.
pub const Spec = struct {
    /// Application state passed to every action and transformer, exactly as
    /// httpz's handler type: `void` (default), a struct, or a pointer to one.
    /// With `void`, actions are `fn (req, res) !void`; otherwise they are
    /// `fn (app: App, req, res) !void`, mirroring httpz's non-void handler.
    App: type = void,
    /// zmpl `Context` type. Passed unchanged to every template render. zmpl
    /// requires one Context type per manifest, so it lives here, not per route.
    Context: type = struct {},
};

/// Methods zerb routes on. Anything else goes through `Server.router()`.
pub const Method = enum { GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS };

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
```

### 1.1 htmx namespace

The request side is a set of typed readers over the v4 request headers. The
response side is one struct, `htmx.Headers`, that is the *only* place hx
response headers are written. Three writers use it: the `.htmx()` route
builder records a per-route default into one; a transformer that takes an
`hx: *htmx.Headers` parameter writes per-request values into another (section
3.3); an `.api()` action can build one directly and `apply` it itself.

```zig
pub const htmx = struct {
    /// Value of `HX-Request-Type` in v4.
    pub const RequestType = enum { partial, full };

    /// Readers for htmx v4 request headers. Names are passed to
    /// `req.header` lowercase, as httpz requires.
    pub const Request = struct {
        /// `HX-Request: true`
        pub fn isHtmx(req: *const httpz.Request) bool;
        /// `HX-Request-Type`
        pub fn requestType(req: *const httpz.Request) ?RequestType;
        /// `HX-Current-URL`
        pub fn currentUrl(req: *const httpz.Request) ?[]const u8;
        /// `HX-Source`
        pub fn source(req: *const httpz.Request) ?[]const u8;
        /// `HX-Target`
        pub fn target(req: *const httpz.Request) ?[]const u8;
        /// `HX-Boosted: true`
        pub fn boosted(req: *const httpz.Request) bool;
        /// `HX-History-Restore-Request: true`
        pub fn historyRestore(req: *const httpz.Request) bool;
    };

    /// One field per htmx v4 response header. `null`/`false` means "do not
    /// send". Values are raw header strings: `reswap` takes the full swap
    /// spec (`"outerHTML show:top"`), `trigger` takes an event name or the
    /// JSON object form, `push_url`/`replace_url` accept `"false"`.
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
        /// they must be static, server-arena, or `req.arena`/`res.arena` owned.
        pub fn apply(self: Headers, res: *httpz.Response) void;

        /// `base` with every field that is set in `over` replaced by `over`'s
        /// value; fields `over` leaves `null`/`false` keep `base`'s. The
        /// per-request merge rule (section 3.3).
        pub fn overlay(base: Headers, over: Headers) Headers;
    };
};
```

There are deliberately no setter methods (`hx.trigger("x")`): Zig does not
allow a method and a field to share a name, so setters would have forced
either renamed fields or a second vocabulary. `hx.trigger = "x"` is the one
spelling.

### 1.2 Server(spec)

```zig
pub fn Server(comptime spec: Spec) type {
    return struct {
        const Self = @This();

        pub const App = spec.App;
        pub const Context = spec.Context;

        /// The httpz action shape, chosen exactly the way httpz chooses it.
        pub const Action = if (App == void)
            *const fn (*httpz.Request, *httpz.Response) anyerror!void
        else
            *const fn (App, *httpz.Request, *httpz.Response) anyerror!void;

        /// The plain `.data()` transformer shape. `T` is anything zmpl's
        /// `Value.put` coerces (see section 3.2). `null` means "omit key".
        /// `.data()` accepts this and three more shapes (section 3.2):
        /// `!?T` return, and a trailing `hx: *htmx.Headers` parameter on
        /// `.htmx` routes.
        pub fn Transformer(comptime T: type) type {
            return if (App == void)
                *const fn (*httpz.Request) ?T
            else
                *const fn (App, *httpz.Request) ?T;
        }

        /// Builds the zmpl `context` value for one request.
        pub const ContextFn = if (App == void)
            *const fn (*httpz.Request) Context
        else
            *const fn (App, *httpz.Request) Context;

        /// Maps an action error to a response. See `defaultErrorMapper`.
        pub const ErrorMapper = if (App == void)
            *const fn (anyerror, *httpz.Request) ErrorResponse
        else
            *const fn (App, anyerror, *httpz.Request) ErrorResponse;

        /// httpz's middleware interface, specialized for zerb's handler.
        /// Any httpz-protocol middleware (`Config`/`init`/`execute`) works.
        pub const Middleware = httpz.Middleware(*Handler);

        /// Raw httpz types, exposed for anything zerb does not wrap.
        pub const Http = httpz.Server(*Handler);
        pub const Router = httpz.Router(*Handler, Action);

        /// Per-route options: exactly httpz's `RouteConfig` minus the three
        /// fields zerb owns (`data`, `handler`, `dispatcher`).
        pub const RouteOptions = struct {
            middlewares: ?[]const Middleware = null,
            middleware_strategy: ?httpz.routing.MiddlewareStrategy = null,
        };

        /// zmpl runtime configuration. The template root is build-time
        /// (section 5); this is everything that is not.
        pub const ZmplConfig = struct {
            /// `null`: resolve names with `zmpl.find` (all roots, in order).
            /// Otherwise `zmpl.findPrefixed(prefix, name)`.
            prefix: ?[]const u8 = null,
            /// `null`: every render receives `Context{}` (all fields must
            /// have defaults).
            context: ?ContextFn = null,
            /// Template chain (section 3.1 semantics) rendered when a
            /// `.htmx`/`.page` route fails. Receives `.error.{status,code,message}`.
            /// Empty: plain-text body.
            error_templates: []const []const u8 = &.{},
        };

        pub const ErrorConfig = struct {
            /// `null`: `defaultErrorMapper`.
            map: ?ErrorMapper = null,
        };

        /// Runtime configuration. `httpz` is passed through untouched, so
        /// every httpz knob is reachable without zerb re-declaring it.
        pub const Config = struct {
            httpz: httpz.Config = .{},
            zmpl: ZmplConfig = .{},
            errors: ErrorConfig = .{},
        };

        /// The httpz handler zerb installs. Users never construct it; it is
        /// public so `Http`/`Router`/`Middleware` are nameable types.
        pub const Handler = struct {
            server: *Self,
            app: App,

            /// httpz calls this instead of the action. Runs `action`, catches
            /// any error, and turns it into a response according to the
            /// route kind found on `req.route_data` (section 2.1).
            pub fn dispatch(h: *Handler, action: Action, req: *httpz.Request, res: *httpz.Response) !void;

            /// Last-resort net. Reached only if the error escaped `dispatch`
            /// (a middleware returned an error, or the error renderer itself
            /// failed). Writes the same JSON envelope with status 500.
            pub fn uncaughtError(h: *Handler, req: *httpz.Request, res: *httpz.Response, err: anyerror) void;

            /// No route matched: `error.NotFound` through the page-style error
            /// path (error templates if configured, else `text/plain`).
            pub fn notFound(h: *Handler, req: *httpz.Request, res: *httpz.Response) !void;
        };

        raw: Http,
        handler: Handler,
        io: std.Io,
        allocator: std.mem.Allocator,
        /// Startup-lifetime arena: route specs, template chains, recorded
        /// header values, data entries. Freed in `deinit`.
        arena: std.mem.Allocator,
        config: Config,

        pub fn init(io: std.Io, allocator: std.mem.Allocator, app: App, config: Config) !*Self;
        pub fn deinit(self: *Self) void;
        pub fn listen(self: *Self) !void;
        pub fn stop(self: *Self) void;

        // Middleware (section 6)
        pub fn middleware(self: *Self, comptime M: type, config: M.Config) !Middleware;
        /// Global middlewares. Must precede the first route registration;
        /// afterwards returns `error.RoutesAlreadyRegistered`.
        pub fn use(self: *Self, middlewares: []const Middleware) !void;

        // Routes (section 2)
        pub fn api(self: *Self, method: Method, path: []const u8, action: Action, opts: RouteOptions) !void;
        pub fn htmx(self: *Self, method: Method, path: []const u8, opts: RouteOptions) !*HtmxRoute;
        pub fn page(self: *Self, path: []const u8, templates: []const []const u8, opts: RouteOptions) !*PageRoute;

        /// Escape hatch: the httpz router itself, for websockets, static
        /// files, `.all`, custom methods, groups.
        pub fn router(self: *Self) !*Router;

        // Builders: section 2.2 and 2.3.
        pub const HtmxRoute = struct {};
        pub const PageRoute = struct {};
    };
}
```

## 2. Route kinds

### 2.0 Shared mechanics

Every zerb route registers with httpz as
`router.<method>(path, action, .{ .data = spec, .middlewares = opts.middlewares, .middleware_strategy = opts.middleware_strategy })`
where `spec` is a `*RouteSpec` allocated from the server arena:

```zig
const RouteKind = enum { api, htmx, page };

const RouteSpec = struct {
    kind: RouteKind,
    server: *Self,
    /// Resolved at registration: `[content, layout_1, ..., layout_n]`.
    chain: []const zmpl.Manifest.Template = &.{},
    /// Applied in registration order; later keys overwrite earlier ones.
    data: std.ArrayListUnmanaged(DataEntry) = .empty,
    /// `.htmx` only. Values are duplicated into the server arena.
    hx: htmx.Headers = .{},
};

/// Type-erased `.data()` entry. `apply` is generated at comptime per
/// transformer shape (section 3.2).
const DataEntry = struct {
    key: []const u8,
    apply: *const fn (app: App, req: *httpz.Request, hx: *htmx.Headers, root: *zmpl.Data.Value) anyerror!void,
};
```

For `.api` the registered action is the user's; for `.htmx` and `.page` it is
an internal `renderAction` that reads `req.route_data`. Because httpz stores
the `data` pointer and passes it back on every match, no path-keyed map is
needed and a route's builder can keep mutating its spec after registration
(until `listen()`; mutating a live route is undefined).

Builder methods follow httpz's own convention for registration-time failure:
they panic with a descriptive message (unknown template name, OOM), the same
way `router.get` panics. `tryTemplates` is the error-returning form for the
one failure a caller might reasonably want to handle.

### 2.1 `.api()`: JSON request/response

```zig
pub fn api(self: *Self, method: Method, path: []const u8, action: Action, opts: RouteOptions) !void;
```

`action` is exactly httpz's action type for the chosen `App`
(`fn (req, res) !void` or `fn (app, req, res) !void`). The body is written the
httpz way: `res.status`, `res.header`, `res.json(value, .{})`, `res.body`.
zerb adds nothing to the success path.

**Error route, concretely.** An error returned from the action is caught in
`Handler.dispatch` and becomes:

1. `mapper(err, req)` (`config.errors.map` or `defaultErrorMapper`) yields an
   `ErrorResponse`.
2. `res.status = er.status`.
3. `res.json(.{ .@"error" = er }, .{})`, producing

```json
{"error":{"status":404,"code":"not_found","message":"Not found","details":null}}
```

Relationship to httpz's `uncaughtError`: zerb's handler *implements*
`uncaughtError` rather than replacing the mechanism. Normal action errors never
reach it because `dispatch` catches them first; it exists for errors thrown by
middleware (which run outside `dispatch`) and for failures inside the error
renderer itself. It emits the same envelope with status 500 and
`code: "internal_error"`, so clients see one shape regardless of where the
error originated.

### 2.2 `.htmx()`: builder for htmx responses

Name: `.htmx`. Alternatives considered were `.fragment` and `.partial`; both
describe the *body* but the distinguishing feature of this route kind is the
header vocabulary, and "htmx" is the word a reader searches for.

```zig
pub fn htmx(self: *Self, method: Method, path: []const u8, opts: RouteOptions) !*HtmxRoute;

pub const HtmxRoute = struct {
    spec: *RouteSpec,

    /// Template chain, section 3.1. Resolved now, not per request; panics on
    /// an unknown name. Calling twice replaces the chain. A route with no
    /// templates sends an empty body with only its headers (valid htmx: a
    /// redirect- or trigger-only response).
    pub fn templates(self: *HtmxRoute, names: []const []const u8) *HtmxRoute;
    pub fn tryTemplates(self: *HtmxRoute, names: []const []const u8) !*HtmxRoute;

    /// Section 3.2. `transformer` is any of the four accepted shapes; `T`
    /// is inferred from its return type at comptime.
    pub fn data(self: *HtmxRoute, key: []const u8, transformer: anytype) *HtmxRoute;

    // One method per htmx v4 response header. Each records the route's
    // default for that header; per request it is sent unless a transformer
    // set the same field (section 3.3). Values are copied into the server
    // arena.
    pub fn trigger(self: *HtmxRoute, events: []const u8) *HtmxRoute; // HX-Trigger
    pub fn location(self: *HtmxRoute, path: []const u8) *HtmxRoute; // HX-Location
    pub fn redirect(self: *HtmxRoute, url: []const u8) *HtmxRoute; // HX-Redirect
    pub fn refresh(self: *HtmxRoute) *HtmxRoute; // HX-Refresh: true
    pub fn retarget(self: *HtmxRoute, selector: []const u8) *HtmxRoute; // HX-Retarget
    pub fn reswap(self: *HtmxRoute, swap: []const u8) *HtmxRoute; // HX-Reswap
    pub fn reselect(self: *HtmxRoute, selector: []const u8) *HtmxRoute; // HX-Reselect
    pub fn pushUrl(self: *HtmxRoute, url: []const u8) *HtmxRoute; // HX-Push-Url
    pub fn replaceUrl(self: *HtmxRoute, url: []const u8) *HtmxRoute; // HX-Replace-Url
};
```

Per-request behaviour, in order (`Handler.dispatch` drives it, so the
per-request headers survive a failure):

1. `req_hx = htmx.Headers{}`: this request's header writes, initially empty.
2. Build `zmpl.Data` from `.data()` entries (3.2). A transformer with an `hx`
   parameter receives `&req_hx`. A transformer error stops here.
3. Render the chain (3.1) into `res.body`, `Content-Type: text/html`.
4. `spec.hx.overlay(req_hx).apply(res)`: route defaults, with every field a
   transformer set replaced by the transformer's value (3.3).

Headers are set whether or not the request carried `HX-Request`; a direct
browser hit gets the same fragment plus harmless extra headers. Branching on
htmx-ness belongs in middleware (section 6) or in the transformer.

On error (a transformer returned one, the chain failed to render, or the
context function surfaced one): status from the mapper; body from
`config.zmpl.error_templates` with `.error` set, else `text/plain` message;
then `req_hx.apply(res)` and nothing else. Route defaults are not sent with
an error body. Section 3.3 gives the reasoning.

### 2.3 `.page()`: full-page render

```zig
pub fn page(self: *Self, path: []const u8, templates: []const []const u8, opts: RouteOptions) !*PageRoute;

pub const PageRoute = struct {
    spec: *RouteSpec,
    /// Identical contract to `HtmxRoute.data`.
    pub fn data(self: *PageRoute, key: []const u8, transformer: anytype) *PageRoute;
};
```

`GET` only. `templates` uses the same chain semantics as `.htmx().templates`
and is resolved at registration. The per-request action is the htmx one minus
step 4, and `.data()` rejects a transformer that takes the `hx` parameter with
a `@compileError`: a full page has no htmx response headers, and a transformer
that reaches for them on a page route is a registration mistake, not a
runtime no-op. The hx-less shapes are accepted unchanged, so one transformer
can serve a `.page` and an `.htmx` route. The brief wrote the parameter as a
single string; it is a list here so that `.page` and `.htmx` share exactly one
chain rule instead of a "one template, layout from config" special case.

## 3. Shared conventions

### 3.1 Template chain semantics

`names` is ordered **innermost first**:

| index | role | mechanism |
|---|---|---|
| `names[0]` | content | `chain[0].render(..., .{ .layout = chain[1] or null })` |
| `names[1]` | first layout | zmpl-native `RenderOptions.layout`; sees `{{zmpl.content}}` and the content template's `@block`s |
| `names[2..]` | outer layouts | zerb sets `data.content = .{ .data = previous_output }`, clears the output buffer, and renders the next template with `.layout = null` |

So `&.{"users/show", "layouts/app", "layouts/html"}` reads as "show, inside
app, inside html". One name means no layout. Every name is a manifest key
(path relative to the templates root, no extension); resolution happens once
at registration through `zmpl.find` or `zmpl.findPrefixed` per
`config.zmpl.prefix`.

Limitation to state plainly: zmpl only forwards `@block` slots from content to
the *first* layout. Layouts at index 2 and beyond receive `{{zmpl.content}}`
only. Partials (`_name.zmpl`) are not valid chain members; zmpl rejects
rendering a partial with a layout.

### 3.2 `.data(key, transformer)` contract

**Shapes.** `.data()` accepts a function (or pointer to one) in any of four
shapes, chosen at comptime from its parameter count and return type. With
`App == void` the `app` parameter is absent; everything else is identical.

```zig
fn (app: App, req: *httpz.Request) ?T
fn (app: App, req: *httpz.Request) !?T
fn (app: App, req: *httpz.Request, hx: *zerb.htmx.Headers) ?T    // .htmx only
fn (app: App, req: *httpz.Request, hx: *zerb.htmx.Headers) !?T   // .htmx only
```

Any other parameter list or return type (a bare `T`, `!T`, `anytype`, a
different pointer type) is a `@compileError` naming the offending function.
`Server.Transformer(T)` still names the first shape for code that stores a
pointer.

**Values.** `T` is **any type that `zmpl.Data.Value.put` already accepts**:
`[]const u8`, integer and float types, `bool`, enums (tag name), structs
(field by field, recursively), slices and arrays of those, optionals, and
`*zmpl.Data.Value` for hand-built objects or arrays. Reason: zmpl's public
surface does have one universal value type (`Data.Value`) but constructing it
requires a `*Data` the transformer would not have. Returning plain Zig values
and letting zmpl's own `zmplValue` coercion run inside `put` adds no second
value model and gives a compile error for unsupported types at the exact `put`
site. A header-only `.htmx` route (no templates) can return `?void`.

**Errors.** A returned error aborts the render at that entry: later entries
do not run, no template renders, and the error takes the same path as an
action error (`dispatch`, then the mapper, then the error templates or
`text/plain`). `error.NotFound` is a 404 and `error.BadRequest` a 400 on both
`.htmx` and `.page` routes; a custom mapper sees the error exactly as it would
from an `.api` action. This is how "unknown id" becomes a 404 instead of a
`ZmplUnknownDataReferenceError` 500 from a template that dereferences a
missing key.

Per request the library does:

```zig
fn buildData(spec: *const RouteSpec, app: App, req: *httpz.Request, hx: *htmx.Headers) !zmpl.Data {
    var d = zmpl.Data.init(spec.server.io, req.arena);
    const root = try d.object();
    for (spec.data.items) |entry| try entry.apply(app, req, hx, root);
    return d;
}
```

where the generated `apply` calls the transformer with the parameters its
shape declares, `try`s the result if the shape is fallible, and does
`if (maybe) |v| try root.put(key, v);`.

Rules that follow:

- `null` from a transformer **omits** the key. Templates guard with `@if`.
- Same key twice: the later entry wins (`Object.put` overwrites).
- Strings are not copied by zmpl; allocate them from `req.arena` or use
  statics. `Data` is created on top of `req.arena` and is never `deinit`ed by
  zerb, so the render output stays valid until httpz writes the response and
  the request arena is reset.
- `error` is reserved for the error-template path.
- Transformers are also where side effects happen on `.htmx` routes (there
  is no separate action stage). Order them accordingly: an entry that fails
  prevents the ones after it from running, not the ones before.

### 3.3 Per-request htmx headers

A transformer on an `.htmx` route may take `hx: *zerb.htmx.Headers`. It is
the request's own `Headers` value, shared by every transformer of that
request, and it starts **empty**, not as a copy of the route's recorded
headers. Writes are plain field assignments:

```zig
fn toggleTodo(app: *App, req: *httpz.Request, hx: *zerb.htmx.Headers) !?View {
    const id = std.fmt.parseInt(u32, req.param("id") orelse return error.BadRequest, 10) catch
        return error.BadRequest;
    const todo = app.toggle(id) orelse {
        hx.retarget = "#errors";
        return error.NotFound;
    };
    if (!todo.changed) hx.reswap = "none";
    hx.trigger = try std.fmt.allocPrint(req.arena, "{{\"todos:changed\":{{\"id\":{d}}}}}", .{id});
    return View.of(todo);
}
```

**Precedence (success).** The response gets `route.hx.overlay(req_hx)`: for
each header field, the transformer's value if any transformer set it, else
the route's recorded default. Between transformers the later write wins,
mirroring the rule for `.data` keys. Headers are applied exactly once, after
the chain renders. Two consequences of "starts empty":

- A transformer cannot *unset* a route default (there is no "set to null"
  distinct from "did not touch"). If a header must sometimes be absent, do
  not record it on the route; set it from the transformer when it applies.
- A transformer cannot read the route default through `hx`. It can read what
  earlier transformers of the same request wrote.

**Precedence (failure).** Only `req_hx` is applied, after the error body;
route defaults are not. htmx 4 swaps 4xx/5xx bodies by default, so a route's
`.reswap("outerHTML")`/`.retarget("closest tr")` would put the error page
where the row was. What the transformer wrote before returning the error is
sent, so `hx.retarget = "#errors"` followed by `return error.BadRequest`
lands the error fragment in the slot it named. The same rule covers a chain
that fails to render after the transformers ran.

Why "starts empty" rather than "starts as a copy of the defaults": the copy
would need a per-field "was this written this request" record to implement
the failure rule, and plain field assignment cannot maintain one. Diffing the
final value against the default instead would misclassify a transformer that
deliberately set a header to the same value as the default. Starting empty
makes `req_hx` exactly the set of per-request writes, so both rules are
literal: success is an overlay, failure is `req_hx` alone.

**Ownership.** `Headers.apply` hands the slices to `res.header` without
copying. A value written from a transformer must therefore be a string
literal, live in the server arena, or be allocated in `req.arena` (or
`res.arena`); both arenas outlive the response write. A slice into a
transformer's stack frame is a use-after-return.

## 4. httpz passthrough

`Config.httpz` *is* `httpz.Config`. zerb sets no defaults of its own; it hands
the value to `httpz.Server(*Handler).init` verbatim. Any group
(`workers`, `thread_pool`, `request`, `response`, `timeout`, `websocket`) is
set with normal struct syntax and new httpz fields become available without a
zerb release. `server.raw` exposes the httpz server and `server.router()` the
httpz router for anything zerb does not model (websocket upgrades, `.all`,
groups, custom methods).

## 5. zmpl passthrough

zmpl splits configuration across build time and run time, and so does zerb.

Build time (template roots). zmpl compiles templates into a manifest, so the
root directory cannot be a runtime value. zerb's `build.zig` declares the same
option and forwards it:

```zig
// zerb/build.zig
const templates_paths = b.option(
    []const []const u8,
    "zmpl_templates_paths",
    "Template roots, each `prefix=<name>,path=<dir>` (forwarded to zmpl)",
);
const zmpl_dep = b.dependency("zmpl", .{
    .target = target,
    .optimize = optimize,
    .zmpl_templates_paths = templates_paths orelse &.{"prefix=templates,path=src/templates"},
});
```

A consuming app sets it once in its own `build.zig` through
`b.dependency("zerb", .{ .zmpl_templates_paths = ... })` or on the command
line with `-Dzmpl_templates_paths=prefix=templates,path=src/templates`. Other
zmpl build options (`zmpl_constants`, `zmpl_options_header`,
`zmpl_manifest_header`, `zmpl_markdown_fragments`, `zmpl_auto_build`) are
forwarded the same way, by name, without zerb interpreting them.

Run time (`Config.zmpl`, section 1.2): `prefix` selects which root
`templates()` names resolve against; `Context`/`context` are the zmpl context
type (comptime, in `Spec`) and its per-request constructor (`ContextFn`);
`error_templates` is the chain used for failed page/htmx renders. Layout
mechanics are fully expressed by the chain rule in 3.1, so there is no
separate "default layout" setting.

## 6. Middleware

zerb reuses httpz's protocol unchanged. A middleware is a struct with
`Config`, `init`, `execute`; `server.middleware(M, config)` instantiates it
(delegating to `raw.middleware`) and returns `Middleware`, which is
`httpz.Middleware(*Handler)`. Attach globally with `server.use(&.{...})`
before registering routes, or per route through `RouteOptions.middlewares`
with httpz's `middleware_strategy` (`.append` to the global list, `.replace`
it). httpz's bundled `httpz.middleware.Cors` works as-is.

One addition, justified by the brief's own example: a hook that runs only for
htmx-tagged requests. Rather than a new hook type, it is an adapter that turns
*any* httpz middleware into an htmx-only one, so it composes with everything
above:

```zig
/// Runs `M` only when `HX-Request: true`; other requests skip straight to
/// `executor.next()`. `Config` and `init` are forwarded unchanged, so the
/// result is registered like any other middleware:
/// `try server.middleware(zerb.HtmxOnly(M), cfg)`.
pub fn HtmxOnly(comptime M: type) type {
    return struct {
        inner: M,
        pub const Config = M.Config;
        pub fn init(config: Config, mw: httpz.MiddlewareConfig) !@This();
        pub fn execute(self: *@This(), req: *httpz.Request, res: *httpz.Response, executor: anytype) !void;
    };
}
```

## 7. End-to-end usage

```zig
const std = @import("std");
const httpz = @import("httpz");
const zerb = @import("zerb");

const App = struct {
    greeting: []const u8,
    pub fn find(self: *App, id: []const u8) ?User {
        _ = self;
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

    var server = try Server.init(init.io, init.gpa, &app, .{
        // Full httpz.Config, untouched by zerb.
        .httpz = .{
            .address = .all(8080),
            .workers = .{ .count = 2 },
            .thread_pool = .{ .count = 8 },
            .request = .{ .max_form_count = 20 },
            .timeout = .{ .request = 5, .keepalive = 30 },
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
    // row, then a client event fires. `renameUser` overrides the recorded
    // HX-Trigger per request and returns error.NotFound for an unknown id.
    _ = (try server.htmx(.POST, "/users/:id/rename", .{}))
        .templates(&.{"users/row"})
        .data("user", renameUser)
        .retarget("closest tr")
        .reswap("outerHTML")
        .trigger("user:renamed");

    // .page(): "users/show" inside "layouts/app", same .data() contract.
    _ = (try server.page("/users/:id", &.{ "users/show", "layouts/app" }, .{}))
        .data("user", loadUser)
        .data("greeting", greeting);

    try server.listen();
}

fn getUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id") orelse return error.BadRequest;
    const user = app.find(id) orelse return error.NotFound;
    try res.json(user, .{});
}

fn loadUser(app: *App, req: *httpz.Request) !?User {
    const id = req.param("id") orelse return error.BadRequest;
    return app.find(id) orelse error.NotFound;
}

fn renameUser(app: *App, req: *httpz.Request, hx: *zerb.htmx.Headers) !?User {
    const id = req.param("id") orelse return error.BadRequest;
    const user = app.find(id) orelse {
        hx.retarget = "#errors";
        hx.reswap = "innerHTML";
        return error.NotFound;
    };
    hx.trigger = try std.fmt.allocPrint(req.arena, "{{\"user:renamed\":{{\"id\":\"{s}\"}}}}", .{id});
    return user;
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
```

Templates referenced above, relative to the configured root:
`users/row.zmpl`, `users/show.zmpl`, `layouts/app.zmpl`, `errors/show.zmpl`.

## 8. Choices the brief left open

Each of these is a decision, not a derivation; change one and the code above
changes with it.

1. **`Spec.App` mirrors httpz's handler type.** Actions and transformers take
   `app` first only when `App != void`, exactly as httpz does. The reference
   sketch instead used a global `active` server pointer; that was dropped.
2. **Actions run through `Handler.dispatch`, not `uncaughtError`.** This is
   what lets `.api` keep the bare `fn (req, res) !void` shape while zerb still
   sees every error. `uncaughtError` is implemented as the 500 backstop.
3. **Error wire shape** is `{"error":{"status","code","message","details"}}`
   with a fixed default table for `zerb.HttpError`; unknown errors are 500.
4. **`.htmx` is the name**, over `.fragment`/`.partial`.
5. **Builder methods are camelCase** (`pushUrl`, `replaceUrl`) per Zig's
   function naming; header field names in `htmx.Headers` are snake_case per
   Zig's field naming.
6. **Template list is innermost-first**: `[content, layout, outer_layout, ...]`.
   The first layout uses zmpl's native option; further layouts reuse the
   content slot manually and lose `@block` propagation.
7. **`.page(templates)` takes a list**, not the brief's single string, so both
   template routes share one chain rule and there is no "default layout" knob.
8. **`.data()` `T` is "anything `Value.put` accepts"**, inferred from the
   transformer's `?T` or `!?T` return type; `null` omits the key; an error
   aborts the render and is mapped like an action error; later duplicates
   win; strings are not copied.
9. **Templates resolve at registration and panic on a miss**, matching
   httpz's `router.get` convention, with `tryTemplates` as the error form.
10. **Recorded hx header values are per-route defaults; per-request values
    come from transformers.** A transformer may take `hx: *htmx.Headers`
    (`.htmx` routes only, `@compileError` on `.page`). The handle starts
    empty; on success it is overlaid on the defaults, on failure it is the
    only thing sent. No setter methods on `Headers` (field/method name clash).
11. **hx headers are always applied**, even without `HX-Request`; a route with
    no templates sends an empty body plus headers.
12. **Routes register immediately** and builders mutate the spec in place
    (via httpz's `route_data`); there is no terminal `.build()`.
13. **Global middleware must precede routes** (`use` after a route errors),
    because that is when httpz snapshots the list.
14. **`HtmxOnly(M)` is the only zerb-specific middleware concept**, and it is
    itself an httpz-protocol middleware.
15. **Template roots are build-time** via the forwarded `zmpl_templates_paths`
    option (plural, `prefix=…,path=…`), not a runtime string.
16. **Header casing**: request headers are read lowercase (httpz requirement);
    response headers are written in htmx's documented `HX-Kebab-Case`.
17. **Method set** is the seven common methods; others go via `router()`.
