/// BootPagesはUEFIで確保した連続領域を分割する。PageTablesはカーネルと引き渡しコードをマップする。
module boot_paging;

import ldc.llvmasm : __asm;

enum ulong pageBytes = 4096;
enum ulong pageTableCoverage = 512 * pageBytes;
enum ulong pageWritable = 1 << 1;
enum ulong pageUncached = (1 << 3) | (1 << 4);
enum ulong pageNoExecute = 1UL << 63;
private enum ulong pagePresent = 1;
private enum ulong physicalMask = 0x000f_ffff_ffff_f000;

ulong roundToPage(ulong bytes) pure nothrow @nogc
{
    return (bytes + pageBytes - 1) & ~(pageBytes - 1);
}

struct BootPages
{
    ulong nextPhysical, remainingBytes;

    ulong take(ulong bytes) nothrow @nogc
    {
        if (bytes > remainingBytes)
            return 0;
        const physical = nextPhysical;
        nextPhysical += bytes;
        remainingBytes -= bytes;
        return physical;
    }
}

struct PageTables
{
    ulong root;
    private BootPages* pages;

    this(ref BootPages pool) nothrow @nogc
    {
        pages = &pool;
        root = pages.take(pageBytes);
    }

    /// 仮想アドレスと物理アドレスはページ境界に揃える。既存エントリには上書きしない。
    bool map(ulong address, ulong physical, ulong bytes, ulong flags) nothrow @nogc
    {
        if (root == 0)
            return false;
        for (ulong offset = 0; offset < bytes; offset += pageBytes)
        {
            auto table = cast(ulong*) root;
            const virtualPage = address + offset;
            foreach (shift; [39, 30, 21])
            {
                auto link = &table[(virtualPage >> shift) & 511];
                if (*link == 0)
                {
                    const nextTable = pages.take(pageBytes);
                    if (nextTable == 0)
                        return false;
                    *link = nextTable | pagePresent | pageWritable;
                }
                table = cast(ulong*) (*link & physicalMask);
            }

            auto leaf = &table[(virtualPage >> 12) & 511];
            if (*leaf != 0)
                return false;
            *leaf = (physical + offset) | pagePresent | flags;
        }
        return true;
    }
}

bool supportsKernelPaging() nothrow @nogc
{
    enum fiveLevelPaging = 1 << 12;
    const cr4 = __asm!ulong("movq %cr4, $0", "=r");
    if (cr4 & fiveLevelPaging)
        return false;

    const maxExtendedLeaf = __asm!uint("cpuid", "={eax},0,~{ebx},~{ecx},~{edx}", 0x8000_0000U);
    if (maxExtendedLeaf < 0x8000_0001U)
        return false;
    const extendedFeatures = __asm!uint("cpuid", "={edx},{eax},~{eax},~{ebx},~{ecx}", 0x8000_0001U);
    return (extendedFeatures & (1U << 20)) != 0; // NX
}

// RCX=CR3、RDX=スタック末尾、R8=ELF入口、R9=BootInfo。CR3の切り替え後は
// ファームウェアのスタックに触れず、SysVの第1引数をRDIに置いてカーネルへ入る。
extern(C) void enterKernel(ulong, ulong, ulong, ulong) nothrow @nogc
{
    asm pure nothrow @nogc {
        naked;
        cli;
        cld;
        mov R10, RCX;
        mov R11, RDX;
        mov ECX, 0xc0000080; // EFER.NXE
        rdmsr;
        or EAX, 0x800;
        wrmsr;
        mov RAX, CR0;
        or RAX, 0x10000; // CR0.WP
        mov CR0, RAX;
        mov RAX, CR4;
        and RAX, -129; // PGEを落とし、ファームウェアのグローバルTLBエントリを破棄する。
        mov CR4, RAX;
        mov CR3, R10;
        mov RSP, R11;
        xor EBP, EBP;
        mov RDI, R9;
        call R8;
        ud2;
    }
}
