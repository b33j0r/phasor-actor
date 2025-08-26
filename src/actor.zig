const std = @import("std");
const root = @import("root.zig");
const Channel = root.Channel;

/// A generic actor that runs `work_fn` on a background thread. It communicates
/// with the outside world via two channels: an inbox and an outbox. After calling
/// `spawn()`, the user gets an `ActorHandle` which contains the user-side
/// endpoints of the channels.
pub fn Actor(comptime ContextT: type, comptime InboxT: type, comptime OutboxT: type) type {
    // Sanity checks on ContextT
    if (ContextT == void) {
        @compileError("ContextT cannot be void, it provides the `work` method");
    }
    // Check for a work method on ContextT
    if (!@hasDecl(ContextT, "work")) {
        @compileError("ContextT must have a `work` method");
    }
    const work_fn = ContextT.work;
    if (@typeInfo(@TypeOf(work_fn)) != .@"fn") {
        @compileError("ContextT.work must be a function");
    }

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,

        pub const ActorHandle = struct {
            inbox: Channel(InboxT).Sender,
            outbox: Channel(OutboxT).Receiver,
            thread: std.Thread,

            pub fn deinit(self: *ActorHandle) void {
                // Graceful shutdown
                self.inbox.close();
                self.outbox.close();
                self.thread.join();
                self.inbox.deinit();
                self.outbox.deinit();
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn spawn(self: *Self, ctx_or_ptr: anytype, inbox_capacity: usize, outbox_capacity: usize) !ActorHandle {
            // ctx must be a pointer to ContextT or a ContextT itself
            const ctx: *ContextT = ctx_block: switch (@typeInfo(@TypeOf(ctx_or_ptr))) {
                .pointer => {
                    break :ctx_block ctx_or_ptr;
                },
                .@"struct" => {
                    break :ctx_block @constCast(&ctx_or_ptr);
                },
                else => @compileError("ctx must be a pointer to ContextT or a ContextT itself"),
            };
            // Create channels
            const in_pair = try Channel(InboxT).create(self.allocator, inbox_capacity);
            errdefer {
                in_pair.sender.deinit();
                in_pair.receiver.deinit();
            }

            const out_pair = try Channel(OutboxT).create(self.allocator, outbox_capacity);
            errdefer {
                out_pair.sender.deinit();
                out_pair.receiver.deinit();
            }

            // Clone worker-owned endpoints
            var worker_inbox = in_pair.receiver.clone();
            var worker_outbox = out_pair.sender.clone();

            // We no longer need the original worker-side ends in this parent scope.
            in_pair.receiver.deinit();
            out_pair.sender.deinit();

            // If spawn fails, clean up everything we own here.
            errdefer {
                worker_inbox.deinit();
                worker_outbox.deinit();
                in_pair.sender.deinit();
                out_pair.receiver.deinit();
            }

            const th = try std.Thread.spawn(.{}, workerMain, .{ ctx, worker_inbox, worker_outbox });

            return .{
                .inbox = in_pair.sender, // user sends to actor
                .outbox = out_pair.receiver, // user receives from actor
                .thread = th,
            };
        }

        fn workerMain(
            ctx: *ContextT,
            inbox: Channel(InboxT).Receiver,
            outbox: Channel(OutboxT).Sender,
        ) void {
            ctx.work(inbox, outbox);
            // Signal EOF and drop worker-owned endpoints
            outbox.close();
            outbox.deinit();
            inbox.deinit();
        }
    };
}

test "Actor map/echo: doubles incoming ints and forwards them" {

    const Doubler = struct {
        pub fn work(_: *@This(), inbox: Channel(usize).Receiver, outbox: Channel(usize).Sender) void {
            while (inbox.next()) |v| {
                _ = outbox.send(v * 2) catch unreachable;
            }
        }
    };
    const DoublerActor = Actor(Doubler, usize, usize);

    var actor = DoublerActor.init(std.testing.allocator);
    var impl = Doubler{};
    var h = try actor.spawn(&impl, 16, 16);
    defer h.deinit();

    // Send 1..=10
    var i: usize = 1;
    while (i <= 10) : (i += 1) {
        try h.inbox.send(i);
    }
    h.inbox.close();

    // Drain outputs
    var got_sum: usize = 0;
    var count: usize = 0;
    while (h.outbox.next()) |v| {
        got_sum += v;
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 10), count);
    try std.testing.expectEqual(@as(usize, 110), got_sum); // 2*(1..10)
}

test "Actor reduce/sum: consumes ints and emits a single total" {
    const Summer = struct {
        pub fn work(_: *@This(), inbox: Channel(i32).Receiver, outbox: Channel(i32).Sender) void {
            var total: i32 = 0;
            while (inbox.next()) |r| {
                total += r;
            }
            _ = outbox.send(total) catch {};
        }
    };

    const A = Actor(Summer, i32, i32);

    var actor = A.init(std.testing.allocator);
    var impl = Summer{};
    var h = try actor.spawn(&impl, 8, 1);
    defer h.deinit();

    // Send -5..=5 -> sum = 0
    var x: i32 = -5;
    while (x <= 5) : (x += 1) {
        try h.inbox.send(x);
    }
    h.inbox.close();

    const first = h.outbox.recv();
    try std.testing.expect(first != Channel(i32).Error.Closed);
    const val = first catch unreachable;
    try std.testing.expectEqual(@as(i32, 0), val);

    const second = h.outbox.recv();
    try std.testing.expect(second == Channel(i32).Error.Closed);
}
