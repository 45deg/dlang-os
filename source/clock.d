/// initClock calibrates the TSC against the PIT. milliseconds returns elapsed time and currentDateTime uses the RTC snapshot.
/// Assumes a single CPU and a constant TSC frequency after calibration.
module clock;

import boot_info : bootDateTime, bootDateTimeValid, bootDateTimeTicks;
import calendar : DateTime, advance;

import cpu : readPort, writePort, ticks;

private enum pitHz = 1_193_182;
private enum ushort calibrationCount = 23_864; // About 20 ms.
private __gshared ulong ticksPerSecond, epoch;

nothrow @nogc:

bool initClock()
{
    const original = readPort(0x61);
    scope(exit) writePort(0x61, original);
    writePort(0x61, cast(ubyte) (original & ~3));
    writePort(0x43, 0xb0); // channel 2, low/high byte, mode 0
    writePort(0x42, cast(ubyte) calibrationCount);
    writePort(0x42, cast(ubyte) (calibrationCount >> 8));
    const start = ticks();
    writePort(0x61, cast(ubyte) ((original & ~2) | 1));
    // Use an iteration limit before the time source is initialized so a faulty PIT cannot cause an indefinite wait.
    foreach (_; 0 .. 10_000_000)
    {
        if (!(readPort(0x61) & 0x20))
            continue;
        const elapsed = ticks() - start;
        ticksPerSecond = elapsed * pitHz / calibrationCount;
        epoch = ticks();
        return ticksPerSecond >= 1000;
    }
    return false;
}

ulong milliseconds()
{
    const elapsed = ticks() - epoch;
    return elapsed / ticksPerSecond * 1000 + elapsed % ticksPerSecond * 1000 / ticksPerSecond;
}

/// Add seconds measured by the same TSC to the RTC snapshot taken before kernel startup.
bool currentDateTime(out DateTime time)
{
    if (!bootDateTimeValid() || ticksPerSecond == 0) return false;
    time = bootDateTime();
    return advance(time, (ticks() - bootDateTimeTicks()) / ticksPerSecond);
}
