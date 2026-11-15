/// initClockはPIT channel 2でTSCを校正する。millisecondsは起動後の経過時間を返す。
/// 現在の単一CPU向け。校正後のTSC周波数が一定であることを前提とする。
module clock;

import cpu : readPort, writePort, ticks;

private enum pitHz = 1_193_182;
private enum ushort calibrationCount = 23_864; // 約20 ms
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
    // 時刻源の初期化前だけは、壊れたPITで永久待機しないため回数で制限する。
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
