/// Limineの上位マッピングを共有し、プロセスごとに下位のコードとスタックを設定する。
module address_space;

import cpu : readCr3, writeCr3;
import limine : directMapOffset;

enum ulong userCodeAddress = 0x0040_0000;
enum ulong userStackTop = 0x0040_3000;
enum uint pageBytes = 4096;
private enum ulong apicAddress = 0xffff_c000_0000_0000;
private enum ulong physicalMask = 0x000f_ffff_ffff_f000;
private enum ulong present = 1;
private enum ulong writable = 2;
private enum ulong user = 4;
private enum ulong noCache = 0x18; // PCDとPWTを立ててMMIOをキャッシュしない
private enum ulong huge = 0x80;
private enum ulong noExecute = 1UL << 63;

private struct Page
{
    align(pageBytes):
    ulong[pageBytes / ulong.sizeof] words;
}
static assert(Page.sizeof == pageBytes && Page.alignof == pageBytes);

struct AddressSpace
{
    private Page root, pdpt, directory, table, stack;
    ulong cr3;
}

private __gshared ulong directOffset;
private __gshared Page* kernelRoot;
private __gshared Page mmioPdpt, mmioDirectory, mmioTable;

extern(C) extern __gshared ubyte __user_app_start;

nothrow @nogc:

bool initPaging()
{
    directOffset = directMapOffset();
    if (directOffset == 0)
        return false;
    kernelRoot = directPage(readCr3() & physicalMask);
    return true;
}

bool initUserSpace(ref AddressSpace space)
{
    const code = physicalAddress(cast(ulong) &__user_app_start);
    const root = physicalAddress(cast(ulong) &space.root);
    const pdpt = physicalAddress(cast(ulong) &space.pdpt);
    const directory = physicalAddress(cast(ulong) &space.directory);
    const table = physicalAddress(cast(ulong) &space.table);
    const stack = physicalAddress(cast(ulong) &space.stack);
    if (code == 0 || root == 0 || pdpt == 0 || directory == 0 || table == 0 || stack == 0)
        return false;

    // プロセス間で共有するのは読み取り専用コードと、Ring 0からだけ触れる上位側。
    foreach (i; 256 .. 512)
        space.root.words[i] = kernelRoot.words[i] & ~user;
    const walkFlags = present | writable | user;
    space.root.words[0] = pdpt | walkFlags;
    space.pdpt.words[0] = directory | walkFlags;
    space.directory.words[2] = table | walkFlags;
    space.table.words[0] = code | present | user;
    // コードとスタックの間・上をマップせず、スタックからの実行も禁止する。
    space.table.words[2] = stack | present | user | writable | noExecute;
    space.cr3 = root;
    return true;
}

void resetUserStack(ref AddressSpace space)
{
    space.stack.words[] = 0;
}

uint* mapLocalApic(ulong physicalPage)
{
    const index = (apicAddress >> 39) & 511;
    if (physicalPage == 0 || kernelRoot.words[index] != 0)
        return null;
    const pdpt = physicalAddress(cast(ulong) &mmioPdpt);
    const directory = physicalAddress(cast(ulong) &mmioDirectory);
    const table = physicalAddress(cast(ulong) &mmioTable);
    if (pdpt == 0 || directory == 0 || table == 0)
        return null;

    mmioTable.words[0] = physicalPage | present | writable | noCache | noExecute;
    mmioDirectory.words[0] = table | present | writable;
    mmioPdpt.words[0] = directory | present | writable;
    kernelRoot.words[index] = pdpt | present | writable;
    writeCr3(readCr3());
    return cast(uint*) apicAddress;
}

private Page* directPage(ulong physical)
{
    return cast(Page*) (directOffset + physical);
}

private ulong physicalAddress(ulong address)
{
    auto table = kernelRoot;
    for (uint shift = 39; shift >= 12; shift -= 9)
    {
        const entry = table.words[(address >> shift) & 511];
        if (!(entry & present))
            return 0;
        if (shift == 12 || (shift != 39 && (entry & huge)))
        {
            const offsetMask = (1UL << shift) - 1;
            return (entry & physicalMask & ~offsetMask) | (address & offsetMask);
        }
        table = directPage(entry & physicalMask);
    }
    return 0;
}
