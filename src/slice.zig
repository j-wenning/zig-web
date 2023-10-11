const std = @import("std");

pub fn append(comptime T: type, comptime slice: *[]T, comptime value: T) *T {
    const idx = slice.len;
    const len = idx + 1;
    comptime var new: [len]T = undefined;
    std.mem.copyForwards(T, &new, slice.*);
    new[idx] = value;
    slice.* = &new;
    return &slice.*[idx];
}
