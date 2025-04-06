const std = @import("std");

pub const PoolError = error {
NoAvailableSlot
};

pub const HandleError = error {
HandleInvalid,
HandleOutOfBounds
};

/// Do not modify the pool while iterating. This will cause unpredictable results and most likely cause a crash.
pub fn HandleBasedPoolIterator(
    comptime max_count: u32,
    comptime TResource: type
) type {
    return struct {
        pool: *const HandleBasedPool(max_count, TResource),
        cursor: u32,
        finished: bool,

        fn init(pool: *const HandleBasedPool(max_count, TResource)) @This() {
            return @This() {
                .pool = pool,
                .cursor = pool.first orelse 0,
                .finished = pool.first == null,
            };
        }

        pub fn next(self: *@This()) ?*const TResource {
            if(self.finished == true) {
                return null;
            }

            const entry = &self.pool.entries[self.cursor];

            if(entry.next == self.cursor) {
                self.finished = true;
            } else {
                self.cursor = entry.next;
            }

            return &entry.resource.?;
        }
    };
}
/// Inspired by the blogpost "Handles are the better pointers" by Andre Weissflog:
/// https://floooh.github.io/2018/06/17/handles-vs-pointers.html
pub fn HandleBasedPool(
    comptime max_count: u32,
    comptime TResource: type
) type {
    return struct {
        pub const Size = max_count;
        pub const Handle = packed struct(u64) {
            index: u32,
            cycle: u32,
        };
        const Entry = struct {
            resource: ?TResource,
            cycle: u32,
            previous: u32,
            next: u32,
        };

        cursor: u32,
        first: ?u32,
        entries: [max_count]Entry,

        pub fn init() @This() {
            return .{
                .cursor = 0,
                .first = null,
                .entries = [_]Entry{.{
                    .resource = null,
                    .cycle = 0,
                    .previous = 0,
                    .next = 0,
                }} ** max_count,
            };
        }

        pub fn iterator(self: *const @This()) HandleBasedPoolIterator(max_count, TResource) {
            return HandleBasedPoolIterator(max_count, TResource).init(self);
        }

        fn findAvailableSlot(self: @This()) PoolError!u32 {
            for(self.cursor..self.entries.len) |index| {
                if(self.entries[index].resource == null and self.entries[index].cycle != std.math.maxInt(u32)) {
                    return @as(u32, @intCast(index));
                }
            }
            for(0..self.cursor) |index| {
                if(self.entries[index].resource == null and self.entries[index].cycle != std.math.maxInt(u32)) {
                    return @as(u32, @intCast(index));
                }
            }

            return PoolError.NoAvailableSlot;
        }

        pub fn add(self: *@This(), resource: TResource) PoolError!Handle {
            self.cursor = try self.findAvailableSlot();
            const new_entry_index = self.cursor;
            const new_entry = &self.entries[new_entry_index];
            new_entry.resource = resource;

            if(self.first == null) {
                self.first = new_entry_index;
                new_entry.previous = new_entry_index;
                new_entry.next = new_entry_index;
            } else {
                const first_entry = &self.entries[self.first.?];
                new_entry.next = self.first.?;
                self.first = new_entry_index;
                first_entry.previous = new_entry_index;
            }

            return Handle {
                .index = self.cursor,
                .cycle = self.entries[self.cursor].cycle,
            };
        }

        pub fn get(self: @This(), handle: Handle) HandleError!*const TResource {
            if(handle.index >= self.entries.len) {
                return HandleError.HandleOutOfBounds;
            }

            const entry = &self.entries[handle.index];

            if(handle.cycle != entry.cycle) {
                return HandleError.HandleInvalid;
            }

            return &entry.resource.?;
        }

        pub fn remove(self: *@This(), handle: Handle) HandleError!void {
            if(handle.index >= self.entries.len) {
                return HandleError.HandleOutOfBounds;
            }

            var entry = &self.entries[handle.index];

            if(entry.resource == null) {
                return HandleError.HandleInvalid;
            }

            if(handle.cycle != entry.cycle) {
                return HandleError.HandleInvalid;
            }

            if(handle.index == self.first.? and entry.next == handle.index) {
                self.first = null;
            } else if(handle.index == self.first.? and entry.next != handle.index) {
                self.first = entry.next;
                self.entries[entry.next].previous = entry.next;
            } else if(entry.previous != handle.index and entry.next != handle.index) {
                self.entries[entry.previous].next = entry.next;
            } else if(entry.previous != handle.index) {
                self.entries[entry.previous].next = entry.previous;
            } else if(entry.next != handle.index) {
                self.entries[entry.next].previous = entry.next;
            }

            entry.resource = null;
            entry.cycle = entry.cycle + 1;
        }

        pub fn clear(self: *@This()) void {
            for(&self.entries) |*entry| {
                entry.cycle = 0;
                entry.resource = null;
            }
        }
    };
}

const expectEqual = std.testing.expectEqual;

test "fails when full" {
    const TestPool = HandleBasedPool(4, u32);
    var pool = TestPool.init();
    _ = try pool.add(10);
    _ = try pool.add(11);
    _ = try pool.add(12);
    _ = try pool.add(13);
    try std.testing.expectError(PoolError.NoAvailableSlot, pool.add(14));
}

test "fails when full after manipulation" {
    const TestPool = HandleBasedPool(4, u32);
    var pool = TestPool.init();
    const handle = try pool.add(10);
    _ = try pool.add(11);
    _ = try pool.add(12);
    _ = try pool.add(13);
    try pool.remove(handle);
    _ = try pool.add(14);
    try std.testing.expectError(PoolError.NoAvailableSlot, pool.add(15));
}

test "iterates properly when removing an entry from the middle of the linked list" {
    const TestPool = HandleBasedPool(4, u32);
    var pool = TestPool.init();
    _ = try pool.add(10);
    const handle = try pool.add(11);
    _ = try pool.add(12);
    _ = try pool.add(13);
    try pool.remove(handle);
    var iterator = pool.iterator();
    try expectEqual(iterator.next().?.*, 13);
    try expectEqual(iterator.next().?.*, 12);
    try expectEqual(iterator.next().?.*, 10);
    try expectEqual(iterator.next(), null);
}

test "iterates properly when removing the last entry of the linked list" {
    const TestPool = HandleBasedPool(4, u32);
    var pool = TestPool.init();
    const handle = try pool.add(10);
    _ = try pool.add(11);
    _ = try pool.add(12);
    _ = try pool.add(13);
    try pool.remove(handle);
    var iterator = pool.iterator();
    try expectEqual(iterator.next().?.*, 13);
    try expectEqual(iterator.next().?.*, 12);
    try expectEqual(iterator.next().?.*, 11);
    try expectEqual(iterator.next(), null);
}

test "iterates properly when removing the first entry of the linked list" {
    const TestPool = HandleBasedPool(4, u32);
    var pool = TestPool.init();
    _ = try pool.add(10);
    _ = try pool.add(11);
    _ = try pool.add(12);
    const handle = try pool.add(13);
    try pool.remove(handle);
    var iterator = pool.iterator();
    try expectEqual(iterator.next().?.*, 12);
    try expectEqual(iterator.next().?.*, 11);
    try expectEqual(iterator.next().?.*, 10);
    try expectEqual(iterator.next(), null);
}

test "iterates properly when removing the only entry of the linked list" {
    const TestPool = HandleBasedPool(4, u32);
    var pool = TestPool.init();
    const handle = try pool.add(10);
    try pool.remove(handle);
    var iterator = pool.iterator();
    try expectEqual(iterator.next(), null);
}

test "iterates properly when never had entries" {
    const TestPool = HandleBasedPool(4, u32);
    var pool = TestPool.init();
    var iterator = pool.iterator();
    try expectEqual(iterator.next(), null);
}

test "does not do weird shit" {
    const StructA = struct {
        field1: u32,
        field2: u32,
        field3: u32,
    };
    const StructB = struct {
        field1: u32,
        field2: u32,
    };
    const TestPoolA = HandleBasedPool(1024, StructA);
    const TestPoolB = HandleBasedPool(1024, StructB);
    var poolA = TestPoolA.init();
    var poolB = TestPoolB.init();
    const handleA = try poolA.add(.{.field1 = 123, .field2 = 456, .field3 = 789});
    const handleB = try poolB.add(.{.field1 = 102, .field2 = 293});
    const valB = try poolB.get(handleB);
    const valA = try poolA.get(handleA);
    try expectEqual(293, valB.field2);
    try expectEqual(456, valA.field2);
}
