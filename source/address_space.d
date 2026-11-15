/// ブート時の上位マッピングを共有し、プロセスごとにコード、スタック、ELF用ヒープをマップする。
module address_space;

import boot_info : directMapOffset;
import physical_memory : allocatePage, freePage;
import cpu : readCr3, writeCr3;
import user_abi : userHeapBase, userHeapInitialBytes, userHeapLimitBytes, callError;

enum ulong userCodeAddress = 0x0040_0000;
enum uint pageBytes = 4096;
// ELF、ヒープ、ガード付きスタックを別々の仮想領域に置く。物理ページは必要時に確保する。
enum ulong userImageEnd = userHeapBase;
enum ulong userStackTop = 0x8000_0000;
enum ulong userStackBase = userStackTop - 64 * 1024;
private enum ulong userAddressEnd = userStackTop;
static assert(userHeapBase + userHeapLimitBytes < userStackBase);
private enum ulong apicAddress = 0xffff_c000_0000_0000;
private enum ulong physicalMask = 0x000f_ffff_ffff_f000;
private enum ulong owned = 1 << 9; // OS用ビット。共有コードは回収しない。
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
    private Page* root;
    private ulong heapBytes;
    ulong cr3;
}

private __gshared Page* kernelRoot;
private __gshared Page mmioPdpt, mmioDirectory, mmioTable;

extern(C) extern __gshared ubyte __user_app_start;

nothrow @nogc:

void initPaging()
{
    const cr3 = readCr3();
    kernelRoot = directPage(cr3 & physicalMask);
    // ローダーを等価マップしていた下位半分は、上位のカーネルへ移った時点で外せる。
    kernelRoot.words[0 .. 256] = 0;
    writeCr3(cr3);
}

bool initUserSpace(ref AddressSpace space)
{
    const root = allocatePage();
    if (root == 0) return false;
    space.root = directPage(root);
    space.cr3 = root;
    foreach (i; 256 .. 512)
        space.root.words[i] = kernelRoot.words[i] & ~user;
    for (ulong address = userStackBase; address < userStackTop; address += pageBytes)
        if (!mapZeroPage(space, address, writable | noExecute))
            return false;
    return true;
}

/// カーネルのCR3に戻ってから、部分的な初期化も含めて下位側の所有ページを回収する。
void releaseUserSpace(ref AddressSpace space)
{
    if (space.root !is null)
    {
        foreach (entry; space.root.words[0 .. 256])
            if (entry & present)
                releaseTree(entry & physicalMask, 3);
        freePage(space.cr3);
    }
    space = AddressSpace.init;
}

private void releaseTree(ulong physical, uint levels)
{
    foreach (entry; directPage(physical).words)
    {
        if (!(entry & present)) continue;
        if (levels > 1)
            releaseTree(entry & physicalMask, levels - 1);
        else if (entry & owned)
            freePage(entry & physicalMask);
    }
    freePage(physical);
}

/// ページテーブルも必要な枝だけ作る。失敗時の空の枝はpruneTablesまたは終了時に回収する。
private ulong* leafFor(ref AddressSpace space, ulong address, bool create)
{
    auto table = space.root;
    foreach (shift; [39, 30, 21])
    {
        auto entry = &table.words[(address >> shift) & 511];
        if (!(*entry & present))
        {
            if (!create) return null;
            const physical = allocatePage();
            if (physical == 0) return null;
            *entry = physical | present | writable | user;
        }
        table = directPage(*entry & physicalMask);
    }
    return &table.words[(address >> 12) & 511];
}

private ulong entryAt(ref const AddressSpace space, ulong address)
{
    const(Page)* table = space.root;
    foreach (shift; [39, 30, 21])
    {
        const entry = table.words[(address >> shift) & 511];
        if (!(entry & present)) return 0;
        table = directPage(entry & physicalMask);
    }
    return table.words[(address >> 12) & 511];
}

private bool mapZeroPage(ref AddressSpace space, ulong address, ulong flags)
{
    auto leaf = leafFor(space, address, true);
    if (leaf is null || *leaf != 0) return false;
    const physical = allocatePage();
    if (physical == 0) return false;
    *leaf = physical | owned | present | user | flags;
    return true;
}

bool mapBuiltin(ref AddressSpace space)
{
    const code = physicalAddress(cast(ulong) &__user_app_start);
    auto leaf = leafFor(space, userCodeAddress, true);
    if (code == 0 || leaf is null || *leaf != 0) return false;
    *leaf = code | present | user;
    return true;
}

bool mapUserHeap(ref AddressSpace space)
{
    return resizeHeap(space, userHeapInitialBytes) != callError;
}

/// 要求サイズをページ境界へ丸めて返す。拡張失敗時は元のサイズと内容を維持する。
ulong resizeHeap(ref AddressSpace space, ulong requestedBytes)
{
    if (requestedBytes > userHeapLimitBytes) return callError;
    const bytes = (requestedBytes + pageBytes - 1) & ~(pageBytes - 1UL);
    if (bytes > space.heapBytes)
    {
        ulong offset = space.heapBytes;
        for (; offset < bytes; offset += pageBytes)
            if (!mapZeroPage(space, userHeapBase + offset, writable | noExecute))
            {
                unmapHeap(space, space.heapBytes, offset);
                pruneTables(space.root, 4);
                return callError;
            }
    }
    else if (bytes < space.heapBytes)
    {
        unmapHeap(space, bytes, space.heapBytes);
        pruneTables(space.root, 4);
    }
    space.heapBytes = bytes;
    return bytes;
}

private void unmapHeap(ref AddressSpace space, ulong start, ulong end)
{
    for (auto offset = start; offset < end; offset += pageBytes)
    {
        auto leaf = leafFor(space, userHeapBase + offset, false);
        if (leaf !is null && (*leaf & owned))
        {
            freePage(*leaf & physicalMask);
            *leaf = 0;
        }
    }
}

// 空になったテーブルを回収する。ルートの上位半分はカーネル共有なので触らない。
private bool pruneTables(Page* table, uint levels)
{
    bool empty = true;
    const count = levels == 4 ? 256 : 512;
    foreach (ref entry; table.words[0 .. count])
    {
        if (!(entry & present)) continue;
        if (levels > 1 && pruneTables(directPage(entry & physicalMask), levels - 1))
        {
            freePage(entry & physicalMask);
            entry = 0;
        }
        else empty = false;
    }
    return empty;
}

bool mapImage(ref AddressSpace space, ulong address, ulong memorySize,
              scope const(char)[] data, bool write, bool execute)
{
    if (address < userCodeAddress || address >= userImageEnd || address % pageBytes != 0
        || memorySize == 0 || memorySize > userImageEnd - address || data.length > memorySize
        || (write && execute))
        return false;

    const count = (memorySize + pageBytes - 1) / pageBytes;
    const flags = present | user | (write ? writable : 0) | (execute ? 0 : noExecute);
    foreach (i; 0 .. count)
    {
        auto leaf = leafFor(space, address + i * pageBytes, true);
        if (leaf is null || *leaf != 0)
            return false;
        const physical = allocatePage();
        if (physical == 0)
            return false;
        auto bytes = cast(char*) directPage(physical);
        const offset = i * pageBytes;
        if (offset < data.length)
            foreach (j; offset .. (data.length < offset + pageBytes ? data.length : offset + pageBytes))
                bytes[j - offset] = data[j];
        *leaf = physical | owned | flags;
    }
    return true;
}

/// カーネルのCR3へ復帰後に呼ぶ。ユーザーが示した仮想アドレスを直接参照しない。
bool copyFromUser(ref const AddressSpace space, ulong address, scope char[] output)
{
    if (address < userCodeAddress || address >= userAddressEnd || output.length > userAddressEnd - address)
        return false;
    size_t copied;
    while (copied < output.length)
    {
        const entry = entryAt(space, address);
        if ((entry & (present | user)) != (present | user))
            return false;
        const bytes = cast(const(char)*) directPage(entry & physicalMask);
        auto within = address % pageBytes;
        while (copied < output.length && within < pageBytes)
        {
            output[copied++] = bytes[within++];
            ++address;
        }
    }
    return true;
}

/// 入力イベントやファイルを、ユーザーが書き込めるページにだけ返す。
bool copyToUser(ref const AddressSpace space, ulong address, scope const(char)[] input)
{
    if (address < userCodeAddress || address >= userAddressEnd || input.length > userAddressEnd - address)
        return false;
    const flags = present | user | writable;
    size_t copied;
    while (copied < input.length)
    {
        const entry = entryAt(space, address);
        if ((entry & flags) != flags)
            return false;
        auto bytes = cast(char*) directPage(entry & physicalMask);
        auto within = address % pageBytes;
        while (copied < input.length && within < pageBytes)
        {
            bytes[within++] = input[copied++];
            ++address;
        }
    }
    return true;
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
    return cast(Page*) (directMapOffset + physical);
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
