const std = @import("std");
const phasor_actor = @import("phasor-actor");
const Actor = phasor_actor.Actor;
const Channel = phasor_actor.Channel;

pub const Command = union(enum) {
    Add: struct { value: f32 },
    Subtract: struct { value: f32 },
    Multiply: struct { value: f32 },
    Divide: struct { value: f32 },
};

pub const Result = union(enum) {
    Partial: f32,
    Total: f32,
    Error: error{ DivisionByZero },
};

const CalculatorActor = Actor(Calculator, Command, Result);

pub fn main() !u8 {
    const allocator = std.heap.c_allocator;
    var actor = CalculatorActor.init(allocator);
    var h = try actor.spawn(Calculator{}, 16, 16);
    defer h.deinit();

    try h.inbox.send(.{ .Add = .{ .value = 2.5 } });
    try h.inbox.send(.{ .Multiply = .{ .value = 4 } });
    try h.inbox.send(.{ .Subtract = .{ .value = 50 } });
    try h.inbox.send(.{ .Divide = .{ .value = 2 } });
    try h.inbox.send(.{ .Divide = .{ .value = 0 } }); // This will cause an error

    h.inbox.close();

    while (h.outbox.next()) |res| {
        switch (res) {
            .Partial => |p| std.debug.print("Partial: {d}\n", .{p}),
            .Total => |t| std.debug.print("Total: {d}\n", .{t}),
            .Error => |e| std.debug.print("Error: {any}\n", .{e}),
        }
    }

    return 0;
}

const Calculator = struct {
    pub fn work(_: *@This(), inbox: Channel(Command).Receiver, outbox: Channel(Result).Sender) void {
        var total: f32 = 0.0;
        while (inbox.next()) |cmd| {
            switch (cmd) {
                .Add => |c| total += c.value,
                .Subtract => |c| total -= c.value,
                .Multiply => |c| total *= c.value,
                .Divide => |c| {
                    if (c.value == 0.0) {
                        _ = outbox.send(.{ .Error =  error.DivisionByZero }) catch |err| {
                            std.log.err("Failed to send error: {}", .{err});
                        };
                        continue;
                    } else {
                        total /= c.value;
                    }
                },
            }
            _ = outbox.send(.{ .Partial = total }) catch |err| {
                std.log.err("Failed to send partial result: {}", .{err});
            };
        }
        _ = outbox.send(.{ .Total = total }) catch |err| {
            std.log.err("Failed to send total: {}", .{err});
        };
    }
};