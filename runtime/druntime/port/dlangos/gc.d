/// Supply druntime's allocation ABI without collection. Blocks and array used lengths
/// are tracked for upstream array growth; the kernel reclaims all blocks on process exit.
module dlangos.gc;

import dlangos.cabi : calloc, malloc;
import core.memory : GC;
import core.exception : onOutOfMemoryError;

private struct Allocation
{
    Allocation* next;
    void* base;
    size_t size, used;
    uint attributes;
}
private __gshared Allocation* allocations;

extern(C) nothrow:
void* gc_malloc(size_t size, uint attributes, const TypeInfo info)
{
    if (size == 0) return null;
    auto block = cast(Allocation*) malloc(Allocation.sizeof);
    auto data = calloc(1, size);
    if (block is null || data is null) onOutOfMemoryError();
    *block = Allocation(allocations, data, size, size, attributes);
    allocations = block;
    return data;
}

private Allocation* find(void* pointer)
{
    const address = cast(size_t) pointer;
    for (auto block = allocations; block !is null; block = block.next)
        if (address >= cast(size_t) block.base && address - cast(size_t) block.base < block.size)
            return block;
    return null;
}

GC.BlkInfo gc_query(void* pointer)
{
    if (auto block = find(pointer))
        return GC.BlkInfo(block.base, block.size, block.attributes);
    return GC.BlkInfo.init;
}

bool gc_expandArrayUsed(void[] slice, size_t newUsed, bool atomic)
{
    auto block = find(slice.ptr);
    if (block is null || !(block.attributes & GC.BlkAttr.APPENDABLE)) return false;
    const offset = cast(size_t) slice.ptr - cast(size_t) block.base;
    if (slice.length > block.size - offset || offset + slice.length != block.used || newUsed < slice.length || newUsed > block.size - offset)
        return false;
    block.used = offset + newUsed;
    return true;
}

bool gc_shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic)
{
    auto block = find(slice.ptr);
    if (block is null || !(block.attributes & GC.BlkAttr.APPENDABLE)) return false;
    const offset = cast(size_t) slice.ptr - cast(size_t) block.base;
    if (existingUsed > block.size - offset || offset + existingUsed != block.used || slice.length > existingUsed)
        return false;
    block.used = offset + slice.length;
    return true;
}

// No collector scans ranges in this process-lifetime allocator.
void gc_removeRange(void*) @nogc {}

// This port never creates object monitors. Do not silently accept a future monitor implementation.
void _d_monitordelete(Object object, bool detach) @nogc
{
    assert((cast(void**) object)[1] is null, "Object monitors are not supported");
}
