/// Define the x64 UEFI tables, protocols, and status codes used by the loader.
module uefi;

alias Status = ulong;
alias Handle = void*;

enum Status success = 0;
enum Status errorBit = 1UL << 63;
enum Status invalidParameter = errorBit | 2;
enum Status unsupported = errorBit | 3;
enum Status bufferTooSmall = errorBit | 5;
enum Status loadError = errorBit | 1;
enum Status outOfResources = errorBit | 9;
enum uint allocateMaxAddress = 1;
enum uint loaderData = 2;
enum uint conventionalMemory = 7;

struct Guid
{
    uint data1;
    ushort data2, data3;
    ubyte[8] data4;
}

immutable Guid loadedImageGuid =
    Guid(0x5b1b31a1, 0x9562, 0x11d2, [0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b]);
immutable Guid simpleFileSystemGuid =
    Guid(0x964e5b22, 0x6459, 0x11d2, [0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b]);
immutable Guid graphicsOutputGuid =
    Guid(0x9042a9de, 0x23dc, 0x4a38, [0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a]);

// Compile for Windows x64 so extern(C) uses the UEFI calling convention.
extern(C)
{
    struct TableHeader
    {
        ulong signature;
        uint revision, headerSize, crc32, reserved;
    }

    struct SystemTable
    {
        TableHeader header;
        const(wchar)* firmwareVendor;
        uint firmwareRevision;
        void*[6] console;
        RuntimeServices* runtimeServices;
        BootServices* bootServices;
    }

    struct Time
    {
        ushort year;
        ubyte month, day, hour, minute, second, pad1;
        uint nanosecond;
        short timezone;
        ubyte daylight, pad2;
    }
    struct RuntimeServices
    {
        TableHeader header;
        Status function(Time*, void*) nothrow @nogc getTime;
    }
    static assert(Time.sizeof == 16 && SystemTable.runtimeServices.offsetof == 88);

    struct BootServices
    {
        TableHeader header;
        void*[2] tpl;
        Status function(uint, uint, size_t, ulong*) nothrow @nogc allocatePages;
        Status function(ulong, size_t) nothrow @nogc freePages;
        Status function(size_t*, void*, size_t*, size_t*, uint*) nothrow @nogc getMemoryMap;
        Status function(uint, size_t, void**) nothrow @nogc allocatePool;
        Status function(void*) nothrow @nogc freePool;
        void*[9] eventsAndProtocolRegistration;
        Status function(Handle, const(Guid)*, void**) nothrow @nogc handleProtocol;
        void*[9] protocolAndImageServices;
        Status function(Handle, size_t) nothrow @nogc exitBootServices;
        void*[10] timerAndOpenProtocolServices;
        Status function(const(Guid)*, void*, void**) nothrow @nogc locateProtocol;
    }

    struct LoadedImage
    {
        uint revision;
        Handle parentHandle;
        SystemTable* systemTable;
        Handle deviceHandle;
        void* filePath;
        void* reserved;
        uint loadOptionsSize;
        void* loadOptions;
        void* imageBase;
        ulong imageSize;
    }

    struct SimpleFileSystem
    {
        ulong revision;
        Status function(SimpleFileSystem*, File**) nothrow @nogc openVolume;
    }

    struct File
    {
        ulong revision;
        Status function(File*, File**, const(wchar)*, ulong, ulong) nothrow @nogc open;
        Status function(File*) nothrow @nogc close;
        void* remove;
        Status function(File*, size_t*, void*) nothrow @nogc read;
        void* write;
        Status function(File*, ulong*) nothrow @nogc getPosition;
        Status function(File*, ulong) nothrow @nogc setPosition;
    }

    struct GraphicsOutput
    {
        Status function(GraphicsOutput*, uint, size_t*, GraphicsInfo**) nothrow @nogc queryMode;
        Status function(GraphicsOutput*, uint) nothrow @nogc setMode;
        void* blt;
        GraphicsMode* mode;
    }
}

struct GraphicsMode
{
    uint maxMode, mode;
    GraphicsInfo* info;
    size_t infoSize;
    ulong framebufferBase;
    size_t framebufferSize;
}

enum PixelFormat : uint { rgb, bgr, bitMask, bltOnly }

struct GraphicsInfo
{
    uint revision, width, height;
    PixelFormat pixelFormat;
    uint redMask, greenMask, blueMask, reservedMask;
    uint pixelsPerScanLine;
}

struct MemoryDescriptor
{
    uint type;
    ulong physicalStart, virtualStart, pageCount, attributes;
}

static assert(Guid.sizeof == 16 && MemoryDescriptor.sizeof == 40);
static assert(SystemTable.bootServices.offsetof == 96);
static assert(BootServices.handleProtocol.offsetof == 152);
static assert(BootServices.exitBootServices.offsetof == 232);
static assert(BootServices.locateProtocol.offsetof == 320);
static assert(LoadedImage.imageBase.offsetof == 64 && File.setPosition.offsetof == 56);
