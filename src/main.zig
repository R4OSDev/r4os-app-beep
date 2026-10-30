const r4os = @import("r4os");

const sample_rate: u32 = 48_000;
const channels: usize = 2;
const frame_bytes: usize = channels * @sizeOf(i16);
const block_frames: u32 = 960;
const block_bytes: usize = block_frames * frame_bytes;
const block_count: u32 = 50;
const selftest_blocks: u32 = 10;
const audio_prefill_milliseconds: u64 = 160;
const audio_prefill_frames: u64 = (@as(u64, sample_rate) * audio_prefill_milliseconds + 999) / 1000;
const selftest_arg = "/SELFTEST";

comptime {
    if (block_bytes > r4os.app_audio.max_write_payload) @compileError("BEEP block exceeds one AudioService write payload");
    if (@as(u64, selftest_blocks) * block_frames < audio_prefill_frames) @compileError("BEEP selftest must cover the full 160-ms source lead");
}

const PlaybackPacer = struct {
    timer_hz: u64,
    end_scaled: ?u128 = null,

    fn accepted(self: *PlaybackPacer, sys: r4os.r4sys.Context, bytes: usize, write_started: u64) void {
        // Absolute source schedule in ticks * sample_rate, preserving fractions.
        // RPC time counts too; an expired schedule grants no future burst credit.
        const start = @as(u128, write_started) * sample_rate;
        const end = @max(self.end_scaled orelse start, start) + @as(u128, bytes / frame_bytes) * self.timer_hz;
        self.end_scaled = end;
        // This is a source lead, not a receipt that the device has started.
        self.waitUntil(sys, end -| (@as(u128, audio_prefill_frames) * self.timer_hz));
    }

    fn drain(self: *PlaybackPacer, sys: r4os.r4sys.Context) void {
        const end = self.end_scaled orelse return;
        self.waitUntil(sys, end);
        self.end_scaled = null;
    }

    fn waitUntil(_: *const PlaybackPacer, sys: r4os.r4sys.Context, deadline: u128) void {
        while (true) {
            const now = @as(u128, sys.ticks()) * sample_rate;
            if (now >= deadline) return;
            sys.sleepTicks(@intCast((deadline - now + sample_rate - 1) / sample_rate));
        }
    }
};

pub fn r4_app_main(app: *r4os.App) i32 {
    const sys = app.system();
    const audio = app.audio() orelse return r4os.abi.err_no_group;
    const selftest = hasArg(app.args(), selftest_arg);
    var pcm: [block_bytes]u8 = undefined;
    fillSquare(pcm[0..]);

    sys.println(if (selftest) "BEEP selftest" else "BEEP AUDIO TEST");
    const timer_hz = sys.monotonicHz();
    if (timer_hz == 0 or !sys.hasFn("ticks") or !sys.hasFn("sleep_ticks")) {
        sys.println("AUDIO CLOCK UNAVAILABLE");
        return 1;
    }
    var stream = switch (audio.openStream(sample_rate, channels, .s16le, r4os.app_audio.default_volume, r4os.time_contract.timeoutForever())) {
        .stream => |value| value,
        else => {
            sys.println("AUDIO STREAM FAILED");
            return 1;
        },
    };
    if (!stream.valid()) {
        sys.println("AUDIO STREAM FAILED");
        return 1;
    }

    var ok = true;
    var remaining: u32 = if (selftest) selftest_blocks else block_count;
    var pacer = PlaybackPacer{ .timer_hz = timer_hz };
    while (remaining > 0) : (remaining -= 1) {
        if (!writeAudioBlock(sys, &stream, pcm[0..], &pacer)) {
            ok = false;
            break;
        }
    }
    if (ok) pacer.drain(sys);

    if (switch (stream.close(r4os.time_contract.timeoutForever())) {
        .ok => false,
        else => true,
    }) ok = false;
    if (ok) {
        sys.println(if (selftest) "BEEP selftest: OK" else "AUDIO STREAM OK");
        return 0;
    }
    sys.println(if (selftest) "BEEP selftest: FAILED" else "AUDIO STREAM FAILED");
    return 1;
}

fn writeAudioBlock(sys: r4os.r4sys.Context, stream: *r4os.AudioStream, data: []const u8, pacer: *PlaybackPacer) bool {
    var cursor = r4os.app_audio.WriteCursor.init(data.len, frame_bytes) orelse return false;
    while (!cursor.done()) {
        const write_started = sys.ticks();
        const advance = cursor.apply(stream.write(data[cursor.accepted..], r4os.time_contract.timeoutForever()));
        switch (advance.outcome) {
            .complete => {
                if (advance.accepted != 0) pacer.accepted(sys, advance.accepted, write_started);
                return cursor.done();
            },
            .retry => {
                if (advance.accepted != 0) pacer.accepted(sys, advance.accepted, write_started) else sys.sleepTicks(1);
            },
            .timed_out, .failure, .invalid => return false,
        }
    }
    return true;
}

fn fillSquare(out: []u8) void {
    var frame: usize = 0;
    while (frame < out.len / 4) : (frame += 1) {
        const sample: i16 = if ((frame % 96) < 48) 12000 else -12000;
        writeI16(out, frame * 4, sample);
        writeI16(out, frame * 4 + 2, sample);
    }
}

fn writeI16(out: []u8, index: usize, sample: i16) void {
    const bits: u16 = @bitCast(sample);
    out[index] = @intCast(bits & 0xFF);
    out[index + 1] = @intCast(bits >> 8);
}

fn hasArg(args: []const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < args.len) {
        while (offset < args.len and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < args.len and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}
