/// UEFIの空きRAMだけをページ単位で管理する。allocatePageはゼロ化し、freePageは再利用リストへ戻す。
module physical_memory;

import boot_info : availableRanges, directMapOffset;

enum pageBytes = 4096;
private __gshared ulong freeHead, freeCount, totalCount;

nothrow @nogc:

void initPhysicalMemory()
{
    foreach (range; availableRanges())
        foreach (page; 0 .. range.pages)
            freePage(range.physical + page * pageBytes);
    totalCount = freeCount;
}

ulong allocatePage()
{
    const page = freeHead;
    if (page == 0)
        return 0;
    auto words = cast(ulong*) (directMapOffset + page);
    freeHead = words[0];
    --freeCount;
    words[0 .. pageBytes / ulong.sizeof] = 0;
    return page;
}

/// 呼び出し側が所有するページを一度だけ返す。共有コードやMMIOを渡さない。
void freePage(ulong page)
{
    *cast(ulong*) (directMapOffset + page) = freeHead;
    freeHead = page;
    ++freeCount;
}

ulong freeMemoryKiB() { return freeCount * (pageBytes / 1024); }
ulong managedMemoryKiB() { return totalCount * (pageBytes / 1024); }
