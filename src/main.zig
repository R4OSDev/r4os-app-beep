const r4os = @import("r4os");
const time = r4os.time_contract.checked;

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

pub fn r4_app_main(app: *r4os.App2) i32 {
    const sys = app.system();
    const audio = app.audio() orelse return r4os.abi.err_no_group;
    const selftest = hasArg(app.args(), selftest_arg);
    var pcm: [block_bytes]u8 = undefined;
    fillSquare(pcm[0..]);

    sys.println(if (selftest) "BEEP selftest" else "BEEP AUDIO TEST");
    const initial = sampleClock(sys) orelse {
        sys.println("AUDIO CLOCK UNAVAILABLE");
        return 1;
    };
    var pacer = r4os.pcm_source.Pacer.init(sample_rate, frame_bytes, audio_prefill_frames, initial) catch return 1;
    var stream = switch (audio.openStream(sample_rate, channels, .s16le, r4os.app_audio.default_volume, operationTimeout())) {
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
    while (remaining > 0) : (remaining -= 1) {
        if (!writeAudioBlock(sys, &stream, pcm[0..], &pacer)) {
            ok = false;
            break;
        }
    }
    if (ok) ok = waitSource(sys, &pacer, true);

    if (switch (stream.close(operationTimeout())) {
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

fn operationTimeout() r4os.abi.R4Timeout {
    return r4os.time_contract.timeoutFinite(.{ .nanoseconds = 5_000_000_000 });
}

fn sampleClock(sys: r4os.r4sys.Context) ?time.ClockSample {
    if (!sys.hasFn("sleep_ticks")) return null;
    var info: r4os.abi.MonotonicClockInfo = .{};
    if (sys.monotonicClock(&info) <= 0) return null;
    const sample = time.ClockSample.fromInfo(info) catch return null;
    return if (sample.identity.tick_hz == 0) null else sample;
}

fn waitSource(sys: r4os.r4sys.Context, pacer: *r4os.pcm_source.Pacer, finish: bool) bool {
    while (!sys.programShouldClose()) {
        const now = sampleClock(sys) orelse return false;
        const deadline = pacer.deadline(now, finish) catch return false;
        if (deadline.wait_ns == 0) return true;
        const ticks = time.scaleCeil(deadline.wait_ns, now.identity.tick_hz, 1_000_000_000) catch return false;
        sys.sleepTicks(ticks);
    }
    return false;
}

fn writeAudioBlock(sys: r4os.r4sys.Context, stream: *r4os.AudioStream, data: []const u8, pacer: *r4os.pcm_source.Pacer) bool {
    var writer: r4os.audio_write.Writer = undefined;
    if (r4os.audio_write.Writer.init(.{ .address = @intFromPtr(data.ptr), .length = data.len }, .fromStream(stream), operationTimeout(), &writer) != 0) return false;
    var accepted: u64 = 0;
    while (true) {
        const began = sampleClock(sys) orelse return false;
        var progress: r4os.audio_write.Progress = undefined;
        if (writer.writeBounded(64, sys.programShouldClose(), &progress) != 0) return false;
        const prefix = progress.io.bytes - accepted;
        accepted = progress.io.bytes;
        if (prefix != 0) {
            _ = pacer.accepted(prefix, began) catch return false;
            if (!waitSource(sys, pacer, false)) return false;
        }
        const outcome: r4os.stream_transfer.Outcome = @enumFromInt(progress.io.outcome);
        switch (outcome) {
            .complete => return true,
            .pending => {},
            .would_block => if (prefix == 0) sys.sleepTicks(1),
            else => return false,
        }
    }
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
