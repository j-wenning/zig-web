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

const RouteMiddleware = *const fn (error_message: *[]const u8) anyerror!void;

const RouteHandler = struct { method: std.http.Method, middleware: RouteMiddleware };

const RouteNodeValueType = enum {
    middleware,
    handler,
};

const RouteNodeValue = union(RouteNodeValueType) {
    middleware: RouteMiddleware,
    handler: RouteHandler,
};

const RouteNode = struct {
    const Self = @This();

    ident: RouteIdent,
    children: []Self,
    middlewares: []RouteMiddleware,
    handlers: []RouteHandler,

    fn init(ident: RouteIdent) Self {
        return Self{
            .ident = ident,
            .children = &[_]Self{},
            .middlewares = &[_]RouteMiddleware{},
            .handlers = &[_]RouteHandler{},
        };
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.children) |*child| {
            child.deinit(allocator);
        }
        allocator.free(self.children);
        allocator.free(self.middlewares);
        allocator.free(self.handlers);
    }

    fn add(root: *Self, allocator: std.mem.Allocator, path: []const u8, value: RouteNodeValue) !void {
        var path_segment_iter = std.mem.splitScalar(u8, path, path_separator);

        var node = root;
        while (path_segment_iter.next()) |segment| {
            const ident = RouteIdent.parse(segment);
            node = for (node.children) |*child| {
                if (RouteIdent.cmp(&child.ident, &ident)) {
                    break @constCast(child);
                }
            } else try slice.append(Self, allocator, &node.children, Self.init(ident));
        }

        switch (value) {
            .middleware => |middleware| _ = try slice.append(RouteMiddleware, allocator, &node.middlewares, middleware),
            .handler => |handler| _ = try slice.append(RouteHandler, allocator, &node.handlers, handler),
        }
    }
};

pub const RouteTree = struct {
    const Self = @This();

    root: RouteNode,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .root = RouteNode.init(RouteIdent{ .name = "/" }),
        };
    }

    pub fn deinit(self: *Self) void {
        self.root.deinit(self.allocator);
    }

    pub fn addMiddleware(self: *Self, path: []const u8, middleware: RouteMiddleware) !void {
        try RouteNode.add(&self.root, self.allocator, path, RouteNodeValue{ .middleware = middleware });
    }

    pub fn addHandler(self: *Self, method: std.http.Method, path: []const u8, handler: RouteMiddleware) !void {
        try RouteNode.add(&self.root, self.allocator, path, RouteNodeValue{ .handler = .{ .method = method, .middleware = handler } });
    }

    pub fn collect(
        self: *Self,
        method: std.http.Method,
        path: []const u8,
        middleware_accumulator: *std.ArrayList(RouteMiddleware),
        param_accumulator: *std.ArrayList([]const u8),
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

fn mockMiddleware(error_message: *[]const u8) !void {
    _ = error_message;
}

test "route allocations should not leak" {
    var tree = RouteTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.addHandler(.GET, "foo", mockMiddleware);
    try tree.addHandler(.GET, "foo", mockMiddleware);
    try tree.addHandler(.GET, "bar", mockMiddleware);
    try tree.addHandler(.GET, "foo/bar", mockMiddleware);
    try tree.addHandler(.GET, "foo/bar/baz", mockMiddleware);
    try tree.addHandler(.GET, "foo/bar", mockMiddleware);
    try tree.addHandler(.GET, "bar/baz", mockMiddleware);

    try tree.addMiddleware("foo", mockMiddleware);
    try tree.addMiddleware("foo", mockMiddleware);
    try tree.addMiddleware("bar", mockMiddleware);
    try tree.addMiddleware("foo/bar", mockMiddleware);
    try tree.addMiddleware("foo/bar/baz", mockMiddleware);
    try tree.addMiddleware("foo/bar", mockMiddleware);
    try tree.addMiddleware("bar/baz", mockMiddleware);
}

test "traversal returns expected result" {
    var tree = RouteTree.init(std.testing.allocator);
    defer tree.deinit();

    var macc = std.ArrayList(RouteMiddleware).init(std.testing.allocator);
    defer macc.deinit();

    var pacc = std.ArrayList([]const u8).init(std.testing.allocator);
    defer pacc.deinit();

    try tree.addHandler(.GET, "foo", mockMiddleware);
    try tree.addHandler(.GET, "foo/bar/baz", mockMiddleware);

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
    var tree = RouteTree.init(std.testing.allocator);
    defer tree.deinit();

    var macc = std.ArrayList(RouteMiddleware).init(std.testing.allocator);
    defer macc.deinit();

    var pacc = std.ArrayList([]const u8).init(std.testing.allocator);
    defer pacc.deinit();

    // Pure handlers
    try tree.addHandler(.GET, "foo", mockMiddleware);
    try tree.addHandler(.GET, "foo/bar", mockMiddleware);
    try tree.addHandler(.GET, "foo/bar/baz", mockMiddleware);

    macc.clearRetainingCapacity();
    try tree.collect(.GET, "foo", &macc, &pacc);
    try std.testing.expect(macc.items.len == 1);

    macc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar", &macc, &pacc);
    try std.testing.expect(macc.items.len == 1);

    macc.clearRetainingCapacity();
    try tree.collect(.GET, "foo/bar/baz", &macc, &pacc);
    try std.testing.expect(macc.items.len == 1);

    // Handlers with middleware
    try tree.addMiddleware("foo/bar", mockMiddleware);
    try tree.addMiddleware("foo", mockMiddleware);
    try tree.addMiddleware("foo/bar/baz", mockMiddleware);

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
    var tree = RouteTree.init(std.testing.allocator);
    defer tree.deinit();

    var macc = std.ArrayList(RouteMiddleware).init(std.testing.allocator);
    defer macc.deinit();

    var pacc = std.ArrayList([]const u8).init(std.testing.allocator);
    defer pacc.deinit();

    try tree.addHandler(.GET, "foo/bar/baz", mockMiddleware);
    try tree.addHandler(.GET, "foo/bar/*", mockMiddleware);
    try tree.addHandler(.GET, "foo/*/baz", mockMiddleware);
    try tree.addHandler(.GET, "*/bar/baz", mockMiddleware);
    try tree.addHandler(.GET, "foo/*/*", mockMiddleware);
    try tree.addHandler(.GET, "*/*/baz", mockMiddleware);
    try tree.addHandler(.GET, "*/*/*", mockMiddleware);

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
