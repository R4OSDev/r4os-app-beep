const std = @import("std");
const r4os = @import("r4os");
const app = @import("main.zig");
const a = r4os.abi;
const a2 = r4os.platform2.abi;
const t = std.testing;

// Only the external R4SYS callbacks are modeled. The application, total Writer/PcmSourcePacer,
// framing/response validation and owned AudioStream are the product code.
const Host = struct {
    var now: u64 = 0;
    var hz: u32 = 1000;
    var sleep_available: bool = true;
    var write_cost: u64 = 0;
    var initial_busy: usize = 0;
    var fragmented: bool = false;
    var calls: usize = 0;
    var accepted: usize = 0;
    var slept: u64 = 0;
    var opens: usize = 0;
    var closes: usize = 0;
    var connections_closed: usize = 0;
    var close_result: i32 = 0;
    var timeout_at: usize = 0;
    var close_after_calls: usize = 0;
    var clock_after_calls: usize = 0;
    var first_write: ?u64 = null;
    var largest_source_lead: u64 = 0;
    var pcm: [192_000]u8 = undefined;

    fn reset() void {
        now = 0;
        hz = 1000;
        sleep_available = true;
        write_cost = 0;
        initial_busy = 0;
        fragmented = false;
        calls = 0;
        accepted = 0;
        slept = 0;
        opens = 0;
        closes = 0;
        connections_closed = 0;
        close_result = 0;
        timeout_at = 0;
        close_after_calls = 0;
        clock_after_calls = 0;
        first_write = null;
        largest_source_lead = 0;
    }
    fn ticks() callconv(.c) u64 {
        return now;
    }
    fn sleep(count: u64) callconv(.c) void {
        slept += count;
        now += count;
    }
    fn clock(out: *a.MonotonicClockInfo) callconv(.c) i32 {
        out.* = .{ .flags = a.monotonic_clock_flag_valid, .source = 1, .generation = if (clock_after_calls != 0 and calls >= clock_after_calls) 2 else 1, .resolution_ns = 1, .instant_ns = now * 1_000_000, .event_requested_hz = hz, .event_effective_hz = hz };
        return 1;
    }
    fn output(_: [*]const u8, len: u32) callconv(.c) i32 {
        return @intCast(len);
    }
    fn open(_: [*:0]const u8, out: *a.ServiceInfo) callconv(.c) i32 {
        out.* = .{ .handle = 1 };
        return 0;
    }
    fn disconnect(_: u32) callconv(.c) i32 {
        connections_closed += 1;
        return 0;
    }
    fn call(_: u32, op: u16, bytes: [*]const u8, len: u32, header: *a.ServiceMessageHeader, response: [*]u8, capacity: u32, _: u64) callconv(.c) i32 {
        if (capacity < @sizeOf(a.AudioServiceStreamResult)) return -1;
        var reply = a.AudioServiceStreamResult{ .action = op, .stream_id = 7 };
        switch (op) {
            a.audio_service_op_open_stream => {
                opens += 1;
                reply.result = 7;
                const req = std.mem.bytesToValue(a.AudioServiceStreamOpenRequest, bytes[0..@sizeOf(a.AudioServiceStreamOpenRequest)]);
                if (req.rate != 48_000 or req.channels != 2) return -1;
            },
            a.audio_service_op_write_stream => {
                const began = now;
                now += write_cost;
                calls += 1;
                if (timeout_at != 0 and calls == timeout_at) return a.service_api_result_timeout;
                const n = @sizeOf(a.AudioServiceStreamWriteRequest);
                if (len < n) return -1;
                const req = std.mem.bytesToValue(a.AudioServiceStreamWriteRequest, bytes[0..n]);
                if (req.stream_id != 7 or req.byte_count != len - n or accepted + req.byte_count > pcm.len) return -1;
                // A short accepted prefix, then Busy, then the untouched tail.
                const count: usize = if (calls <= initial_busy) 0 else if (fragmented and (calls - initial_busy) % 3 == 1) @min(400, req.byte_count) else if (fragmented and (calls - initial_busy) % 3 == 2) 0 else req.byte_count;
                @memcpy(pcm[accepted..][0..count], bytes[n..][0..count]);
                accepted += count;
                if (count != 0) {
                    if (first_write == null) first_write = began;
                    const elapsed_frames: u64 = @intCast(@as(u128, now - first_write.?) * 48_000 / @max(hz, 1));
                    largest_source_lead = @max(largest_source_lead, accepted / 4 -| elapsed_frames);
                }
                reply.result = if (count == 0) a.service_api_result_busy else @intCast(count);
                reply.bytes = @intCast(count);
            },
            a.audio_service_op_close_stream => {
                closes += 1;
                reply.result = close_result;
            },
            else => return -1,
        }
        @memcpy(response[0..@sizeOf(@TypeOf(reply))], std.mem.asBytes(&reply));
        header.* = .{ .op = op, .status = 0, .payload_len = @sizeOf(@TypeOf(reply)) };
        return @sizeOf(@TypeOf(reply));
    }

    fn shouldClose(_: *const a2.R4XStartContext2) callconv(.c) u32 {
        return @intFromBool(close_after_calls != 0 and calls >= close_after_calls);
    }
    fn run(args: [:0]const u8, ticks_available: bool) i32 {
        var raw: a2.R4XStartContext2 = .{ .args = @intFromPtr(args.ptr), .args_len = @intCast(args.len), .app_class = 1, .flags = a.r4xstart_flag_imports_valid | a.r4xstart_flag_close_supported, .should_close = @intFromPtr(@as(a2.R4XStartShouldCloseFn2, &shouldClose)) };
        var sys: a2.R4XStartR4Sys2 = .{};
        sys.ticks = if (ticks_available) @intFromPtr(&ticks) else 0;
        sys.sleep_ticks = if (sleep_available) @intFromPtr(&sleep) else 0;
        sys.monotonic_clock = if (ticks_available) @intFromPtr(&clock) else 0;
        sys.write = @intFromPtr(&output);
        sys.service_open = @intFromPtr(&open);
        sys.service_close = @intFromPtr(&disconnect);
        sys.service_call = @intFromPtr(&call);
        const audio: a2.R4XStartR4Audio2 = .{};
        const imports = [_]a.R4XStartImport{
            .{ .group_id = 1, .resolved_version = 2, .table = @intFromPtr(&sys) },
            .{ .group_id = 5, .resolved_version = 2, .table = @intFromPtr(&audio) },
        };
        raw.imports = @intFromPtr(&imports);
        raw.import_count = imports.len;
        var instance = switch (r4os.App2.init(&raw, .console)) {
            .value => |value| value,
            .failure => return -99,
        };
        return app.r4_app_main(&instance);
    }
};

fn expectTone(blocks: usize) !void {
    try t.expectEqual(blocks * 3840, Host.accepted);
    for (0..blocks * 960) |frame| {
        const expected: u16 = if (frame % 96 < 48) 12_000 else @bitCast(@as(i16, -12_000));
        for (0..2) |channel| {
            const index = frame * 4 + channel * 2;
            try t.expectEqual(@as(u8, @truncate(expected)), Host.pcm[index]);
            try t.expectEqual(@as(u8, @truncate(expected >> 8)), Host.pcm[index + 1]);
        }
    }
    try t.expectEqual(@as(usize, 1), Host.opens);
    try t.expectEqual(@as(usize, 1), Host.closes);
    try t.expectEqual(@as(usize, 1), Host.connections_closed);
}

test "fast BEEP retains the source lead exact PCM and actual close" {
    Host.reset();
    try t.expectEqual(@as(i32, 0), Host.run("", true));
    try expectTone(50);
    try t.expectEqual(@as(u64, 1000), Host.now);
    // At most the retained160-ms lead plus the one20-ms write just accepted.
    // A bulk write followed only by a one-second final sleep must fail this.
    try t.expectEqual(@as(u64, 8640), Host.largest_source_lead);
    Host.reset();
    Host.now = 5000; // Time before the first write is not earlier playback.
    try t.expectEqual(@as(i32, 0), Host.run("/SELFTEST", true));
    try expectTone(10);
    try t.expectEqual(@as(u64, 5200), Host.now);
}

test "slow BEEP writes consume the pacing budget including final drain" {
    Host.reset();
    Host.write_cost = 25; // Already longer than each 20-ms block.
    try t.expectEqual(@as(i32, 0), Host.run("", true));
    try expectTone(50);
    try t.expectEqual(@as(u64, 1250), Host.now);
    try t.expectEqual(@as(u64, 0), Host.slept);
    Host.reset();
    Host.initial_busy = 5;
    Host.write_cost = 40;
    try t.expectEqual(@as(i32, 0), Host.run("/SELFTEST", true));
    try expectTone(10);
    try t.expectEqual(@as(u64, 605), Host.now);
    try t.expectEqual(@as(u64, 5), Host.slept); // Only the unchanged Busy yield.
}

test "BEEP preserves accepted partial prefixes across Busy without double time" {
    Host.reset();
    Host.write_cost = 25;
    Host.fragmented = true;
    try t.expectEqual(@as(i32, 0), Host.run("/SELFTEST", true));
    try expectTone(10);
    try t.expectEqual(@as(usize, 30), Host.calls);
    try t.expectEqual(@as(u64, 750), Host.now);
    try t.expectEqual(@as(u64, 0), Host.slept);
}

test "BEEP never turns a failed real close into success" {
    Host.reset();
    Host.close_result = a.service_api_result_busy;
    try t.expect(Host.run("/SELFTEST", true) != 0);
    try t.expectEqual(@as(usize, 38_400), Host.accepted);
    try t.expectEqual(@as(usize, 1), Host.closes);
    try t.expectEqual(@as(usize, 0), Host.connections_closed);
}

test "BEEP rejects unavailable timing before creating a stream" {
    Host.reset();
    try t.expect(Host.run("/SELFTEST", false) != 0);
    try t.expectEqual(@as(usize, 0), Host.opens);
    try t.expectEqual(@as(usize, 0), Host.accepted);
    Host.reset();
    Host.hz = 0;
    try t.expect(Host.run("/SELFTEST", true) != 0);
    try t.expectEqual(@as(usize, 0), Host.opens);
    Host.reset();
    Host.sleep_available = false;
    try t.expect(Host.run("/SELFTEST", true) != 0);
    try t.expectEqual(@as(usize, 0), Host.opens);
}

test "BEEP total deadline uncertainty close and clock replacement keep exact source ownership" {
    Host.reset();
    Host.initial_busy = 100_000;
    Host.write_cost = 1;
    try t.expect(Host.run("/SELFTEST", true) != 0);
    try t.expectEqual(@as(usize, 0), Host.accepted);
    try t.expectEqual(@as(u64, 5000), Host.now);
    try t.expectEqual(@as(usize, 1), Host.closes);
    try t.expectEqual(@as(usize, 1), Host.connections_closed);
    Host.reset();
    Host.fragmented = true;
    Host.timeout_at = 2;
    try t.expect(Host.run("/SELFTEST", true) != 0);
    try t.expectEqual(@as(usize, 2), Host.calls);
    try t.expectEqual(@as(usize, 400), Host.accepted);
    try t.expectEqual(@as(usize, 1), Host.closes);
    Host.reset();
    Host.close_after_calls = 1;
    try t.expect(Host.run("/SELFTEST", true) != 0);
    try t.expectEqual(@as(usize, 1), Host.calls);
    try t.expectEqual(@as(usize, 1), Host.closes);
    try t.expectEqual(@as(usize, 1), Host.connections_closed);
    Host.reset();
    Host.clock_after_calls = 1;
    try t.expect(Host.run("/SELFTEST", true) != 0);
    try t.expectEqual(@as(usize, 1), Host.calls);
    try t.expectEqual(@as(usize, 1), Host.closes);
}
