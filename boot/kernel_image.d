/// 固定アドレスにリンクしたカーネルELFを検査し、PT_LOADを確保済みの物理ページに配置する。
module kernel_image;

import boot_info : directMapOffset;
import boot_paging : PageTables, pageBytes, pageNoExecute, pageWritable, roundToPage;
import runtime : memcpy;

private enum ulong kernelBase = 0xffff_ffff_8000_0000;
enum ulong maxKernelBytes = 32 * 1024 * 1024;
private enum uint loadSegment = 1;
private enum uint flagExecute = 1, flagWrite = 2, flagRead = 4;

private struct ElfHeader
{
    ubyte[16] ident;
    ushort type, machine;
    uint elfVersion;
    ulong entry, programOffset, sectionOffset;
    uint flags;
    ushort headerSize, programEntrySize, programCount;
    ushort sectionEntrySize, sectionCount, sectionNames;
}

private struct ProgramHeader
{
    uint type, flags;
    ulong offset, address, physical, fileBytes, memoryBytes, alignment;
}

static assert(ElfHeader.sizeof == 64 && ProgramHeader.sizeof == 56);

struct KernelImage
{
    ulong entry, memoryBytes;
    private const(ubyte)[] file;
    private const(ProgramHeader)[] programs;

    bool parse(const(ubyte)[] image) nothrow @nogc
    {
        if (image.length < ElfHeader.sizeof)
            return false;
        const header = cast(const(ElfHeader)*) image.ptr;
        if (header.ident[0 .. 7] != [0x7f, 'E', 'L', 'F', 2, 1, 1]
            || header.type != 2 || header.machine != 62 || header.elfVersion != 1
            || header.headerSize != ElfHeader.sizeof || header.programEntrySize != ProgramHeader.sizeof
            || header.programCount == 0 || header.programOffset < ElfHeader.sizeof
            || header.programOffset % ProgramHeader.alignof != 0
            || !contains(image.length, header.programOffset, header.programCount * ProgramHeader.sizeof))
            return false;

        const entries = cast(const(ProgramHeader)*) (image.ptr + header.programOffset);
        const programHeaders = entries[0 .. header.programCount];
        ulong end;
        bool entryIsExecutable;
        foreach (ref const segment; programHeaders)
        {
            if (segment.type != loadSegment)
                return false;
            if ((segment.flags & ~7U) || !(segment.flags & flagRead)
                || (segment.flags & (flagExecute | flagWrite)) == (flagExecute | flagWrite)
                || segment.address < kernelBase || segment.address % pageBytes != 0
                || segment.alignment != pageBytes || segment.offset % pageBytes != 0
                || segment.memoryBytes == 0 || segment.fileBytes > segment.memoryBytes
                || !contains(image.length, segment.offset, segment.fileBytes)
                || !contains(maxKernelBytes, segment.address - kernelBase, segment.memoryBytes))
                return false;

            const segmentEnd = segment.address - kernelBase + segment.memoryBytes;
            if (segmentEnd > end)
                end = segmentEnd;
            if ((segment.flags & flagExecute) && header.entry >= segment.address
                && header.entry - segment.address < segment.fileBytes)
                entryIsExecutable = true;
        }
        if (!entryIsExecutable)
            return false;
        entry = header.entry;
        memoryBytes = roundToPage(end);
        file = image;
        programs = programHeaders;
        return true;
    }

    /// physicalBaseはゼロ化済み。ELFに含まれないBSSはそのまま残す。
    bool load(ulong physicalBase, ref PageTables tables) const nothrow @nogc
    {
        foreach (ref const segment; programs)
        {
            const physical = physicalBase + (segment.address - kernelBase);
            const write = (segment.flags & flagWrite) ? pageWritable : 0;
            const executeProtection = (segment.flags & flagExecute) ? 0 : pageNoExecute;
            // ダイレクトマップ経由でも、ELFの読み取り専用ページには書き込めない。
            if (!tables.map(segment.address, physical, segment.memoryBytes, write | executeProtection)
                || !tables.map(directMapOffset + physical, physical, segment.memoryBytes, write | pageNoExecute))
                return false;
            memcpy(cast(void*) physical, file.ptr + segment.offset, segment.fileBytes);
        }
        return true;
    }
}

private bool contains(ulong size, ulong offset, ulong bytes) pure nothrow @nogc
{
    return offset <= size && bytes <= size - offset;
}
