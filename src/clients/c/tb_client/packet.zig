const std = @import("std");
const assert = std.debug.assert;

const tb_client = @import("../tb_client.zig");
const stdx = tb_client.vsr.stdx;
const maybe = stdx.maybe;

pub const Packet = extern struct {
    pub const Status = enum(u8) {
        ok,
        too_much_data,
        client_evicted,
        client_release_too_low,
        client_release_too_high,
        client_shutdown,
        invalid_operation,
        invalid_data_size,
    };

    /// External packet type exposed to the user.
    pub const Extern = extern struct {
        user_data: ?*anyopaque,
        data: ?*anyopaque,
        data_size: u32,
        user_tag: u16,
        operation: u8,
        status: Status,
        @"opaque": [32]u8 = [_]u8{0} ** 32,

        pub fn cast(self: *Extern) *Packet {
            return @ptrCast(self);
        }
    };

    const Phase = enum(u8) {
        submitted,
        pending,
        batched,
        sent,
        complete,
    };

    user_data: ?*anyopaque,
    data: ?*anyopaque,
    data_size: u32,
    user_tag: u16,
    operation: u8,
    status: Status,

    next: ?*Packet,

    batch_next: ?*Packet,
    batch_tail: ?*Packet,
    batch_size: u32,
    batch_allowed: bool,
    phase: Phase,
    reserved: [2]u8 = [_]u8{0} ** 2,

    pub fn cast(self: *Packet) *Extern {
        return @ptrCast(self);
    }

    pub fn slice(packet: *const Packet) []const u8 {
        if (packet.data_size == 0) {
            // It may be an empty array (null pointer)
            // or a buffer with no elements (valid pointer and size == 0).
            stdx.maybe(packet.data == null);
            return &[0]u8{};
        }

        const data: [*]const u8 = @ptrCast(packet.data.?);
        return data[0..packet.data_size];
    }

    /// Asserts the internal state of the packet according to its expected phase.
    /// Inline function, so `expected` can be comptime known.
    pub inline fn assert_phase(packet: *const Packet, expected: Phase) void {
        assert(packet.phase == expected);
        assert(packet.data_size == 0 or packet.data != null);
        assert(stdx.zeroed(&packet.reserved));
        maybe(packet.user_data == null);
        maybe(packet.user_tag == 0);

        switch (expected) {
            .submitted => {
                assert(packet.next == null);
                assert(packet.batch_next == null);
                assert(packet.batch_tail == null);
                assert(packet.batch_size == 0);
                assert(!packet.batch_allowed);
            },
            .pending => {
                assert(packet.batch_size >= packet.data_size);
                assert(packet.batch_size == packet.data_size or packet.batch_next != null);
                assert(packet.batch_next == null or packet.batch_allowed);
                assert((packet.batch_next == null) == (packet.batch_tail == null));
                maybe(packet.next == null);
            },
            .batched => {
                assert(packet.next == null);
                assert(packet.batch_tail == null);
                assert(packet.batch_size == 0);
                assert(!packet.batch_allowed);
                maybe(packet.batch_next != null);
            },
            .sent => {
                assert(packet.next == null);
                assert(packet.batch_size >= packet.data_size);
                assert(packet.batch_size == packet.data_size or packet.batch_next != null);
                assert((packet.batch_next == null) == (packet.batch_tail == null));
                assert(packet.batch_next == null or packet.batch_allowed);
            },
            .complete => {
                // The packet pointer isn't available after completed,
                // it may be dealocated by the user;
                unreachable;
            },
        }
    }

    comptime {
        assert(@sizeOf(Extern) % @alignOf(Extern) == 0);
        assert(@alignOf(Extern) == 8);

        assert(@sizeOf(Packet) == @sizeOf(Extern));
        assert(@alignOf(Packet) == @alignOf(Extern));

        // Asseting the fields are identical.
        for (std.meta.fields(Extern)) |field_extern| {
            if (std.mem.eql(u8, field_extern.name, "opaque")) continue;
            const field_packet = std.meta.fields(Packet)[
                std.meta.fieldIndex(
                    Packet,
                    field_extern.name,
                ).?
            ];
            assert(field_packet.type == field_extern.type);
            assert(field_packet.alignment == field_extern.alignment);
            assert(@offsetOf(Packet, field_extern.name) ==
                @offsetOf(Extern, field_extern.name));
        }
    }
};
