const std = @import("std");
const slice = @import("slice.zig");
const path_separator = '/';

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

fn RouteMiddleware(comptime Context: type) type {
    return *const fn (
        response: *std.http.Server.Response,
        request_context: *Context,
    ) anyerror!void;
}

fn RouteHandler(comptime Context: type) type {
    return struct {
        method: std.http.Method,
        middleware: RouteMiddleware(Context),
    };
}

const RouteNodeValueType = enum {
    middleware,
    handler,
};

fn RouteNodeValue(comptime Context: type) type {
    return union(RouteNodeValueType) {
        middleware: RouteMiddleware(Context),
        handler: RouteHandler(Context),
    };
}

fn RouteNode(comptime Context: type) type {
    const OwnRouteNodeValue = RouteNodeValue(Context);
    const OwnRouteMiddleware = RouteMiddleware(Context);
    const OwnRouteHandler = RouteHandler(Context);

    return struct {
        const Self = @This();

        ident: RouteIdent,
        children: []Self,
        middlewares: []OwnRouteMiddleware,
        handlers: []OwnRouteHandler,

        fn init(comptime ident: RouteIdent) Self {
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
        ) void {
            var path_segment_iter = std.mem.splitScalar(u8, path, path_separator);

            var node = root;
            while (path_segment_iter.next()) |segment| {
                const ident = RouteIdent.parse(segment);
                node = for (node.children) |*child| {
                    if (RouteIdent.cmp(&child.ident, &ident)) {
                        break @constCast(child);
                    }
                } else slice.append(Self, &node.children, Self.init(ident));
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
            }
        }
    };
}

pub fn RouteTree(comptime Context: type) type {
    const OwnRouteNodeValue = RouteNodeValue(Context);
    const OwnRouteNode = RouteNode(Context);
    const OwnRouteMiddleware = RouteMiddleware(Context);

    return struct {
        const Self = @This();

        pub const MiddlewareAccumulator = std.ArrayList(OwnRouteMiddleware);
        pub const ParamAccumulator = std.ArrayList([]const u8);

        root: OwnRouteNode,

        pub fn init() Self {
            return Self{
                .root = OwnRouteNode.init(RouteIdent{ .name = "" }),
            };
        }

        pub fn addMiddleware(
            comptime self: *Self,
            comptime path: []const u8,
            comptime middleware: OwnRouteMiddleware,
        ) void {
            OwnRouteNode.add(
                &self.root,
                path,
                OwnRouteNodeValue{ .middleware = middleware },
            );
        }

        pub fn addHandler(
            comptime self: *Self,
            comptime method: std.http.Method,
            comptime path: []const u8,
            comptime handler: OwnRouteMiddleware,
        ) void {
            OwnRouteNode.add(
                &self.root,
                path,
                OwnRouteNodeValue{ .handler = .{ .method = method, .middleware = handler } },
            );
        }

        pub fn collect(
            comptime self: *Self,
            method: std.http.Method,
            path: []const u8,
            middleware_accumulator: *MiddlewareAccumulator,
            param_accumulator: *ParamAccumulator,
        ) !void {
            var segments = std.mem.splitScalar(u8, path, path_separator);
            var node = &self.root;
            while (segments.next()) |segment| {
                node = for (node.children) |*child| {
                    switch (child.ident) {
                        .name => |name| if (!std.mem.eql(u8, name, segment)) continue,
                        .param => try param_accumulator.append(segment),
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

fn mockMiddleware(
    response: *std.http.Server.Response,
    context: *void,
) !void {
    _ = context;
    _ = response;
}

test "traversal returns expected result" {
    const RT = RouteTree(void);
    comptime var tree = blk: {
        var tree = RT.init();

        tree.addHandler(.GET, "foo", mockMiddleware);
        tree.addHandler(.GET, "foo/bar/baz", mockMiddleware);

        break :blk tree;
    };

    var macc = RT.MiddlewareAccumulator.init(std.testing.allocator);
    defer macc.deinit();

    var pacc = RT.ParamAccumulator.init(std.testing.allocator);
    defer pacc.deinit();

    try tree.collect(.GET, "foo", &macc, &pacc);

    try tree.collect(.GET, "foo/bar/baz", &macc, &pacc);

    try std.testing.expectError(
        error.RouteNotFound,
        tree.collect(.GET, "bar", &macc, &pacc),
    );

    try std.testing.expectError(
        error.RouteNotFound,
        tree.collect(.GET, "foo/a", &macc, &pacc),
    );

    try std.testing.expectError(
        error.RouteNotFound,
        tree.collect(.GET, "foo/bar/a", &macc, &pacc),
    );
}

test "traversal results in expected collections of middleware" {
    const RT = RouteTree(void);

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

    macc.clearRetainingCapacity();
    try tree.collect(.GET, "foo", &macc, &pacc);
    try std.testing.expect(macc.items.len == 2);

    macc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar", &macc, &pacc);
    try std.testing.expect(macc.items.len == 3);

    macc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar/baz", &macc, &pacc);
    try std.testing.expect(macc.items.len == 4);
}

test "traversal results in expected collections of params" {
    const RT = RouteTree(void);
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

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar/baz", &macc, &pacc);
    try std.testing.expect(pacc.items.len == 0);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar/a", &macc, &pacc);
    try std.testing.expect(pacc.items.len == 1);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/a/baz", &macc, &pacc);
    try std.testing.expect(pacc.items.len == 1);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "a/bar/baz", &macc, &pacc);
    try std.testing.expect(pacc.items.len == 1);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/a/a", &macc, &pacc);
    try std.testing.expect(pacc.items.len == 2);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "a/a/baz", &macc, &pacc);
    try std.testing.expect(pacc.items.len == 2);

    pacc.clearRetainingCapacity();
    try tree.collect(.GET, "a/a/a", &macc, &pacc);
    try std.testing.expect(pacc.items.len == 3);
}
