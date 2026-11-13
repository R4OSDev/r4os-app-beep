//! Explicit private guest observer. It never creates or changes audio itself.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
var line: [1024]u8 = undefined;

fn status(sys: r4os.r4sys.Context, out: *a.AudioServiceStatus) bool {
    const end = sys.ticks() +| sys.ticksFromMilliseconds(3000);
    while (true) {
        const result = sys.audioServiceStatus(out);
        if (result == 0) return true;
        if (result != a.service_api_result_busy or sys.ticks() >= end) return false;
        sys.sleepTicks(1);
    }
}

fn output(sys: r4os.r4sys.Context, observation: *const a.ProgramObservationHandle, text: []u8) ?[]const u8 {
    var count: u32 = 0;
    if (sys.programObservationRead(observation, 0, text, &count) != 0 or count > text.len) return null;
    return text[0..count];
}

fn waitText(sys: r4os.r4sys.Context, desk: r4os.r4desk.Context, child: *const a.ProgramProcessHandle, wanted: []const u8) bool {
    const end = sys.ticks() +| sys.ticksFromMilliseconds(2000);
    var text: [4096]u8 = undefined;
    while (sys.ticks() < end) {
        // ObservationRead owns the immutable terminal transcript, not live
        // output. The strong unreaped child keeps this legacy console ID bound.
        var live: a.ProgramInstanceInfo = .{};
        if (sys.programHandleStatus(child, &live) != 0 or live.id != child.instance_id or live.state != 0) return false;
        const count = desk.consoleOutput(child.instance_id, &text);
        if (count >= 0 and count <= text.len and std.mem.indexOf(u8, text[0..@intCast(count)], wanted) != null) return true;
        sys.sleepTicks(1);
    }
    return false;
}

pub fn r4_app_main(app: *r4os.App2) i32 {
    const sys = app.system();
    const dev = app.devicesLowLevel() orelse return 2;
    const desk = app.desktop() orelse return 3;
    const mode = if (app.args().len != 0) app.args()[0] else 'B';
    var before: a.AudioServiceStatus = .{};
    if (!status(sys, &before) or before.open_sessions != 0 or before.materialized_sessions != 0) return 4;
    const perf_before = dev.performanceSummary() orelse return 5;
    if (perf_before.audio_open_streams != 0) return 6;
    var owner: u32 = 0;
    for (1..257) |candidate| {
        const item = dev.driverModuleInfo(@intCast(candidate)) orelse continue;
        const name = item.driver_name[0..(std.mem.indexOfScalar(u8, &item.driver_name, 0) orelse item.driver_name.len)];
        if (std.mem.eql(u8, name, "HDA")) {
            owner = item.owner;
            break;
        }
    }
    if (owner == 0) return 7;
    const work_before = dev.performanceDriverWork(owner) orelse return 8;
    const beep = mode == 'B' or mode == 'N';
    const path: [*:0]const u8 = if (beep) "C:\\R4OS\\SOFTWARE\\TERMINAL\\BEEP.R4X" else "C:\\R4OS\\SOFTWARE\\TERMINAL\\SYNTH.R4X";
    const args: [*:0]const u8 = switch (mode) {
        'B', 'S' => "/SELFTEST",
        'N' => "",
        'W' => "C:\\TEMP\\PCM57.WAV",
        'C' => "C:\\TEMP\\CVT57.WAV",
        'P', 'Q' => "C:\\TEMP\\LONG57.WAV",
        else => return 9,
    };
    var child: a.ProgramProcessHandle = .{};
    const start = sys.ticks();
    const spawned = sys.programSpawnWithConsoleHostHandle(path, args, .console, .terminal_window, &child);
    if (spawned < 0) return 10;
    var done: a.ProgramProcessCompletion = .{};
    var reaped = false;
    defer if (!reaped) {
        _ = sys.programHandleKill(&child);
        _ = sys.programHandleWait(&child, sys.ticksFromMilliseconds(3000), &done);
        _ = sys.programHandleReap(&child, &done);
    };
    var observation: a.ProgramObservationHandle = .{};
    if (sys.programObservationRetain(&child, 0, &observation) != 0) return 11;
    var released = false;
    defer if (!released) {
        _ = sys.programObservationRelease(&observation);
    };
    var pause_bytes: u64 = 0;
    var pause_stable = false;
    if (mode == 'P' or mode == 'Q') {
        if (!waitText(sys, desk, &child, "Playing WAV.")) return 12;
        sys.sleepTicks(sys.ticksFromMilliseconds(80));
        if (desk.consolePushKey(child.instance_id, if (mode == 'P') 'p' else 'q') != 0) return 13;
        if (mode == 'P') {
            if (!waitText(sys, desk, &child, "Paused")) return 14;
            var paused: a.AudioServiceStatus = .{};
            var later: a.AudioServiceStatus = .{};
            if (!status(sys, &paused)) return 15;
            sys.sleepTicks(sys.ticksFromMilliseconds(220));
            if (!status(sys, &later)) return 16;
            pause_bytes = paused.bytes_written - before.bytes_written;
            pause_stable = later.bytes_written == paused.bytes_written;
            if (!pause_stable or desk.consolePushKey(child.instance_id, 'p') != 0) return 17;
        }
    }
    const waited = sys.programObservationWait(&observation, sys.ticksFromMilliseconds(5000), &done);
    var text: [4096]u8 = undefined;
    const bytes = if (waited == 0) output(sys, &observation, &text) else null;
    if (waited != 0 or bytes == null) return 18;
    const complete = bytes.?;
    sys.write(complete);
    var after: a.AudioServiceStatus = .{};
    if (!status(sys, &after)) return 19;
    const perf_after = dev.performanceSummary() orelse return 20;
    const work_after = dev.performanceDriverWork(owner) orelse return 21;
    const receipt = sys.programHandleReap(&child, &done);
    reaped = receipt == 0;
    const release = sys.programObservationRelease(&observation);
    released = release == 0;
    const accepted = after.bytes_written - before.bytes_written;
    const expected: u64 = switch (mode) {
        'B' => 38_400,
        'N' => 192_000,
        'W' => 38_400,
        'C' => 35_280,
        'S' => 512,
        'P', 'Q' => 115_200,
        else => unreachable,
    };
    const marker = if (beep) (if (mode == 'B') "BEEP selftest: OK" else "AUDIO STREAM OK") else if (mode == 'S') "SYNTH selftest: OK" else "Done.";
    const ok = done.handle.instance_id == child.instance_id and done.handle.generation == child.generation and done.exit_code == 0 and
        complete.len == done.output_length and std.mem.indexOf(u8, complete, marker) != null and receipt == 0 and release == 0 and
        (if (mode == 'Q') accepted > 0 and accepted < expected else accepted == expected) and
        (mode != 'P' or pause_stable) and after.open_sessions == 0 and after.materialized_sessions == 0 and perf_after.audio_open_streams == 0 and
        perf_after.audio_backend_ok > perf_before.audio_backend_ok and perf_after.audio_backend_errors == perf_before.audio_backend_errors and
        work_after.owner_used_slots == 0 and work_after.owner_queued_slots == 0 and work_after.owner_running_slots == 0 and
        work_after.metrics.submitted_task_class > work_before.metrics.submitted_task_class;
    sys.println(std.fmt.bufPrint(&line, "PCM57 mode={c} child={d}:{d} exit={d} wait={d} fulltext={d} reap={d} release={d} accepted_source={d} elapsed_ticks={d} pause_bytes={d} pause_stable={d} core_open={d} sessions={d} materialized={d} driver_used={d} driver_queued={d} driver_running={d} idle_jobs={d} backend_ok_delta={d} backend_errors_delta={d} playback_frames=unavailable pass={d}", .{
        mode,                                                               child.instance_id,          child.generation,              done.exit_code,      waited,                      complete.len,                receipt,                       release,                        accepted,                                                                           sys.ticks() - start,
        pause_bytes,                                                        @intFromBool(pause_stable), perf_after.audio_open_streams, after.open_sessions, after.materialized_sessions, work_after.owner_used_slots, work_after.owner_queued_slots, work_after.owner_running_slots, work_after.metrics.submitted_task_class - work_before.metrics.submitted_task_class, perf_after.audio_backend_ok - perf_before.audio_backend_ok,
        perf_after.audio_backend_errors - perf_before.audio_backend_errors, @intFromBool(ok),
    }) catch "PCM57 report overflow");
    return if (ok) 0 else 1;
}
