/// 512バイトのブロックI/O契約。ドライバは容量と読書き関数を登録し、上位層はポートを知らない。
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

    /// 成功時には書き込みが永続化している。キャッシュを使うドライバはここでフラッシュする。
    bool write(ulong lba, ref const Sector sector) nothrow @nogc
    {
        return lba < sectorCount && writeBlock !is null && writeBlock(context, lba, sector);
    }
}
