pub const Actor = actor.Actor;
pub const Channel = channel.Channel;

const actor = @import("actor.zig");
const channel = @import("channel.zig");

comptime {
    _ = actor;
    _ = channel;
}
