/// ブート時の上位マッピングを共有し、プロセスごとにコード、スタック、ELF用ヒープをマップする。
module address_space;

import boot_info : directMapOffset;
import cpu : readCr3, writeCr3;
import user_abi : userHeapBase, userHeapBytes;

enum ulong userCodeAddress = 0x0040_0000;
enum uint pageBytes = 4096;
enum uint userImagePages = 8;
enum ulong userImageEnd = userCodeAddress + userImagePages * pageBytes;
enum ulong userStackBase = 0x0041_0000;
enum ulong userStackTop = userStackBase + pageBytes;
private enum stackIndex = (userStackBase - userCodeAddress) / pageBytes;
private enum heapIndex = (userHeapBase - userCodeAddress) / pageBytes;
private enum heapPages = userHeapBytes / pageBytes;
private enum userHeapEnd = userHeapBase + userHeapBytes;
static assert(userHeapBase >= userStackTop + pageBytes && userHeapBase % pageBytes == 0);
static assert(userHeapBytes % pageBytes == 0 && heapIndex + heapPages <= 512);
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
    private Page[userImagePages] image;
    private Page[heapPages] heap;
    private ulong stackPhysical;
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
    const root = physicalAddress(cast(ulong) &space.root);
    const pdpt = physicalAddress(cast(ulong) &space.pdpt);
    const directory = physicalAddress(cast(ulong) &space.directory);
    const table = physicalAddress(cast(ulong) &space.table);
    const stack = physicalAddress(cast(ulong) &space.stack);
    if (root == 0 || pdpt == 0 || directory == 0 || table == 0 || stack == 0)
        return false;

    // 上位側は共有し、プロセスからアクセスできるページは下位側にだけ割り当てる。
    foreach (i; 256 .. 512)
        space.root.words[i] = kernelRoot.words[i] & ~user;
    const walkFlags = present | writable | user;
    space.root.words[0] = pdpt | walkFlags;
    space.pdpt.words[0] = directory | walkFlags;
    space.directory.words[2] = table | walkFlags;
    space.stackPhysical = stack;
    space.cr3 = root;
    return true;
}

void resetUserSpace(ref AddressSpace space)
{
    space.table.words[] = 0;
    space.stack.words[] = 0;
    space.table.words[stackIndex] = space.stackPhysical | present | user | writable | noExecute;
}

bool mapBuiltin(ref AddressSpace space)
{
    const code = physicalAddress(cast(ulong) &__user_app_start);
    if (code == 0)
        return false;
    space.table.words[0] = code | present | user;
    return true;
}

bool mapUserHeap(ref AddressSpace space)
{
    foreach (i, ref page; space.heap)
    {
        const physical = physicalAddress(cast(ulong) &page);
        if (physical == 0)
            return false;
        page.words[] = 0;
        space.table.words[heapIndex + i] = physical | present | writable | user | noExecute;
    }
    return true;
}

bool mapImage(ref AddressSpace space, ulong address, ulong memorySize,
              scope const(char)[] data, bool write, bool execute)
{
    if (address < userCodeAddress || address >= userImageEnd || address % pageBytes != 0
        || memorySize == 0 || memorySize > userImageEnd - address || data.length > memorySize
        || (write && execute))
        return false;

    const first = (address - userCodeAddress) / pageBytes;
    const count = (memorySize + pageBytes - 1) / pageBytes;
    const flags = present | user | (write ? writable : 0) | (execute ? 0 : noExecute);
    foreach (i; 0 .. count)
    {
        const index = first + i;
        if (space.table.words[index] != 0)
            return false;
        auto page = &space.image[index];
        const physical = physicalAddress(cast(ulong) page);
        if (physical == 0)
            return false;
        page.words[] = 0; // ゼロ初期化領域と、前のプロセスが残したデータの両方を消す。
        auto bytes = cast(char*) page;
        const offset = i * pageBytes;
        if (offset < data.length)
            foreach (j; offset .. (data.length < offset + pageBytes ? data.length : offset + pageBytes))
                bytes[j - offset] = data[j];
        space.table.words[index] = physical | flags;
    }
    return true;
}

/// カーネルのCR3へ復帰後に呼ぶ。ユーザーが示した仮想アドレスを直接参照しない。
bool copyFromUser(ref const AddressSpace space, ulong address, scope char[] output)
{
    if (address < userCodeAddress || address >= userHeapEnd || output.length > userHeapEnd - address)
        return false;
    size_t copied;
    while (copied < output.length)
    {
        const index = (address - userCodeAddress) / pageBytes;
        const entry = space.table.words[index];
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
    if (address < userCodeAddress || address >= userHeapEnd || input.length > userHeapEnd - address)
        return false;
    const flags = present | user | writable;
    size_t copied;
    while (copied < input.length)
    {
        const index = (address - userCodeAddress) / pageBytes;
        const entry = space.table.words[index];
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
