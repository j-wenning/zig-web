const std = @import("std");

pub fn append(comptime T: type, allocator: std.mem.Allocator, slice: *[]T, value: *const T) !*T {
    const new_idx = slice.len;
    const new_len = slice.len + 1;
    const new = try allocator.realloc(slice.*, new_len);
    new[new_idx] = value.*;
    slice.* = new;
    return &new[new_idx];
}
