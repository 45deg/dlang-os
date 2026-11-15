/// ELFにLimineの要求を埋め込み、物理メモリ情報と描画用フレームバッファを受け取る。
module limine;

import core.volatile : volatileLoad;
import ldc.attributes : section;

private struct MemoryMapEntry
{
    ulong physicalBase;
    ulong lengthBytes;
    ulong type;
}

private struct MemoryMapResponse
{
    ulong revision;
    ulong entryCount;
    const(MemoryMapEntry*)* entries;
}

private struct Request
{
    ulong[4] id;
    ulong revision;
    ulong responseAddress;
}

private enum ulong usableMemory = 0;
private __gshared bool bootBufferTaken;

// 値と構造体の配置はLimine Boot Protocolに従う。
// ブートローダーが起動前に書き換える値はvolatileLoadで読む。
@section(".limine_requests_start")
private __gshared ulong[4] requestsStart = [
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9,
];

@section(".limine_requests")
private __gshared ulong[3] baseRevision = [0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 6];

@section(".limine_requests")
private __gshared Request memoryMap = {
    id: [0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62],
};

// 描画に使うv0の先頭フィールド。EDIDとモード一覧は参照しない。
struct BootFramebuffer
{
    void* address;
    ulong width;
    ulong height;
    ulong pitchBytes;
    ushort bitsPerPixel;
    ubyte memoryModel;
    ubyte redSize;
    ubyte redShift;
    ubyte greenSize;
    ubyte greenShift;
    ubyte blueSize;
    ubyte blueShift;
}

private struct FramebufferResponse
{
    ulong revision;
    ulong count;
    const(BootFramebuffer*)* frames;
}

@section(".limine_requests")
private __gshared Request framebuffer = {
    id: [0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x9d5827dcd881dd75, 0xa3148604f6fab11b],
};

private struct DirectMapResponse
{
    ulong revision;
    ulong offset;
}

@section(".limine_requests")
private __gshared Request directMap = {
    id: [0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x48dcf1cb8ad2b852, 0x63984e959a98244b],
};

@section(".limine_requests_end")
private __gshared ulong[2] requestsEnd = [0xadc0e0531bb10d03, 0x9572709f31764c62];

nothrow @nogc:

bool supportsRequestedRevision()
{
    return volatileLoad(&baseRevision[2]) == 0;
}

/// メモリマップがない場合はfalse。返すのは利用可能な領域の合計で、搭載量ではない。
bool usableMemoryKiB(out ulong totalKiB)
{
    const response = memoryMapResponse();
    if (response is null)
        return false;

    ulong totalBytes;
    foreach (i; 0 .. response.entryCount)
    {
        const entry = response.entries[i];
        if (entry.type == usableMemory)
            totalBytes += entry.lengthBytes;
    }
    totalKiB = totalBytes / 1024;
    return true;
}

/// 起動時の描画に使う連続領域を一度だけ確保する。他のカーネル領域はELFに含まれる。
void* reserveBootBuffer(ulong bytes)
{
    const response = memoryMapResponse();
    const offset = directMapOffset();
    if (bootBufferTaken || response is null || offset == 0 || bytes == 0)
        return null;

    foreach (i; 0 .. response.entryCount)
    {
        const entry = response.entries[i];
        if (entry.type == usableMemory && entry.lengthBytes >= bytes)
        {
            bootBufferTaken = true;
            return cast(void*) (offset + entry.physicalBase);
        }
    }
    return null;
}

private const(MemoryMapResponse)* memoryMapResponse()
{
    return cast(const(MemoryMapResponse)*) volatileLoad(&memoryMap.responseAddress);
}

const(BootFramebuffer)* bootFramebuffer()
{
    const response = cast(const(FramebufferResponse)*) volatileLoad(&framebuffer.responseAddress);
    if (response is null || response.count == 0)
        return null;
    return response.frames[0];
}

ulong directMapOffset()
{
    const response = cast(const(DirectMapResponse)*) volatileLoad(&directMap.responseAddress);
    return response is null ? 0 : response.offset;
}
