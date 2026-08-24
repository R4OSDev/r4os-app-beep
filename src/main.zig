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
    if (@as(u64, selftest_blocks) * block_frames < audio_prefill_frames) @compileError("BEEP selftest cannot reach the HDA start window");
}

const PlaybackPacer = struct {
    timer_hz: u64,
    buffered_frames: u64 = 0,
    remainder: u64 = 0,

    fn accepted(self: *PlaybackPacer, sys: r4os.r4sys.Context, bytes: usize) void {
        self.buffered_frames += @as(u64, @intCast(bytes / frame_bytes));
        if (self.buffered_frames <= audio_prefill_frames) return;
        const paced_frames = self.buffered_frames - audio_prefill_frames;
        self.buffered_frames = audio_prefill_frames;
        self.sleepFrames(sys, paced_frames);
    }

    fn drain(self: *PlaybackPacer, sys: r4os.r4sys.Context) void {
        const frames = self.buffered_frames;
        self.buffered_frames = 0;
        self.sleepFrames(sys, frames);
    }

    fn sleepFrames(self: *PlaybackPacer, sys: r4os.r4sys.Context, frames: u64) void {
        if (frames == 0) return;
        const wait_ticks = ticksForFrames(frames, sample_rate, self.timer_hz, &self.remainder);
        if (wait_ticks != 0) sys.sleepTicks(wait_ticks);
    }
};

pub fn r4_app_main(app: *r4os.App) i32 {
    const sys = app.system();
    const audio = app.audio() orelse return r4os.abi.err_no_group;
    const selftest = hasArg(app.args(), selftest_arg);
    var pcm: [block_bytes]u8 = undefined;
    fillSquare(pcm[0..]);

    sys.println(if (selftest) "BEEP selftest" else "BEEP AUDIO TEST");
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
    var pacer = PlaybackPacer{ .timer_hz = effectiveTimerHz(sys.monotonicHz()) };
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
        const advance = cursor.apply(stream.write(data[cursor.accepted..], r4os.time_contract.timeoutForever()));
        switch (advance.outcome) {
            .complete => {
                if (advance.accepted != 0) pacer.accepted(sys, advance.accepted);
                return cursor.done();
            },
            .retry => {
                if (advance.accepted != 0) pacer.accepted(sys, advance.accepted) else sys.sleepTicks(1);
            },
            .timed_out, .failure, .invalid => return false,
        }
    }
    return true;
}

fn effectiveTimerHz(value: u32) u64 {
    return if (value == 0) 100 else value;
}

fn ticksForFrames(frames: u64, rate: u64, timer_hz: u64, remainder: *u64) u64 {
    if (rate == 0) return 1;
    const numerator = frames * timer_hz + remainder.*;
    const ticks = numerator / rate;
    remainder.* = numerator % rate;
    return ticks;
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
