const std = @import("std");

/// A bounded channel for sending values of type `T` between threads.
pub fn Channel(comptime T: type) type {
    return struct {
        pub const Error = error{Closed};

        pub fn create(allocator: std.mem.Allocator, capacity: usize) !struct { sender: Sender, receiver: Receiver } {
            if (capacity == 0) return error.InvalidCapacity;

            const buf = try allocator.alloc(T, capacity);

            const inner = try allocator.create(Inner);
            inner.* = .{
                .buf = buf,
                .cap = capacity,
                .allocator = allocator,
                .refs = std.atomic.Value(usize).init(2),
            };

            return .{
                .sender = .{ .inner = inner },
                .receiver = .{ .inner = inner },
            };
        }

        const Inner = struct {
            mutex: std.Thread.Mutex = .{},
            not_full: std.Thread.Condition = .{},
            not_empty: std.Thread.Condition = .{},

            buf: []T,
            cap: usize,
            head: usize = 0, // next pop
            tail: usize = 0, // next push
            len: usize = 0,

            closed: bool = false,

            // one ref for Sender, one for Receiver (clones retain/release)
            refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(2),

            allocator: std.mem.Allocator,

            fn freeAll(self: *Inner) void {
                const alloc = self.allocator;
                alloc.free(self.buf);
                // Important: destroy the Inner itself to avoid leaking it.
                alloc.destroy(self);
            }

            fn retain(self: *Inner) void {
                // Just bump the count; no synchronizes-with needed here.
                _ = self.refs.fetchAdd(1, .monotonic);
            }

            fn release(self: *Inner) void {
                // Use a strong ordering so prior writes become visible before free.
                if (self.refs.fetchSub(1, .seq_cst) == 1) {
                    self.freeAll();
                }
            }

            fn push(self: *Inner, value: T) !void {
                // precondition: mutex locked
                if (self.closed) return Error.Closed;

                while (self.len == self.cap and !self.closed) {
                    self.not_full.wait(&self.mutex);
                }
                if (self.closed) return Error.Closed;

                self.buf[self.tail] = value;
                self.tail = (self.tail + 1) % self.cap;
                self.len += 1;

                self.not_empty.signal();
            }

            fn tryPush(self: *Inner, value: T) !bool {
                // precondition: mutex locked
                if (self.closed) return Error.Closed;
                if (self.len == self.cap) return false;

                self.buf[self.tail] = value;
                self.tail = (self.tail + 1) % self.cap;
                self.len += 1;

                self.not_empty.signal();
                return true;
            }

            fn pop(self: *Inner) !T {
                // precondition: mutex locked
                while (self.len == 0) {
                    if (self.closed) return Error.Closed; // closed and empty -> EOF
                    self.not_empty.wait(&self.mutex);
                }

                const idx = self.head;
                self.head = (self.head + 1) % self.cap;
                self.len -= 1;

                const val = self.buf[idx];
                self.buf[idx] = undefined; // avoid accidental reuse for resource types

                self.not_full.signal();
                return val;
            }

            fn tryPop(self: *Inner) ?T {
                // precondition: mutex locked
                if (self.len == 0) return null;

                const idx = self.head;
                self.head = (self.head + 1) % self.cap;
                self.len -= 1;

                const val = self.buf[idx];
                self.buf[idx] = undefined;

                self.not_full.signal();
                return val;
            }

            fn doClose(self: *Inner) void {
                // precondition: mutex locked
                if (!self.closed) {
                    self.closed = true;
                    self.not_full.broadcast();
                    self.not_empty.broadcast();
                }
            }
        };

        pub const Sender = struct {
            inner: *Inner,

            pub fn clone(self: Sender) Sender {
                self.inner.retain();
                return .{ .inner = self.inner };
            }

            pub fn send(self: Sender, value: T) !void {
                self.inner.mutex.lock();
                defer self.inner.mutex.unlock();
                try self.inner.push(value);
            }

            pub fn trySend(self: Sender, value: T) !bool {
                self.inner.mutex.lock();
                defer self.inner.mutex.unlock();
                return try self.inner.tryPush(value);
            }

            pub fn close(self: Sender) void {
                self.inner.mutex.lock();
                self.inner.doClose();
                self.inner.mutex.unlock();
            }

            pub fn deinit(self: Sender) void {
                self.inner.release();
            }
        };

        pub const Receiver = struct {
            inner: *Inner,

            pub fn clone(self: Receiver) Receiver {
                self.inner.retain();
                return .{ .inner = self.inner };
            }

            pub fn recv(self: Receiver) !T {
                self.inner.mutex.lock();
                defer self.inner.mutex.unlock();
                return try self.inner.pop();
            }

            pub fn tryRecv(self: Receiver) ?T {
                self.inner.mutex.lock();
                defer self.inner.mutex.unlock();
                return self.inner.tryPop();
            }

            /// Like `tryRecv`, but blocks until a value
            /// is available or the channel is closed.
            /// Used to iterate over all values until closed
            /// with a while loop.
            pub fn next(self: Receiver) ?T {
                return self.recv() catch |err| {
                    if (err == Error.Closed) return null else unreachable;
                };
            }

            pub fn close(self: Receiver) void {
                self.inner.mutex.lock();
                self.inner.doClose();
                self.inner.mutex.unlock();
            }

            pub fn deinit(self: Receiver) void {
                self.inner.release();
            }
        };
    };
}

test "Channel basic send/recv" {
    const allocator = std.testing.allocator;
    var ch = try Channel(i32).create(allocator, 2);
    defer ch.sender.deinit();
    defer ch.receiver.deinit();

    try ch.sender.send(1);
    try ch.sender.send(2);

    const a = try ch.receiver.recv();
    try std.testing.expectEqual(@as(i32, 1), a);

    // Close the sender
    ch.sender.close();

    // Closing still allows draining
    const b = try ch.receiver.recv();
    try std.testing.expectEqual(@as(i32, 2), b);

    // now closed + empty -> Closed
    try std.testing.expectError(Channel(i32).Error.Closed, ch.receiver.recv());
}

test "Channel as iterator" {
    const allocator = std.testing.allocator;
    var ch = try Channel(i32).create(allocator, 2);
    defer ch.sender.deinit();
    defer ch.receiver.deinit();

    try ch.sender.send(10);
    try ch.sender.send(20);
    ch.sender.close();

    var sum: i32 = 0;
    while (ch.receiver.tryRecv()) |v| {
        sum += v;
    }
    try std.testing.expectEqual(@as(i32, 30), sum);
}

test "Channel across threads" {
    const allocator = std.testing.allocator;
    var ch = try Channel(usize).create(allocator, 3);
    defer ch.sender.deinit();
    defer ch.receiver.deinit();

    const Worker = struct {
        pub fn run(sender: Channel(usize).Sender) !void {
            defer sender.deinit();
            for (0..10) |i| {
                try sender.send(i);
            }
            sender.close();
        }
    };

    var thread = try std.Thread.spawn(.{}, Worker.run, .{ch.sender.clone()});
    defer thread.join();

    var sum: usize = 0;
    while (true) {
        const res = ch.receiver.recv();
        if (res == Channel(usize).Error.Closed) break;
        sum += res catch unreachable;
    }
    try std.testing.expectEqual(@as(i32, 45), sum);
}
