//! `zerb.Server(spec)`: a thin layer over httpz (HTTP) and zmpl (templates)
//! that treats htmx as a first-class response concern. See
//! `docs/interface-design.md` for the contract this file implements.
const std = @import("std");
const httpz = @import("httpz");
const zmpl = @import("zmpl");

const errors = @import("errors.zig");
const hx = @import("htmx.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.zerb);

pub const ErrorResponse = errors.ErrorResponse;
pub const defaultErrorMapper = errors.defaultErrorMapper;

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

pub fn Server(comptime spec: Spec) type {
    return struct {
        const Self = @This();

        pub const App = spec.App;
        pub const Context = spec.Context;

        /// The httpz action shape, chosen exactly the way httpz chooses it.
        pub const Action = httpz.Action(App);

        /// The plain `.data()` transformer shape. `T` is anything zmpl's
        /// `Value.put` coerces (see section 3.2 of the design). `null` means
        /// "omit key".
        ///
        /// `.data()` itself accepts four shapes, chosen at comptime from the
        /// function's parameters and return type (`app` only when
        /// `App != void`):
        ///
        ///   fn (app, req) ?T                       // this type
        ///   fn (app, req) !?T                      // may fail
        ///   fn (app, req, hx: *htmx.Headers) ?T    // .htmx routes only
        ///   fn (app, req, hx: *htmx.Headers) !?T   // .htmx routes only
        ///
        /// `T == void` puts nothing: for a transformer that only sets headers
        /// or performs a write. A returned error aborts the render and goes
        /// through the error mapper like an action error. `hx` is this
        /// request's htmx response headers; see `Handler.dispatch` for how
        /// they merge with the route's recorded ones. A `.page` route rejects
        /// the `hx` shapes at compile time.
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
        /// (`-Dzmpl_templates_paths`); this is everything that is not.
        pub const ZmplConfig = struct {
            /// `null`: resolve names with `zmpl.find` (all roots, in order).
            /// Otherwise `zmpl.findPrefixed(prefix, name)`.
            prefix: ?[]const u8 = null,
            /// `null`: every render receives `Context{}` (all fields must
            /// have defaults).
            context: ?ContextFn = null,
            /// Template chain (innermost first) rendered when a `.htmx`/`.page`
            /// route fails. Receives `.error.{status,code,message}`.
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
            /// route kind.
            ///
            /// For `.htmx`/`.page` routes it also owns the per-request htmx
            /// headers: `req_hx` starts empty, transformers that take an `hx`
            /// parameter write into it, and
            ///
            /// - on success `render` applies `route.hx.overlay(req_hx)`, so a
            ///   transformer write wins over the route's recorded value and
            ///   untouched fields keep the route default;
            /// - on failure only `req_hx` is applied, after the error body.
            ///   Route defaults (`.reswap("outerHTML")`, `.trigger(...)`)
            ///   describe the success fragment and are not sent with an error
            ///   page; what a transformer wrote before returning the error
            ///   (`hx.retarget = "#errors"`) is.
            pub fn dispatch(h: *Handler, action: Action, req: *httpz.Request, res: *httpz.Response) !void {
                const server = h.server;
                if (isRenderAction(action)) {
                    var req_hx = hx.Headers{};
                    render(h.app, req, res, &req_hx) catch |err| {
                        const er = server.mapError(h.app, err, req);
                        try server.respondErrorPage(h.app, req, res, er);
                        req_hx.apply(res);
                    };
                    return;
                }
                callAction(action, h.app, req, res) catch |err| {
                    const er = server.mapError(h.app, err, req);
                    try respondErrorJson(res, er);
                };
            }

            /// Last-resort net. Reached only if the error escaped `dispatch`
            /// (a middleware returned an error, or the error renderer itself
            /// failed). Writes the same JSON envelope with status 500.
            pub fn uncaughtError(h: *Handler, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
                _ = h;
                log.warn("uncaught error {s} for {s}", .{ @errorName(err), req.url.raw });
                respondErrorJson(res, errors.internal_error) catch {
                    res.clearWriter();
                    res.status = errors.internal_error.status;
                    res.content_type = .TEXT;
                    res.body = errors.internal_error.message;
                };
            }

            /// No route matched: `error.NotFound` through the page-style error
            /// path (error templates if configured, else `text/plain`).
            pub fn notFound(h: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
                const er = h.server.mapError(h.app, error.NotFound, req);
                return h.server.respondErrorPage(h.app, req, res, er);
            }
        };

        raw: Http,
        handler: Handler,
        io: std.Io,
        allocator: Allocator,
        /// Startup-lifetime arena: route specs, template chains, recorded
        /// header values, data entries. Freed in `deinit`.
        arena: Allocator,
        config: Config,

        _arena_state: std.heap.ArenaAllocator,
        _error_chain: []const zmpl.Template,
        _global_middlewares: []const Middleware,
        _router: ?*Router,
        _routes_registered: bool,

        pub fn init(io: std.Io, allocator: Allocator, app: App, config: Config) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .raw = undefined,
                .handler = .{ .server = self, .app = app },
                .io = io,
                .allocator = allocator,
                .arena = undefined,
                .config = config,
                ._arena_state = std.heap.ArenaAllocator.init(allocator),
                ._error_chain = &.{},
                ._global_middlewares = &.{},
                ._router = null,
                ._routes_registered = false,
            };
            errdefer self._arena_state.deinit();
            self.arena = self._arena_state.allocator();

            self._error_chain = try self.resolveChain(config.zmpl.error_templates);
            self.raw = try Http.init(io, allocator, config.httpz, &self.handler);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.raw.deinit();
            const allocator = self.allocator;
            self._arena_state.deinit();
            allocator.destroy(self);
        }

        pub fn listen(self: *Self) !void {
            return self.raw.listen();
        }

        pub fn stop(self: *Self) void {
            self.raw.stop();
        }

        // ------------------------------------------------------------------
        // Middleware
        // ------------------------------------------------------------------

        /// Instantiates an httpz-protocol middleware (`Config`/`init`/`execute`).
        pub fn middleware(self: *Self, comptime M: type, config: M.Config) !Middleware {
            return self.raw.middleware(M, config);
        }

        /// Global middlewares. Must precede the first route registration;
        /// afterwards returns `error.RoutesAlreadyRegistered`. Calling it
        /// again before any route replaces the list, as httpz does.
        pub fn use(self: *Self, middlewares: []const Middleware) !void {
            if (self._routes_registered) return error.RoutesAlreadyRegistered;
            self._global_middlewares = try self.arena.dupe(Middleware, middlewares);
            self._router = try self.raw.router(.{ .middlewares = self._global_middlewares });
        }

        // ------------------------------------------------------------------
        // Routes
        // ------------------------------------------------------------------

        /// JSON request/response. `action` is exactly httpz's action type for
        /// the chosen `App`. An error returned from it becomes
        /// `{"error":{"status","code","message","details"}}` with the mapped
        /// status.
        pub fn api(self: *Self, method: Method, path: []const u8, action: Action, opts: RouteOptions) !void {
            const route_spec = try self.newRouteSpec(.api);
            try self.register(method, path, action, route_spec, opts);
        }

        /// Builder for htmx responses: a template chain (optional) plus
        /// recorded htmx response headers, applied on every request.
        pub fn htmx(self: *Self, method: Method, path: []const u8, opts: RouteOptions) !*HtmxRoute {
            const route_spec = try self.newRouteSpec(.htmx);
            try self.register(method, path, renderAction, route_spec, opts);
            const route = try self.arena.create(HtmxRoute);
            route.* = .{ .spec = route_spec };
            return route;
        }

        /// Full-page render. `GET` only. `templates` is innermost first and is
        /// resolved now; an unknown name returns `error.TemplateNotFound`.
        pub fn page(self: *Self, path: []const u8, templates: []const []const u8, opts: RouteOptions) !*PageRoute {
            const route_spec = try self.newRouteSpec(.page);
            route_spec.chain = try self.resolveChain(templates);
            try self.register(.GET, path, renderAction, route_spec, opts);
            const route = try self.arena.create(PageRoute);
            route.* = .{ .spec = route_spec };
            return route;
        }

        /// Escape hatch: the httpz router itself, for websockets, static
        /// files, `.all`, custom methods, groups. Global middlewares are
        /// snapshotted here, so `use` is rejected afterwards.
        pub fn router(self: *Self) !*Router {
            const r = try self.routerInner();
            self._routes_registered = true;
            return r;
        }

        // ------------------------------------------------------------------
        // Builders
        // ------------------------------------------------------------------

        pub const HtmxRoute = struct {
            spec: *RouteSpec,

            /// Template chain, innermost first. Resolved now, not per request;
            /// panics on an unknown name. Calling twice replaces the chain. A
            /// route with no templates sends an empty body with only its
            /// headers (valid htmx: a redirect- or trigger-only response).
            pub fn templates(self: *HtmxRoute, names: []const []const u8) *HtmxRoute {
                self.spec.chain = self.spec.server.resolveChainOrPanic(names);
                return self;
            }

            /// Error-returning form of `templates`.
            pub fn tryTemplates(self: *HtmxRoute, names: []const []const u8) !*HtmxRoute {
                self.spec.chain = try self.spec.server.resolveChain(names);
                return self;
            }

            /// `transformer` is any of the shapes listed on `Transformer`;
            /// `T` is inferred from its return type at comptime. Entries run
            /// in registration order; for both data keys and `hx` header
            /// fields the later write wins.
            pub fn data(self: *HtmxRoute, key: []const u8, transformer: anytype) *HtmxRoute {
                self.spec.addData(key, transformer);
                return self;
            }

            // One method per htmx v4 response header. Each records a default
            // value for the route that is applied per request through
            // `htmx.Headers.apply`, unless a transformer sets the same field
            // for that request. Values are copied into the server arena.

            /// HX-Trigger
            pub fn trigger(self: *HtmxRoute, events: []const u8) *HtmxRoute {
                self.spec.hx.trigger = self.spec.dupe(events);
                return self;
            }

            /// HX-Location
            pub fn location(self: *HtmxRoute, path: []const u8) *HtmxRoute {
                self.spec.hx.location = self.spec.dupe(path);
                return self;
            }

            /// HX-Redirect
            pub fn redirect(self: *HtmxRoute, url: []const u8) *HtmxRoute {
                self.spec.hx.redirect = self.spec.dupe(url);
                return self;
            }

            /// HX-Refresh: true
            pub fn refresh(self: *HtmxRoute) *HtmxRoute {
                self.spec.hx.refresh = true;
                return self;
            }

            /// HX-Retarget
            pub fn retarget(self: *HtmxRoute, selector: []const u8) *HtmxRoute {
                self.spec.hx.retarget = self.spec.dupe(selector);
                return self;
            }

            /// HX-Reswap
            pub fn reswap(self: *HtmxRoute, swap: []const u8) *HtmxRoute {
                self.spec.hx.reswap = self.spec.dupe(swap);
                return self;
            }

            /// HX-Reselect
            pub fn reselect(self: *HtmxRoute, selector: []const u8) *HtmxRoute {
                self.spec.hx.reselect = self.spec.dupe(selector);
                return self;
            }

            /// HX-Push-Url
            pub fn pushUrl(self: *HtmxRoute, url: []const u8) *HtmxRoute {
                self.spec.hx.push_url = self.spec.dupe(url);
                return self;
            }

            /// HX-Replace-Url
            pub fn replaceUrl(self: *HtmxRoute, url: []const u8) *HtmxRoute {
                self.spec.hx.replace_url = self.spec.dupe(url);
                return self;
            }
        };

        pub const PageRoute = struct {
            spec: *RouteSpec,

            /// Identical contract to `HtmxRoute.data`, except that the `hx`
            /// parameter is rejected: a full page has no htmx response
            /// headers, so a transformer that wants them is a mistake here.
            pub fn data(self: *PageRoute, key: []const u8, transformer: anytype) *PageRoute {
                if (comptime transformerShape(@TypeOf(transformer)).takes_hx) {
                    @compileError("zerb: .page() transformer " ++ @typeName(@TypeOf(transformer)) ++ " takes a *htmx.Headers parameter, but htmx headers are meaningless on a full page; drop the parameter or register the route with .htmx()");
                }
                self.spec.addData(key, transformer);
                return self;
            }
        };

        // ------------------------------------------------------------------
        // Internals
        // ------------------------------------------------------------------

        const RouteKind = enum { api, htmx, page };

        /// Per-route state. Allocated from the server arena and handed to
        /// httpz as the route's `data` pointer, so builders can keep mutating
        /// it after registration (until `listen()`).
        const RouteSpec = struct {
            kind: RouteKind,
            server: *Self,
            /// Resolved at registration: `[content, layout_1, ..., layout_n]`.
            chain: []const zmpl.Template = &.{},
            /// Applied in registration order; later keys overwrite earlier ones.
            data: std.ArrayListUnmanaged(DataEntry) = .empty,
            /// `.htmx` only. Values are duplicated into the server arena.
            hx: hx.Headers = .{},

            fn dupe(self: *RouteSpec, value: []const u8) []const u8 {
                return self.server.arena.dupe(u8, value) catch @panic("zerb: out of memory");
            }

            fn addData(self: *RouteSpec, key: []const u8, transformer: anytype) void {
                const F = @TypeOf(transformer);
                const shape = comptime transformerShape(F);
                // A function body coerces to a pointer to itself; a pointer is
                // already the right type. `transformerShape` has validated the
                // parameter list, so the call below is well-typed.
                const Ptr = if (@typeInfo(F) == .pointer) F else *const F;
                const ptr: Ptr = transformer;

                const gen = struct {
                    fn apply(erased: *const anyopaque, app: App, req: *httpz.Request, req_hx: *hx.Headers, k: []const u8, root: *zmpl.Data.Value) anyerror!void {
                        const f: Ptr = @ptrCast(@alignCast(erased));
                        const result = if (comptime App == void)
                            (if (comptime shape.takes_hx) f(req, req_hx) else f(req))
                        else
                            (if (comptime shape.takes_hx) f(app, req, req_hx) else f(app, req));
                        const maybe = if (comptime shape.fallible) try result else result;
                        const value = maybe orelse return;
                        // `?void`: the transformer ran for its effects (headers,
                        // writes) and has nothing to put. Header-only routes.
                        if (comptime shape.T == void) return;
                        try root.put(k, value);
                    }
                };

                self.data.append(self.server.arena, .{
                    .key = self.dupe(key),
                    .transformer = @ptrCast(ptr),
                    .apply = gen.apply,
                }) catch @panic("zerb: out of memory");
            }
        };

        /// Type-erased `.data()` entry. `apply` is generated at comptime per
        /// transformer shape.
        const DataEntry = struct {
            key: []const u8,
            transformer: *const anyopaque,
            apply: *const fn (*const anyopaque, App, *httpz.Request, *hx.Headers, []const u8, *zmpl.Data.Value) anyerror!void,
        };

        /// What `.data()` learned about one transformer at comptime.
        const TransformerShape = struct {
            /// The `T` in `?T` / `!?T`.
            T: type,
            /// Takes the trailing `*htmx.Headers` parameter.
            takes_hx: bool,
            /// Returns `!?T` rather than `?T`.
            fallible: bool,
        };

        /// Classifies a transformer (function or pointer to one) into one of
        /// the four accepted shapes, or fails compilation with the reason.
        fn transformerShape(comptime F: type) TransformerShape {
            const expected = "`fn (" ++ (if (App == void) "" else "app, ") ++ "*httpz.Request[, *htmx.Headers]) ?T` or `!?T`";
            const fn_info = switch (@typeInfo(F)) {
                .@"fn" => |f| f,
                .pointer => |p| switch (@typeInfo(p.child)) {
                    .@"fn" => |f| f,
                    else => @compileError("zerb: .data() transformer must be " ++ expected ++ ", got " ++ @typeName(F)),
                },
                else => @compileError("zerb: .data() transformer must be " ++ expected ++ ", got " ++ @typeName(F)),
            };

            const params = fn_info.params;
            const n_app: usize = if (App == void) 0 else 1;
            const takes_hx = if (params.len == n_app + 1)
                false
            else if (params.len == n_app + 2)
                true
            else
                @compileError("zerb: .data() transformer must be " ++ expected ++ ", got " ++ @typeName(F));
            if (App != void and params[0].type != @as(?type, App)) {
                @compileError("zerb: .data() transformer's first parameter must be the app (" ++ @typeName(App) ++ "), got " ++ @typeName(F));
            }
            if (params[n_app].type != @as(?type, *httpz.Request)) {
                @compileError("zerb: .data() transformer's request parameter must be `*httpz.Request`, got " ++ @typeName(F));
            }
            if (takes_hx and params[n_app + 1].type != @as(?type, *hx.Headers)) {
                @compileError("zerb: .data() transformer's last parameter must be `*htmx.Headers`, got " ++ @typeName(F));
            }

            const R = fn_info.return_type orelse @compileError("zerb: .data() transformer must return `?T` or `!?T`");
            const fallible, const Payload = switch (@typeInfo(R)) {
                .error_union => |eu| .{ true, eu.payload },
                else => .{ false, R },
            };
            const T = switch (@typeInfo(Payload)) {
                .optional => |o| o.child,
                else => @compileError("zerb: .data() transformer must return `?T` or `!?T`, got " ++ @typeName(R)),
            };
            return .{ .T = T, .takes_hx = takes_hx, .fallible = fallible };
        }

        fn newRouteSpec(self: *Self, kind: RouteKind) !*RouteSpec {
            const route_spec = try self.arena.create(RouteSpec);
            route_spec.* = .{ .kind = kind, .server = self };
            return route_spec;
        }

        fn routerInner(self: *Self) !*Router {
            if (self._router) |r| return r;
            const r = try self.raw.router(.{ .middlewares = self._global_middlewares });
            self._router = r;
            return r;
        }

        fn register(self: *Self, method: Method, path: []const u8, action: Action, route_spec: *RouteSpec, opts: RouteOptions) !void {
            const r = try self.routerInner();
            self._routes_registered = true;
            const cfg = r.routeConfig(.{
                .data = route_spec,
                .middlewares = opts.middlewares,
                .middleware_strategy = opts.middleware_strategy,
            });
            switch (method) {
                .GET => try r.tryGet(path, action, cfg),
                .POST => try r.tryPost(path, action, cfg),
                .PUT => try r.tryPut(path, action, cfg),
                .PATCH => try r.tryPatch(path, action, cfg),
                .DELETE => try r.tryDelete(path, action, cfg),
                .HEAD => try r.tryHead(path, action, cfg),
                .OPTIONS => try r.tryOptions(path, action, cfg),
            }
        }

        fn findTemplate(self: *const Self, name: []const u8) ?zmpl.Template {
            if (self.config.zmpl.prefix) |prefix| {
                return zmpl.findPrefixed(prefix, name);
            }
            return zmpl.find(name);
        }

        fn resolveChain(self: *Self, names: []const []const u8) ![]const zmpl.Template {
            const chain = try self.arena.alloc(zmpl.Template, names.len);
            for (names, chain) |name, *slot| {
                slot.* = self.findTemplate(name) orelse return error.TemplateNotFound;
            }
            return chain;
        }

        fn resolveChainOrPanic(self: *Self, names: []const []const u8) []const zmpl.Template {
            const chain = self.arena.alloc(zmpl.Template, names.len) catch @panic("zerb: out of memory");
            for (names, chain) |name, *slot| {
                slot.* = self.findTemplate(name) orelse
                    std.debug.panic("zerb: unknown template \"{s}\"", .{name});
            }
            return chain;
        }

        // --- per-request ---------------------------------------------------

        fn callAction(action: Action, app: App, req: *httpz.Request, res: *httpz.Response) anyerror!void {
            if (comptime App == void) {
                return action(req, res);
            }
            return action(app, req, res);
        }

        /// The internal action registered for `.htmx` and `.page` routes.
        /// `Handler.dispatch` recognises it by address and calls `render`
        /// directly so it can keep the per-request headers across a failure;
        /// the action bodies below only matter if something other than
        /// `dispatch` invokes the pointer.
        const renderAction: Action = if (App == void) renderVoid else renderApp;

        fn renderVoid(req: *httpz.Request, res: *httpz.Response) anyerror!void {
            var req_hx = hx.Headers{};
            return render({}, req, res, &req_hx);
        }

        fn renderApp(app: App, req: *httpz.Request, res: *httpz.Response) anyerror!void {
            var req_hx = hx.Headers{};
            return render(app, req, res, &req_hx);
        }

        fn isRenderAction(action: Action) bool {
            return @intFromPtr(action) == @intFromPtr(renderAction);
        }

        /// Success path of a template route: data, then the chain, then (for
        /// `.htmx`) the route defaults overlaid with this request's `req_hx`.
        /// On error nothing is applied here; `dispatch` decides.
        fn render(app: App, req: *httpz.Request, res: *httpz.Response, req_hx: *hx.Headers) anyerror!void {
            const route_spec: *const RouteSpec = @ptrCast(@alignCast(req.route_data.?));
            const server = route_spec.server;

            var d = try server.buildData(route_spec, app, req, req_hx);
            res.body = try server.renderChain(route_spec.chain, &d, app, req);
            res.content_type = .HTML;

            if (route_spec.kind == .htmx) {
                route_spec.hx.overlay(req_hx.*).apply(res);
            }
        }

        /// Runs every `.data()` entry in registration order. A transformer
        /// error propagates immediately; entries after it do not run.
        fn buildData(self: *Self, route_spec: *const RouteSpec, app: App, req: *httpz.Request, req_hx: *hx.Headers) !zmpl.Data {
            var d = zmpl.Data.init(self.io, req.arena);
            const root = try d.object();
            for (route_spec.data.items) |entry| {
                try entry.apply(entry.transformer, app, req, req_hx, entry.key, root);
            }
            return d;
        }

        fn buildContext(self: *const Self, app: App, req: *httpz.Request) Context {
            const f = self.config.zmpl.context orelse return Context{};
            if (comptime App == void) {
                return f(req);
            }
            return f(app, req);
        }

        /// Renders `chain` (innermost first): `chain[0]` with `chain[1]` as
        /// its zmpl-native layout, then every further template wrapped around
        /// the previous output through `data.content`.
        fn renderChain(self: *const Self, chain: []const zmpl.Template, d: *zmpl.Data, app: App, req: *httpz.Request) ![]const u8 {
            if (chain.len == 0) return "";
            const ctx = self.buildContext(app, req);

            var out = try chain[0].render(self.io, d, Context, ctx, &.{}, .{
                .layout = if (chain.len > 1) chain[1] else null,
            });

            var i: usize = 2;
            while (i < chain.len) : (i += 1) {
                d.content = .{ .data = d.strip(out) };
                d.output_buf.clearRetainingCapacity();
                out = d.strip(try chain[i].render(self.io, d, Context, ctx, &.{}, .{}));
            }
            return out;
        }

        fn mapError(self: *const Self, app: App, err: anyerror, req: *httpz.Request) ErrorResponse {
            const f = self.config.errors.map orelse return defaultErrorMapper(err, req);
            if (comptime App == void) {
                return f(err, req);
            }
            return f(app, err, req);
        }

        fn respondErrorJson(res: *httpz.Response, er: ErrorResponse) !void {
            res.clearWriter();
            res.status = er.status;
            try res.json(.{ .@"error" = er }, .{});
        }

        fn respondErrorPage(self: *Self, app: App, req: *httpz.Request, res: *httpz.Response, er: ErrorResponse) !void {
            res.clearWriter();
            res.status = er.status;

            if (self._error_chain.len == 0) {
                res.content_type = .TEXT;
                res.body = er.message;
                return;
            }

            var d = zmpl.Data.init(self.io, req.arena);
            const root = try d.object();
            try root.put("error", .{
                .status = er.status,
                .code = er.code,
                .message = er.message,
            });
            res.body = try self.renderChain(self._error_chain, &d, app, req);
            res.content_type = .HTML;
        }
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const t = std.testing;

const TestApp = struct {
    greeting: []const u8 = "hello",
    suspended: bool = false,
};
const TestUser = struct { id: []const u8, name: []const u8 };
const TestCtx = struct { site: []const u8 = "zerb test" };

const TestServer = Server(.{ .App = *TestApp, .Context = TestCtx });
// zmpl instantiates every template for each Context type, so one manifest
// means one Context type; only `App` differs here.
const PlainServer = Server(.{ .Context = TestCtx });

fn loadUser(_: *TestApp, req: *httpz.Request) ?TestUser {
    const id = req.param("id") orelse return null;
    return .{ .id = id, .name = "Ada" };
}

fn greeting(app: *TestApp, _: *httpz.Request) ?[]const u8 {
    return app.greeting;
}

fn otherGreeting(_: *TestApp, _: *httpz.Request) ?[]const u8 {
    return "override";
}

fn nothing(_: *TestApp, _: *httpz.Request) ?[]const u8 {
    return null;
}

fn apiOk(_: *TestApp, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .ok = true }, .{});
}

fn apiNotFound(_: *TestApp, _: *httpz.Request, _: *httpz.Response) !void {
    return error.NotFound;
}

fn apiSuspended(app: *TestApp, _: *httpz.Request, _: *httpz.Response) !void {
    if (app.suspended) return error.UserSuspended;
}

fn apiPartialThenFail(_: *TestApp, _: *httpz.Request, res: *httpz.Response) !void {
    try res.writer().writeAll("partial output");
    return error.Conflict;
}

fn mapTestError(_: *TestApp, err: anyerror, req: *httpz.Request) ErrorResponse {
    return switch (err) {
        error.UserSuspended => .{ .status = 423, .code = "user_suspended", .message = "User is suspended" },
        else => defaultErrorMapper(err, req),
    };
}

fn siteContext(_: *TestApp, _: *httpz.Request) TestCtx {
    return .{ .site = "from-context-fn" };
}

fn plainOk(_: *httpz.Request, res: *httpz.Response) !void {
    res.body = "plain";
}

fn plainFail(_: *httpz.Request, _: *httpz.Response) !void {
    return error.Forbidden;
}

fn plainMessage(_: *httpz.Request) ?[]const u8 {
    return "Hello from void";
}

// --- transformer shapes under test ------------------------------------------

/// `!?T`, App: 400 without an id, 404 for "missing", else the user.
fn loadUserOrFail(_: *TestApp, req: *httpz.Request) !?TestUser {
    const id = req.param("id") orelse return error.BadRequest;
    if (std.mem.eql(u8, id, "missing")) return error.NotFound;
    return .{ .id = id, .name = "Ada" };
}

/// `!?T`, App, returns null: the key is omitted, no error.
fn fallibleNothing(_: *TestApp, _: *httpz.Request) !?[]const u8 {
    return null;
}

/// `(app, req, hx) ?T`: a dynamic HX-Trigger built in the request arena.
fn triggerWithId(_: *TestApp, req: *httpz.Request, h: *hx.Headers) ?TestUser {
    const id = req.param("id") orelse return null;
    h.trigger = std.fmt.allocPrint(req.arena, "user:renamed:{s}", .{id}) catch return null;
    return .{ .id = id, .name = "Ada" };
}

/// `(app, req, hx) ?T`: a second writer for the same header field.
fn triggerSecond(_: *TestApp, _: *httpz.Request, h: *hx.Headers) ?[]const u8 {
    h.trigger = "second";
    return "x";
}

/// `(app, req, hx) !?T`: sets a header, then fails.
fn retargetThenFail(_: *TestApp, _: *httpz.Request, h: *hx.Headers) !?TestUser {
    h.retarget = "#errors";
    h.reswap = "innerHTML";
    return error.UnprocessableEntity;
}

/// `(app, req, hx) !?T`: happy path of the fallible+hx shape.
fn fallibleWithHx(_: *TestApp, _: *httpz.Request, h: *hx.Headers) !?[]const u8 {
    h.push_url = "/users/1";
    return "fallible-hx";
}

/// void App, `!?T`.
fn plainFallible(req: *httpz.Request) !?[]const u8 {
    if (req.param("fail") != null) return error.Forbidden;
    return "Hello fallible";
}

/// void App, `(req, hx) ?T`.
fn plainWithHx(_: *httpz.Request, h: *hx.Headers) ?[]const u8 {
    h.trigger = "void:evt";
    return "Hello hx";
}

/// void App, `(req, hx) !?T`.
fn plainFallibleWithHx(req: *httpz.Request, h: *hx.Headers) !?[]const u8 {
    h.retarget = "#void-errors";
    if (req.param("fail") != null) return error.Conflict;
    return "Hello fallible hx";
}

const CountingMiddleware = struct {
    pub const Config = struct { header: []const u8 = "X-Counted" };
    cfg: Config,
    pub fn init(cfg: Config) !CountingMiddleware {
        return .{ .cfg = cfg };
    }
    pub fn execute(self: *const CountingMiddleware, _: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
        res.header(self.cfg.header, "1");
        return executor.next();
    }
};

const FailingMiddleware = struct {
    pub const Config = struct {};
    pub fn init(_: Config) !FailingMiddleware {
        return .{};
    }
    pub fn execute(_: *const FailingMiddleware, _: *httpz.Request, _: *httpz.Response, _: anytype) !void {
        return error.MiddlewareExploded;
    }
};

fn testServer(app: *TestApp, config: TestServer.Config) !*TestServer {
    return TestServer.init(t.io, t.allocator, app, config);
}

/// Runs `action` the way httpz would for a matched route carrying `route_spec`.
fn dispatchRoute(server: *TestServer, ht: *httpz.testing.Testing, action: TestServer.Action, route_spec: ?*const anyopaque) !void {
    ht.req.route_data = route_spec;
    return server.handler.dispatch(action, ht.req, ht.res);
}

test "api: success path is untouched" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();
    try server.api(.GET, "/api/ok", apiOk, .{});

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, apiOk, null);
    try ht.expectStatus(200);
    try ht.expectJson(.{ .ok = true });
}

test "api: canonical error becomes JSON envelope" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();
    try server.api(.GET, "/api/users/:id", apiNotFound, .{});

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, apiNotFound, null);
    try ht.expectStatus(404);
    try ht.expectHeader("Content-Type", "application/json; charset=UTF-8");
    try ht.expectBody(
        \\{"error":{"status":404,"code":"not_found","message":"Not found","details":null}}
    );
}

test "api: custom mapper composes with the default table" {
    var app = TestApp{ .suspended = true };
    const server = try testServer(&app, .{ .errors = .{ .map = mapTestError } });
    defer server.deinit();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, apiSuspended, null);
    try ht.expectStatus(423);
    try ht.expectBody(
        \\{"error":{"status":423,"code":"user_suspended","message":"User is suspended","details":null}}
    );
}

test "api: partial body written before the error is discarded" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, apiPartialThenFail, null);
    try ht.expectStatus(409);
    try ht.expectBody(
        \\{"error":{"status":409,"code":"conflict","message":"Conflict","details":null}}
    );
}

test "api: unknown error is 500 internal_error" {
    const server = try PlainServer.init(t.io, t.allocator, {}, .{});
    defer server.deinit();
    try server.api(.POST, "/plain", plainOk, .{});

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try server.handler.dispatch(plainFail, ht.req, ht.res);
    try ht.expectStatus(403);
    try ht.expectBody(
        \\{"error":{"status":403,"code":"forbidden","message":"Forbidden","details":null}}
    );
}

test "page: renders content inside layout with .data() entries" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = try server.page("/users/:id", &.{ "users/show", "layouts/app" }, .{});
    _ = route.data("user", loadUser).data("greeting", greeting);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "42");
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(200);
    try ht.expectHeader("Content-Type", "text/html; charset=UTF-8");
    try ht.expectBody("<main><h1>Ada</h1>\n<p>hello</p></main>");
    try ht.expectHeader("HX-Trigger", null);
}

test "page: three-deep chain wraps outer layouts around the previous output" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = try server.page("/users/:id", &.{ "users/show", "layouts/app", "layouts/html" }, .{});
    _ = route.data("user", loadUser).data("greeting", greeting);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "42");
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectBody("<html><body><main><h1>Ada</h1>\n<p>hello</p></main></body></html>");
}

test "page: single template means no layout" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = try server.page("/users/:id", &.{"users/row"}, .{});
    _ = route.data("user", loadUser);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "7");
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectBody("<tr><td>7</td><td>Ada</td></tr>\n");
}

test "page: unknown template name is an error at registration" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();
    try t.expectError(error.TemplateNotFound, server.page("/x", &.{"does/not/exist"}, .{}));
}

test "page: prefix restricts resolution to one template root" {
    var app = TestApp{};
    const server = try testServer(&app, .{ .zmpl = .{ .prefix = "templates" } });
    defer server.deinit();
    _ = try server.page("/ok", &.{"users/row"}, .{});

    const other = try testServer(&app, .{ .zmpl = .{ .prefix = "nope" } });
    defer other.deinit();
    try t.expectError(error.TemplateNotFound, other.page("/x", &.{"users/row"}, .{}));
}

test "data: null omits the key and later duplicates win" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = try server.page("/g", &.{"users/row"}, .{});
    _ = route
        .data("greeting", greeting)
        .data("greeting", otherGreeting)
        .data("missing", nothing);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    var req_hx = hx.Headers{};
    var d = try server.buildData(route.spec, &app, ht.req, &req_hx);
    try t.expectEqualStrings("override", d.getT(.string, "greeting").?);
    try t.expect(d.get("missing") == null);
}

test "data: transformers accept structs, slices, ints, bools and pointers" {
    const S = struct {
        fn user(_: *TestApp, _: *httpz.Request) ?TestUser {
            return .{ .id = "1", .name = "Bo" };
        }
        fn count(_: *TestApp, _: *httpz.Request) ?u32 {
            return 3;
        }
        fn flag(_: *TestApp, _: *httpz.Request) ?bool {
            return true;
        }
        fn tags(_: *TestApp, _: *httpz.Request) ?[]const []const u8 {
            return &.{ "a", "b" };
        }
    };
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = try server.page("/kinds", &.{"users/row"}, .{});
    const via_pointer: TestServer.Transformer(u32) = S.count;
    _ = route
        .data("user", S.user)
        .data("count", via_pointer)
        .data("flag", S.flag)
        .data("tags", S.tags);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    var req_hx = hx.Headers{};
    var d = try server.buildData(route.spec, &app, ht.req, &req_hx);
    try t.expectEqualStrings("Bo", d.get("user").?.get("name").?.string.value);
    try t.expectEqual(3, d.getT(.integer, "count").?);
    try t.expectEqual(true, d.getT(.boolean, "flag").?);
    try t.expectEqual(2, d.get("tags").?.count());
}

test "htmx: fragment plus recorded headers" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = (try server.htmx(.POST, "/users/:id/rename", .{}))
        .templates(&.{"users/row"})
        .data("user", loadUser)
        .retarget("closest tr")
        .reswap("outerHTML")
        .trigger("user:renamed")
        .pushUrl("false");

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "9");
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(200);
    try ht.expectBody("<tr><td>9</td><td>Ada</td></tr>\n");
    try ht.expectHeader("Content-Type", "text/html; charset=UTF-8");
    try ht.expectHeader("HX-Retarget", "closest tr");
    try ht.expectHeader("HX-Reswap", "outerHTML");
    try ht.expectHeader("HX-Trigger", "user:renamed");
    try ht.expectHeader("HX-Push-Url", "false");
    try ht.expectHeader("HX-Redirect", null);
}

test "htmx: header-only response with no templates" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = (try server.htmx(.DELETE, "/session", .{}))
        .redirect("/login")
        .refresh()
        .location("/elsewhere")
        .reselect("#main")
        .replaceUrl("/login");

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(200);
    try ht.expectBody("");
    try ht.expectHeader("HX-Redirect", "/login");
    try ht.expectHeader("HX-Refresh", "true");
    try ht.expectHeader("HX-Location", "/elsewhere");
    try ht.expectHeader("HX-Reselect", "#main");
    try ht.expectHeader("HX-Replace-Url", "/login");
}

test "htmx: recorded header values are copied into the server arena" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    var scratch = [_]u8{ 'e', 'v', 't' };
    const route = (try server.htmx(.GET, "/copy", .{})).trigger(&scratch);
    scratch[0] = 'X';
    try t.expectEqualStrings("evt", route.spec.hx.trigger.?);
}

test "htmx: templates() replaces the chain and tryTemplates reports misses" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = (try server.htmx(.GET, "/t", .{})).templates(&.{ "users/row", "layouts/app" });
    try t.expectEqual(2, route.spec.chain.len);
    _ = route.templates(&.{"users/row"});
    try t.expectEqual(1, route.spec.chain.len);
    try t.expectError(error.TemplateNotFound, route.tryTemplates(&.{"nope"}));
}

test "errors: page-style failure renders error templates with .error" {
    var app = TestApp{};
    const server = try testServer(&app, .{
        .zmpl = .{ .error_templates = &.{ "errors/show", "layouts/app" } },
    });
    defer server.deinit();

    // No `user` data: the template's `{{.user.name}}` reference fails.
    const route = try server.page("/users/:id", &.{"users/show"}, .{});

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(500);
    try ht.expectHeader("Content-Type", "text/html; charset=UTF-8");
    try ht.expectBody("<main><h1>500 internal_error</h1>\n<p>Internal server error</p></main>");
}

test "errors: page-style failure without error templates is text/plain" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = (try server.htmx(.GET, "/frag", .{})).templates(&.{"users/show"}).trigger("never");

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(500);
    try ht.expectHeader("Content-Type", "text/plain; charset=UTF-8");
    try ht.expectBody("Internal server error");
    // No hx headers on the error path.
    try ht.expectHeader("HX-Trigger", null);
}

test "errors: unknown error template name fails init" {
    var app = TestApp{};
    try t.expectError(error.TemplateNotFound, testServer(&app, .{
        .zmpl = .{ .error_templates = &.{"errors/missing"} },
    }));
}

test "notFound: routes through the page-style error path" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try server.handler.notFound(ht.req, ht.res);
    try ht.expectStatus(404);
    try ht.expectBody("Not found");
}

test "notFound: uses error templates when configured" {
    var app = TestApp{};
    const server = try testServer(&app, .{
        .zmpl = .{ .error_templates = &.{"errors/show"} },
    });
    defer server.deinit();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try server.handler.notFound(ht.req, ht.res);
    try ht.expectStatus(404);
    try ht.expectBody("<h1>404 not_found</h1>\n<p>Not found</p>\n");
}

test "uncaughtError: 500 JSON envelope" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    server.handler.uncaughtError(ht.req, ht.res, error.MiddlewareExploded);
    try ht.expectStatus(500);
    try ht.expectBody(
        \\{"error":{"status":500,"code":"internal_error","message":"Internal server error","details":null}}
    );
}

test "context: context fn output reaches the template" {
    var app = TestApp{};
    const server = try testServer(&app, .{ .zmpl = .{ .context = siteContext } });
    defer server.deinit();

    const route = try server.page("/ctx", &.{"site"}, .{});

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectBody("<title>from-context-fn</title>\n");
}

test "context: default context when no fn is configured" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = try server.page("/ctx", &.{"site"}, .{});

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectBody("<title>zerb test</title>\n");
}

test "middleware: use() must precede routes" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const counted = try server.middleware(CountingMiddleware, .{});
    try server.use(&.{counted});
    try server.api(.GET, "/api/ok", apiOk, .{});
    try t.expectError(error.RoutesAlreadyRegistered, server.use(&.{counted}));
}

test "middleware: global middlewares run through httpz's executor" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const counted = try server.middleware(CountingMiddleware, .{});
    try server.use(&.{counted});
    try server.api(.GET, "/api/ok", apiOk, .{});

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/api/ok");
    const r = try server.router();
    const da = r.route(.GET, "", "/api/ok", ht.req.params).?;
    try t.expectEqual(1, da.middlewares.len);

    var executor = TestServer.Http.Executor{
        .index = 0,
        .req = ht.req,
        .res = ht.res,
        .handler = &server.handler,
        .middlewares = da.middlewares,
        .dispatchable_action = da,
    };
    ht.req.route_data = da.data;
    try executor.next();
    try ht.expectHeader("X-Counted", "1");
    try ht.expectJson(.{ .ok = true });
}

test "middleware: per-route replace strategy drops globals" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const counted = try server.middleware(CountingMiddleware, .{});
    const other = try server.middleware(CountingMiddleware, .{ .header = "X-Other" });
    try server.use(&.{counted});
    try server.api(.GET, "/a", apiOk, .{ .middlewares = &.{other} });
    try server.api(.GET, "/b", apiOk, .{ .middlewares = &.{other}, .middleware_strategy = .replace });

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    const r = try server.router();
    try t.expectEqual(2, r.route(.GET, "", "/a", ht.req.params).?.middlewares.len);
    try t.expectEqual(1, r.route(.GET, "", "/b", ht.req.params).?.middlewares.len);
}

test "middleware: HtmxOnly adapter registers like any middleware" {
    const HtmxOnly = @import("middleware.zig").HtmxOnly;
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const only = try server.middleware(HtmxOnly(CountingMiddleware), .{});
    try server.use(&.{only});
    try server.api(.GET, "/api/ok", apiOk, .{});

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    const r = try server.router();
    const da = r.route(.GET, "", "/api/ok", ht.req.params).?;
    var executor = TestServer.Http.Executor{
        .index = 0,
        .req = ht.req,
        .res = ht.res,
        .handler = &server.handler,
        .middlewares = da.middlewares,
        .dispatchable_action = da,
    };
    try executor.next();
    try ht.expectHeader("X-Counted", null);
}

test "middleware: errors escaping dispatch reach uncaughtError" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const failing = try server.middleware(FailingMiddleware, .{});
    try server.use(&.{failing});
    try server.api(.GET, "/api/ok", apiOk, .{});

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    const r = try server.router();
    const da = r.route(.GET, "", "/api/ok", ht.req.params).?;
    var executor = TestServer.Http.Executor{
        .index = 0,
        .req = ht.req,
        .res = ht.res,
        .handler = &server.handler,
        .middlewares = da.middlewares,
        .dispatchable_action = da,
    };
    try t.expectError(error.MiddlewareExploded, executor.next());
}

test "void App: actions and transformers take no app argument" {
    const server = try PlainServer.init(t.io, t.allocator, {}, .{});
    defer server.deinit();

    try server.api(.GET, "/plain", plainOk, .{});
    const route = try server.page("/hello", &.{"hello"}, .{});
    _ = route.data("message", plainMessage);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.req.route_data = route.spec;
    try server.handler.dispatch(PlainServer.renderAction, ht.req, ht.res);
    try ht.expectBody("Hello from void\n");
}

test "transformers: ?T and !?T shapes, with and without hx, App" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = (try server.htmx(.POST, "/shapes/:id", .{}))
        .data("plain", greeting) // (app, req) ?T
        .data("user", loadUserOrFail) // (app, req) !?T
        .data("omitted", fallibleNothing) // (app, req) !?T -> null
        .data("hx_user", triggerWithId) // (app, req, hx) ?T
        .data("hx_fallible", fallibleWithHx); // (app, req, hx) !?T

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "5");
    var req_hx = hx.Headers{};
    var d = try server.buildData(route.spec, &app, ht.req, &req_hx);
    try t.expectEqualStrings("hello", d.getT(.string, "plain").?);
    try t.expectEqualStrings("5", d.get("user").?.get("id").?.string.value);
    try t.expect(d.get("omitted") == null);
    try t.expectEqualStrings("5", d.get("hx_user").?.get("id").?.string.value);
    try t.expectEqualStrings("fallible-hx", d.getT(.string, "hx_fallible").?);
    try t.expectEqualStrings("user:renamed:5", req_hx.trigger.?);
    try t.expectEqualStrings("/users/1", req_hx.push_url.?);
}

test "transformers: ?T and !?T shapes, with and without hx, void App" {
    const server = try PlainServer.init(t.io, t.allocator, {}, .{});
    defer server.deinit();

    const route = (try server.htmx(.GET, "/hello", .{}))
        .templates(&.{"hello"})
        .data("message", plainMessage) // (req) ?T
        .data("message", plainFallible) // (req) !?T
        .data("ignored", plainWithHx) // (req, hx) ?T
        .data("message", plainFallibleWithHx); // (req, hx) !?T

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.req.route_data = route.spec;
    try server.handler.dispatch(PlainServer.renderAction, ht.req, ht.res);
    try ht.expectStatus(200);
    try ht.expectBody("Hello fallible hx\n");
    try ht.expectHeader("HX-Trigger", "void:evt");
    try ht.expectHeader("HX-Retarget", "#void-errors");
}

test "transformers: void App error is mapped and keeps only transformer headers" {
    const server = try PlainServer.init(t.io, t.allocator, {}, .{});
    defer server.deinit();

    const route = (try server.htmx(.GET, "/hello", .{}))
        .templates(&.{"hello"})
        .reswap("outerHTML")
        .data("message", plainFallibleWithHx);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("fail", "1");
    ht.req.route_data = route.spec;
    try server.handler.dispatch(PlainServer.renderAction, ht.req, ht.res);
    try ht.expectStatus(409);
    try ht.expectBody("Conflict");
    try ht.expectHeader("HX-Retarget", "#void-errors");
    try ht.expectHeader("HX-Reswap", null);
}

test "htmx: transformer header overrides the route default; last writer wins" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = (try server.htmx(.POST, "/users/:id/rename", .{}))
        .templates(&.{"users/row"})
        .trigger("route-default")
        .retarget("closest tr")
        .data("user", triggerWithId)
        .data("second", triggerSecond);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "9");
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(200);
    try ht.expectBody("<tr><td>9</td><td>Ada</td></tr>\n");
    // Both transformers wrote HX-Trigger; registration order decides.
    try ht.expectHeader("HX-Trigger", "second");
    // Nobody touched HX-Retarget: the route default stands.
    try ht.expectHeader("HX-Retarget", "closest tr");
}

test "htmx: a single transformer write beats the route default, other defaults stay" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = (try server.htmx(.POST, "/users/:id/rename", .{}))
        .templates(&.{"users/row"})
        .trigger("route-default")
        .reswap("outerHTML")
        .pushUrl("false")
        .data("user", triggerWithId);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "3");
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectHeader("HX-Trigger", "user:renamed:3");
    try ht.expectHeader("HX-Reswap", "outerHTML");
    try ht.expectHeader("HX-Push-Url", "false");
    // Applied exactly once: Content-Length, Content-Type, 3 hx headers.
    try ht.expectHeaderCount(5);
}

test "htmx: route defaults are sent when no transformer takes hx" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const route = (try server.htmx(.POST, "/users/:id/rename", .{}))
        .templates(&.{"users/row"})
        .trigger("route-default")
        .data("user", loadUserOrFail);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "3");
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(200);
    try ht.expectHeader("HX-Trigger", "route-default");
}

test "errors: transformer error maps to status through error templates on .htmx" {
    var app = TestApp{};
    const server = try testServer(&app, .{
        .zmpl = .{ .error_templates = &.{ "errors/show", "layouts/app" } },
    });
    defer server.deinit();

    const route = (try server.htmx(.POST, "/users/:id/rename", .{}))
        .templates(&.{"users/row"})
        .data("user", loadUserOrFail);

    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.param("id", "missing");
        try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
        try ht.expectStatus(404);
        try ht.expectHeader("Content-Type", "text/html; charset=UTF-8");
        try ht.expectBody("<main><h1>404 not_found</h1>\n<p>Not found</p></main>");
    }
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        // No id param at all.
        try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
        try ht.expectStatus(400);
        try ht.expectBody("<main><h1>400 bad_request</h1>\n<p>Bad request</p></main>");
    }
}

test "errors: transformer error maps to status through error templates on .page" {
    var app = TestApp{};
    const server = try testServer(&app, .{
        .zmpl = .{ .error_templates = &.{"errors/show"} },
    });
    defer server.deinit();

    const route = try server.page("/users/:id", &.{ "users/show", "layouts/app" }, .{});
    _ = route.data("user", loadUserOrFail).data("greeting", greeting);

    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.param("id", "missing");
        try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
        try ht.expectStatus(404);
        try ht.expectBody("<h1>404 not_found</h1>\n<p>Not found</p>\n");
        try ht.expectHeader("HX-Trigger", null);
    }
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
        try ht.expectStatus(400);
        try ht.expectBody("<h1>400 bad_request</h1>\n<p>Bad request</p>\n");
    }
}

test "errors: transformer error without error templates is text/plain" {
    var app = TestApp{ .suspended = true };
    const server = try testServer(&app, .{ .errors = .{ .map = mapTestError } });
    defer server.deinit();

    const S = struct {
        fn suspended(a: *TestApp, _: *httpz.Request) !?TestUser {
            if (a.suspended) return error.UserSuspended;
            return null;
        }
    };
    const route = (try server.htmx(.GET, "/s", .{})).templates(&.{"users/row"}).data("user", S.suspended);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(423);
    try ht.expectHeader("Content-Type", "text/plain; charset=UTF-8");
    try ht.expectBody("User is suspended");
}

test "errors: on failure only transformer-set headers are sent, never route defaults" {
    var app = TestApp{};
    const server = try testServer(&app, .{
        .zmpl = .{ .error_templates = &.{"errors/show"} },
    });
    defer server.deinit();

    const route = (try server.htmx(.POST, "/users/:id/rename", .{}))
        .templates(&.{"users/row"})
        .reswap("outerHTML")
        .trigger("user:renamed")
        .pushUrl("false")
        .data("user", retargetThenFail)
        // Never runs: the entry before it failed.
        .data("second", triggerSecond);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "1");
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(422);
    try ht.expectBody("<h1>422 unprocessable</h1>\n<p>Unprocessable entity</p>\n");
    // Written by the failing transformer: sent, so the error body lands in
    // the slot it asked for. `reswap` is sent because the transformer set it,
    // not because the route did.
    try ht.expectHeader("HX-Retarget", "#errors");
    try ht.expectHeader("HX-Reswap", "innerHTML");
    // Route defaults: not sent with an error page.
    try ht.expectHeader("HX-Trigger", null);
    try ht.expectHeader("HX-Push-Url", null);
}

test "errors: a render failure after the transformers keeps the same header rule" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    // `users/show` needs `user`, which nobody provides: zmpl fails after
    // `triggerSecond` has already written HX-Trigger.
    const route = (try server.htmx(.GET, "/frag", .{}))
        .templates(&.{"users/show"})
        .reswap("outerHTML")
        .data("greeting", triggerSecond);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(500);
    try ht.expectHeader("HX-Trigger", "second");
    try ht.expectHeader("HX-Reswap", null);
}

test "transformers: ?void puts nothing and serves header-only routes" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const S = struct {
        fn gone(_: *TestApp, req: *httpz.Request, h: *hx.Headers) !?void {
            _ = req.param("id") orelse return error.NotFound;
            h.push_url = "/users";
            return {};
        }
    };
    const route = (try server.htmx(.DELETE, "/users/:id", .{}))
        .trigger("user:deleted")
        .data("effect", S.gone);

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("id", "1");
    var req_hx = hx.Headers{};
    var d = try server.buildData(route.spec, &app, ht.req, &req_hx);
    try t.expect(d.get("effect") == null);

    try dispatchRoute(server, &ht, TestServer.renderAction, route.spec);
    try ht.expectStatus(200);
    try ht.expectBody("");
    try ht.expectHeader("HX-Trigger", "user:deleted");
    try ht.expectHeader("HX-Push-Url", "/users");
}

test "transformers: one hx-less transformer serves both .page and .htmx" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const page_route = try server.page("/users/:id", &.{"users/row"}, .{});
    _ = page_route.data("user", loadUserOrFail);
    const htmx_route = (try server.htmx(.POST, "/users/:id/rename", .{}))
        .templates(&.{"users/row"})
        .trigger("user:renamed")
        .data("user", loadUserOrFail);

    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.param("id", "8");
        try dispatchRoute(server, &ht, TestServer.renderAction, page_route.spec);
        try ht.expectBody("<tr><td>8</td><td>Ada</td></tr>\n");
        try ht.expectHeader("HX-Trigger", null);
    }
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.param("id", "8");
        try dispatchRoute(server, &ht, TestServer.renderAction, htmx_route.spec);
        try ht.expectBody("<tr><td>8</td><td>Ada</td></tr>\n");
        try ht.expectHeader("HX-Trigger", "user:renamed");
    }
}

test "router: escape hatch exposes the httpz router" {
    var app = TestApp{};
    const server = try testServer(&app, .{});
    defer server.deinit();

    const r = try server.router();
    r.all("/anything", apiOk, .{});

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try t.expect(r.route(.PUT, "", "/anything", ht.req.params) != null);
    try t.expectError(error.RoutesAlreadyRegistered, server.use(&.{}));
}

test "config: httpz config passes through untouched" {
    var app = TestApp{};
    const server = try testServer(&app, .{
        .httpz = .{ .address = .all(9999), .request = .{ .max_form_count = 20 } },
    });
    defer server.deinit();
    try t.expectEqual(20, server.raw.config.request.max_form_count.?);
    try t.expectEqual(20, server.config.httpz.request.max_form_count.?);
}
