const platform = @import("../platform/platform.zig");

pub const Clock = struct {
    start_time: f64,
    elapsed: f64,
};

pub fn update(clock: *Clock) void {
    if (clock.start_time != 0) {
        clock.elapsed = platform.getAbsoluteTime() - clock.start_time;
    }
}

pub fn start(clock: *Clock) void {
    clock.start_time = platform.getAbsoluteTime();
    clock.elapsed = 0;
}

pub fn stop(clock: *Clock) void {
    clock.start_time = 0;
}
