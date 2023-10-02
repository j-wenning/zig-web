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

    fn init(ident: RouteIdent, allocator: std.mem.Allocator) Self {
        return Self{
            .ident = ident,
            .children = allocator.alloc(Self, 0) catch unreachable,
            .middlewares = allocator.alloc(RouteMiddleware, 0) catch unreachable,
            .handlers = allocator.alloc(RouteHandler, 0) catch unreachable,
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

    fn add(root: *Self, path: []const u8, value: RouteNodeValue, allocator: std.mem.Allocator) void {
        var path_segment_iter = std.mem.splitScalar(u8, path, path_separator);

        var node = root;
        while (path_segment_iter.next()) |segment| {
            const ident = RouteIdent.parse(segment);
            node = for (node.children) |*child| {
                if (RouteIdent.cmp(&child.ident, &ident)) {
                    break @constCast(child);
                }
            } else slice.append(Self, allocator, &node.children, &Self.init(ident, allocator)) catch unreachable;
        }

        switch (value) {
            .middleware => |middleware| _ = slice.append(RouteMiddleware, allocator, &node.middlewares, &middleware) catch unreachable,
            .handler => |handler| _ = slice.append(RouteHandler, allocator, &node.handlers, &handler) catch unreachable,
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
            .root = RouteNode.init(RouteIdent{ .name = "/" }, allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.root.deinit(self.allocator);
    }

    pub fn addMiddleware(self: *Self, path: []const u8, middleware: RouteMiddleware) void {
        RouteNode.add(&self.root, path, RouteNodeValue{ .middleware = middleware }, self.allocator);
    }

    pub fn addHandler(self: *Self, method: std.http.Method, path: []const u8, handler: RouteMiddleware) void {
        RouteNode.add(&self.root, path, RouteNodeValue{ .handler = .{ .method = method, .middleware = handler } }, self.allocator);
    }
};

fn mockMiddleware(error_message: *[]const u8) !void {
    _ = error_message;
}

test "route allocations should not leak" {
    var tree = RouteTree.init(std.testing.allocator);
    defer tree.deinit();

    tree.addHandler(.GET, "foo", mockMiddleware);
    tree.addHandler(.GET, "foo", mockMiddleware);
    tree.addHandler(.GET, "bar", mockMiddleware);
    tree.addHandler(.GET, "foo/bar", mockMiddleware);
    tree.addHandler(.GET, "foo/bar/baz", mockMiddleware);
    tree.addHandler(.GET, "foo/bar", mockMiddleware);
    tree.addHandler(.GET, "bar/baz", mockMiddleware);

    tree.addMiddleware("foo", mockMiddleware);
    tree.addMiddleware("foo", mockMiddleware);
    tree.addMiddleware("bar", mockMiddleware);
    tree.addMiddleware("foo/bar", mockMiddleware);
    tree.addMiddleware("foo/bar/baz", mockMiddleware);
    tree.addMiddleware("foo/bar", mockMiddleware);
    tree.addMiddleware("bar/baz", mockMiddleware);
}
