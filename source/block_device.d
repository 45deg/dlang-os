/// Define 512-byte block I/O. Drivers supply capacity and read/write functions and keep port access internal.
module block_device;

enum sectorBytes = 512;
alias Sector = ushort[sectorBytes / ushort.sizeof];

struct BlockDevice
{
    ulong sectorCount;
    void* context;
    bool function(void*, ulong, out Sector) nothrow @nogc readBlock;
    bool function(void*, ulong, ref const Sector) nothrow @nogc writeBlock;

    bool read(ulong lba, out Sector sector) nothrow @nogc
    {
        return lba < sectorCount && readBlock !is null && readBlock(context, lba, sector);
    }

    /// A successful write is persistent. Drivers with caches must flush them here.
    bool write(ulong lba, ref const Sector sector) nothrow @nogc
    {
        return lba < sectorCount && writeBlock !is null && writeBlock(context, lba, sector);
    }
}
