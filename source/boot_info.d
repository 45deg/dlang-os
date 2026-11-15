/// UEFIローダーとカーネルで起動情報の配置を共有する。initBootInfoで受け取り、各機能に公開する。
module boot_info;

// 起動時に確保した物理ページを上位にマップする。ユーザープロセスでも同じ位置を使う。
enum ulong directMapOffset = 0xffff_8000_0000_0000;
enum ulong bootPhysicalLimit = 32UL << 40;

struct BootFramebuffer
{
    uint* address;
    uint width, height, pitchBytes;
    ubyte redShift, greenShift, blueShift;
}

struct BootInfo
{
    BootFramebuffer framebuffer;
    uint* backBuffer;
    ulong usableKiB;
}

static assert(BootFramebuffer.sizeof == 24 && BootInfo.sizeof == 40);

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
