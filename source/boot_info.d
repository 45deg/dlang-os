/// UEFIローダーとカーネルで画面・メモリ・RTCの起動情報を共有する。initBootInfoで受け取る。
module boot_info;

import calendar : DateTime;

// 起動時に確保した物理ページを上位にマップする。ユーザープロセスでも同じ位置を使う。
enum ulong directMapOffset = 0xffff_8000_0000_0000;
enum ulong bootPhysicalLimit = 32UL << 40;

struct BootFramebuffer
{
    uint* address;
    uint width, height, pitchBytes;
    ubyte redShift, greenShift, blueShift;
}

struct MemoryRange
{
    ulong physical, pages;
}

struct BootInfo
{
    BootFramebuffer framebuffer;
    uint* backBuffer;
    DateTime rtc;
    bool rtcValid;
    ulong rtcTicks;
    ulong usableKiB;
    size_t rangeCount;
    MemoryRange[128] ranges; // 容量超過時はローダーが起動を拒否する。
}

static assert(BootFramebuffer.sizeof == 24 && BootInfo.sizeof <= 4096);

private __gshared BootInfo* bootInfo;

nothrow @nogc:

void initBootInfo(BootInfo* info)
{
    bootInfo = info;
}

ulong usableMemoryKiB()
{
    return bootInfo.usableKiB;
}

BootFramebuffer bootFramebuffer()
{
    return bootInfo.framebuffer;
}

uint* bootBackBuffer()
{
    return bootInfo.backBuffer;
}

MemoryRange[] availableRanges()
{
    return bootInfo.ranges[0 .. bootInfo.rangeCount];
}

DateTime bootDateTime() nothrow @nogc { return bootInfo.rtc; }
bool bootDateTimeValid() nothrow @nogc { return bootInfo.rtcValid; }
ulong bootDateTimeTicks() nothrow @nogc { return bootInfo.rtcTicks; }
