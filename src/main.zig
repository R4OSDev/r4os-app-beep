const r4os = @import("r4os");

const sample_rate = 48_000;
const channels = 2;
const block_frames = 1024;
const block_bytes = block_frames * channels * @sizeOf(i16);
const block_count = 50;
const selftest_blocks = 2;
const selftest_arg = "/SELFTEST";

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
    while (remaining > 0) : (remaining -= 1) {
        const written = stream.write(pcm[0..], r4os.time_contract.timeoutForever());
        if (switch (written) {
            .written => |bytes| bytes != pcm.len,
            else => true,
        }) ok = false;
        sys.sleepTicks(2);
    }

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
