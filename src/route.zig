const std = @import("std");
const slice = @import("slice.zig");

const path_separator = '/';
const query_separator = '?';

const RouteIdentType = enum {
    param,
    name,
};

const RouteIdent = union(RouteIdentType) {
    const Self = @This();

    param: void,
    name: []const u8,

    fn parse(raw_ident: []const u8) Self {
        if (std.mem.eql(u8, raw_ident, "*")) {
            return .param;
        } else {
            return Self{ .name = raw_ident };
        }
    }

    fn cmp(a: *const Self, b: *const Self) bool {
        const a_val = a.*;
        const b_val = b.*;

        if (@intFromEnum(a_val) != @intFromEnum(b_val)) {
            return false;
        }

        return switch (a_val) {
            .param => true,
            .name => |name| {
                return std.mem.eql(u8, name, b_val.name);
            },
        };
    }
};

fn RouteMiddleware(comptime Context: type, comptime ErrorContext: type) type {
    return *const fn (
        response: *std.http.Server.Response,
        request_context: *Context,
        error_context: *ErrorContext,
    ) anyerror!void;
}

fn RouteHandler(comptime Context: type, comptime ErrorContext: type) type {
    return struct {
        method: std.http.Method,
        middleware: RouteMiddleware(Context, ErrorContext),
    };
}

const RouteNodeValueType = enum {
    middleware,
    handler,
    prefix,
};

fn RouteNodeValue(comptime Context: type, comptime ErrorContext: type) type {
    return union(RouteNodeValueType) {
        middleware: RouteMiddleware(Context, ErrorContext),
        handler: RouteHandler(Context, ErrorContext),
        prefix: void,
    };
}

fn RouteNode(comptime Context: type, comptime ErrorContext: type) type {
    const OwnRouteNodeValue = RouteNodeValue(Context, ErrorContext);
    const OwnRouteMiddleware = RouteMiddleware(Context, ErrorContext);
    const OwnRouteHandler = RouteHandler(Context, ErrorContext);

    return struct {
        const Self = @This();

        pub const MiddlewareAccumulator = std.ArrayList(OwnRouteMiddleware);
        pub const ParamAccumulator = std.ArrayList([]const u8);

        ident: RouteIdent,
        children: []Self,
        middlewares: []OwnRouteMiddleware,
        handlers: []OwnRouteHandler,

        fn initInternal(comptime ident: RouteIdent) Self {
            return Self{
                .ident = ident,
                .children = &[_]Self{},
                .middlewares = &[_]OwnRouteMiddleware{},
                .handlers = &[_]OwnRouteHandler{},
            };
        }

        fn add(
            comptime root: *Self,
            comptime path: []const u8,
            comptime value: OwnRouteNodeValue,
        ) *Self {
            var path_segment_iter = std.mem.splitScalar(u8, path, path_separator);
            var node = root;
            while (path_segment_iter.next()) |segment| {
                if (std.mem.eql(u8, segment, "")) {
                    continue;
                }
                const ident = RouteIdent.parse(segment);
                node = for (node.children) |*child| {
                    if (RouteIdent.cmp(&child.ident, &ident)) {
                        break @constCast(child);
                    }
                } else slice.append(Self, &node.children, Self.initInternal(ident));
            }
            switch (value) {
                .middleware => |middleware| _ = slice.append(
                    OwnRouteMiddleware,
                    &node.middlewares,
                    middleware,
                ),
                .handler => |handler| _ = slice.append(
                    OwnRouteHandler,
                    &node.handlers,
                    handler,
                ),
                .prefix => {},
            }
            return node;
        }

        pub fn init() Self {
            return Self.initInternal(.{ .name = "" });
        }

        pub fn addPrefix(
            comptime self: *Self,
            comptime path: []const u8,
        ) *Self {
            return self.add(path, .{ .prefix = undefined });
        }

        pub fn addMiddleware(
            comptime self: *Self,
            comptime path: []const u8,
            comptime middleware: OwnRouteMiddleware,
        ) void {
            _ = self.add(path, .{ .middleware = middleware });
        }

        pub fn addHandler(
            comptime self: *Self,
            comptime method: std.http.Method,
            comptime path: []const u8,
            comptime handler: OwnRouteMiddleware,
        ) void {
            _ = self.add(path, .{ .handler = .{ .method = method, .middleware = handler } });
        }

        pub fn collect(
            comptime self: *Self,
            method: std.http.Method,
            path: []const u8,
            middleware_accumulator: *MiddlewareAccumulator,
            param_accumulator: *ParamAccumulator,
            query_params: *[]const u8,
        ) !void {
            var query_iter = std.mem.splitScalar(u8, path, query_separator);
            var segments = std.mem.splitScalar(u8, query_iter.first(), path_separator);
            query_params.* = query_iter.next() orelse "";
            var node = self;
            while (segments.next()) |*segment| {
                if (std.mem.eql(u8, segment.*, "")) {
                    continue;
                }
                node = for (node.children) |*child| {
                    switch (child.ident) {
                        .name => |name| if (!std.mem.eql(u8, name, segment.*)) continue,
                        .param => try param_accumulator.append(segment.*),
                    }
                    try middleware_accumulator.appendSlice(child.middlewares);
                    break child;
                } else return error.RouteNotFound;
            }
            const handler = for (node.handlers) |*handler| {
                if (handler.method == method) {
                    break handler.*.middleware;
                }
            } else return error.RouteNotFound;

            try middleware_accumulator.append(handler);
        }
    };
}

pub fn RouteTree(comptime Context: type, comptime ErrorContext: type) type {
    return RouteNode(Context, ErrorContext);
}

fn mockMiddleware(
    response: *std.http.Server.Response,
    context: *void,
    error_context: *void,
) !void {
    _ = error_context;
    _ = context;
    _ = response;
}

test "traversal returns expected result" {
    const RT = RouteTree(void, void);
    comptime var tree = blk: {
        var tree = RT.init();

        tree.addHandler(.GET, "", mockMiddleware);
        tree.addHandler(.GET, "foo", mockMiddleware);
        tree.addHandler(.GET, "foo/bar/baz", mockMiddleware);

        break :blk tree;
    };

    var macc = RT.MiddlewareAccumulator.init(std.testing.allocator);
    defer macc.deinit();

    var pacc = RT.ParamAccumulator.init(std.testing.allocator);
    defer pacc.deinit();

    var query: []const u8 = undefined;

    try tree.collect(.GET, "foo", &macc, &pacc, &query);

    try tree.collect(.GET, "foo/bar/baz", &macc, &pacc, &query);

    try std.testing.expectError(
        error.RouteNotFound,
        tree.collect(.GET, "/bar", &macc, &pacc, &query),
    );

    try std.testing.expectError(
        error.RouteNotFound,
        tree.collect(.GET, "/foo/a", &macc, &pacc, &query),
    );

    try std.testing.expectError(
        error.RouteNotFound,
        tree.collect(.GET, "/foo/bar/a", &macc, &pacc, &query),
    );
}

test "traversal results in expected collections of middleware" {
    const RT = RouteTree(void, void);

    comptime var tree = blk: {
        var tree = RT.init();

        tree.addHandler(.GET, "foo", mockMiddleware);
        tree.addHandler(.GET, "foo/bar", mockMiddleware);
        tree.addHandler(.GET, "foo/bar/baz", mockMiddleware);

        tree.addMiddleware("foo/bar", mockMiddleware);
        tree.addMiddleware("foo", mockMiddleware);
        tree.addMiddleware("foo/bar/baz", mockMiddleware);

        break :blk tree;
    };

    var macc = RT.MiddlewareAccumulator.init(std.testing.allocator);
    defer macc.deinit();

    var pacc = RT.ParamAccumulator.init(std.testing.allocator);
    defer pacc.deinit();

    var query: []const u8 = undefined;

    macc.clearRetainingCapacity();
    try tree.collect(.GET, "foo", &macc, &pacc, &query);
    try std.testing.expect(macc.items.len == 2);

    macc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar", &macc, &pacc, &query);
    try std.testing.expect(macc.items.len == 3);

    macc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar/baz", &macc, &pacc, &query);
    try std.testing.expect(macc.items.len == 4);
}

test "traversal results in expected collections of params" {
    const RT = RouteTree(void, void);
    comptime var tree = blk: {
        var tree = RT.init();

        tree.addHandler(.GET, "foo/bar/baz", mockMiddleware);
        tree.addHandler(.GET, "foo/bar/*", mockMiddleware);
        tree.addHandler(.GET, "foo/*/baz", mockMiddleware);
        tree.addHandler(.GET, "*/bar/baz", mockMiddleware);
        tree.addHandler(.GET, "foo/*/*", mockMiddleware);
        tree.addHandler(.GET, "*/*/baz", mockMiddleware);
        tree.addHandler(.GET, "*/*/*", mockMiddleware);

        break :blk tree;
    };

    var macc = RT.MiddlewareAccumulator.init(std.testing.allocator);
    defer macc.deinit();

    var pacc = RT.ParamAccumulator.init(std.testing.allocator);
    defer pacc.deinit();

    var query: []const u8 = undefined;

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar/baz", &macc, &pacc, &query);
    try std.testing.expect(pacc.items.len == 0);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar/a", &macc, &pacc, &query);
    try std.testing.expect(pacc.items.len == 1);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/a/baz", &macc, &pacc, &query);
    try std.testing.expect(pacc.items.len == 1);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "a/bar/baz", &macc, &pacc, &query);
    try std.testing.expect(pacc.items.len == 1);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/a/a", &macc, &pacc, &query);
    try std.testing.expect(pacc.items.len == 2);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "a/a/baz", &macc, &pacc, &query);
    try std.testing.expect(pacc.items.len == 2);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "a/a/a", &macc, &pacc, &query);
    try std.testing.expect(pacc.items.len == 3);
}

test "traversal results in expected collections of query params" {
    const RT = RouteTree(void, void);
    comptime var tree = blk: {
        var tree = RT.init();

        tree.addHandler(.GET, "", mockMiddleware);
        tree.addHandler(.GET, "foo", mockMiddleware);
        tree.addHandler(.GET, "foo/bar", mockMiddleware);

        break :blk tree;
    };

    var macc = RT.MiddlewareAccumulator.init(std.testing.allocator);
    defer macc.deinit();

    var pacc = RT.ParamAccumulator.init(std.testing.allocator);
    defer pacc.deinit();

    var query: []const u8 = undefined;

    try tree.collect(.GET, "", &macc, &pacc, &query);
    try std.testing.expect(std.mem.eql(u8, query, ""));

    try tree.collect(.GET, "foo", &macc, &pacc, &query);
    try std.testing.expect(std.mem.eql(u8, query, ""));

    try tree.collect(.GET, "foo?", &macc, &pacc, &query);
    try std.testing.expect(std.mem.eql(u8, query, ""));

    try tree.collect(.GET, "foo?foo", &macc, &pacc, &query);
    try std.testing.expect(std.mem.eql(u8, query, "foo"));

    try tree.collect(.GET, "foo?foo=123&bar=456", &macc, &pacc, &query);
    try std.testing.expect(std.mem.eql(u8, query, "foo=123&bar=456"));

    try tree.collect(.GET, "foo/bar?", &macc, &pacc, &query);
    try std.testing.expect(std.mem.eql(u8, query, ""));

    try tree.collect(.GET, "foo/bar?foo", &macc, &pacc, &query);
    try std.testing.expect(std.mem.eql(u8, query, "foo"));

    try tree.collect(.GET, "foo/bar?foo=123&bar=456", &macc, &pacc, &query);
    try std.testing.expect(std.mem.eql(u8, query, "foo=123&bar=456"));
}

test "prefixes return expected nodes" {
    const RT = RouteTree(void, void);
    comptime var tree = blk: {
        var tree = RT.init();

        var foo = tree.addPrefix("foo");
        foo.addMiddleware("/", mockMiddleware);
        var baz = foo.addPrefix("bar").addPrefix("baz");
        baz.addHandler(.GET, "qux", mockMiddleware);

        break :blk tree;
    };

    var macc = RT.MiddlewareAccumulator.init(std.testing.allocator);
    defer macc.deinit();

    var pacc = RT.ParamAccumulator.init(std.testing.allocator);
    defer pacc.deinit();

    var query: []const u8 = undefined;

    macc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar/baz/qux", &macc, &pacc, &query);
    try std.testing.expect(macc.items.len == 2);
}

test "root/empty path behaves expectedly" {
    const RT = RouteTree(void, void);
    var macc = RT.MiddlewareAccumulator.init(std.testing.allocator);
    defer macc.deinit();

    var pacc = RT.ParamAccumulator.init(std.testing.allocator);
    defer pacc.deinit();

    var query: []const u8 = undefined;

    {
        comptime var empty_tree = RT.init();
        try std.testing.expectError(
            error.RouteNotFound,
            empty_tree.collect(.GET, "/", &macc, &pacc, &query),
        );
    }
    {
        comptime var empty_tree = RT.init();
        try std.testing.expectError(
            error.RouteNotFound,
            empty_tree.collect(.GET, "", &macc, &pacc, &query),
        );
    }

    {
        comptime var tree = RT.init();
        comptime tree.addHandler(.GET, "/", mockMiddleware);
        try tree.collect(.GET, "/", &macc, &pacc, &query);
    }
    {
        comptime var tree = RT.init();
        comptime tree.addHandler(.GET, "", mockMiddleware);
        try tree.collect(.GET, "", &macc, &pacc, &query);
    }
}
