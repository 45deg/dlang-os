/// Manage the heap for an ELF process. Handle new, array append, duplication, and concatenation. Array casts share storage.
module d_allocation;

import core.stdc.string : memcpy;
import core.internal.traits : hasElaborateCopyConstructor;
import user_abi : Call, userHeapBase, userHeapLimitBytes;
import user_api : call, exitApp, send;
import user_abi : userHeapInitialBytes, callError;

private __gshared size_t heapUsed;
private __gshared size_t heapCommitted = userHeapInitialBytes;
private enum classAlignment = 16; // Alignment LDC uses for heap-allocated classes on x86-64.

private struct ArrayBlock
{
    ArrayBlock* next;
    void* data;
    size_t used, capacity; // Byte counts.
}

private __gshared ArrayBlock* arrays;

// Allow new and ~= in D pure functions by hiding state private to this process's allocator.
private alias Allocation = void* function(size_t, size_t) pure;
private alias TypedAllocation = void* function(const TypeInfo, size_t, bool) pure;
private alias ArrayGrowth = void* function(void*, size_t, size_t, size_t) pure;

private noreturn outOfMemory()
{
    send(Call.write, "D application heap exhausted.\n");
    exitApp();
}

private void* tryAllocate(size_t bytes, size_t alignment)
{
    if (bytes == 0 || alignment == 0 || alignment > userHeapLimitBytes)
        return null;

    const address = (userHeapBase + heapUsed + alignment - 1) & ~(alignment - 1);
    const offset = address - userHeapBase;
    if (offset >= userHeapLimitBytes || bytes > userHeapLimitBytes - offset)
        return null;

    const required = offset + bytes;
    if (required > heapCommitted)
    {
        const committed = call(Call.heapResize, required);
        if (committed == callError) return null;
        heapCommitted = committed;
    }
    heapUsed = required;
    return cast(void*) address;
}

private void* allocate(size_t bytes, size_t alignment)
{
    if (auto result = tryAllocate(bytes, alignment))
        return result;
    outOfMemory();
}

private size_t arrayBytes(size_t count, size_t itemSize) pure
{
    if (itemSize == 0 || count > userHeapLimitBytes / itemSize)
        (cast(noreturn function() pure) &outOfMemory)();
    return count * itemSize;
}

private void* allocateArray(size_t used, size_t capacity, size_t alignment)
{
    auto block = cast(ArrayBlock*) allocate(ArrayBlock.sizeof, ArrayBlock.alignof);
    auto data = tryAllocate(capacity, alignment);
    if (data is null)
    {
        capacity = used;
        data = allocate(used, alignment);
    }
    *block = ArrayBlock(arrays, data, used, capacity);
    arrays = block;
    return data;
}

private void* appendSpace(void* data, size_t used, size_t required, size_t alignment)
{
    // When appending through a shorter alias, move to a new block to preserve entries that were already initialized.
    for (auto block = arrays; block !is null; block = block.next)
    {
        if (block.data is data && block.used == used && block.capacity >= required)
        {
            block.used = required;
            return data;
        }
    }

    const capacity = required <= userHeapLimitBytes / 2 ? required * 2 : required;
    auto result = allocateArray(required, capacity, alignment);
    if (used != 0)
        memcpy(result, data, used);
    return result;
}

/// LDC initializes classes and scalars at the call site.
extern(C) void* _d_allocclass(const TypeInfo_Class info)
{
    return allocate(info.m_init.length, classAlignment);
}

extern(C) void* _d_allocmemoryT(const TypeInfo info)
{
    return allocate(info.tsize, info.talign);
}

private void* allocateTypedArray(const TypeInfo item, size_t length, bool copyInitializer)
{
    if (length == 0)
        return null;
    const bytes = arrayBytes(length, item.tsize);
    auto data = allocateArray(bytes, bytes, item.talign);
    const initial = copyInitializer ? item.initializer() : null;
    // The kernel zeroes the heap. Repeat nonzero .init values within static array elements as well.
    if (initial.length != 0 && initial.ptr !is null)
        foreach (offset; 0 .. bytes / initial.length)
            memcpy(data + offset * initial.length, initial.ptr, initial.length);
    return data;
}

extern(C) void[] _d_newarrayT(const TypeInfo arrayType, size_t length)
{
    return allocateTypedArray(arrayType.next, length, false)[0 .. length];
}

extern(C) void[] _d_newarrayiT(const TypeInfo arrayType, size_t length)
{
    return allocateTypedArray(arrayType.next, length, true)[0 .. length];
}

extern(C) void[] _d_newarrayU(const TypeInfo arrayType, size_t length)
{
    return allocateTypedArray(arrayType.next, length, false)[0 .. length];
}

T* _d_newitemT(T)() pure @trusted
{
    auto item = cast(T*) (cast(Allocation) &allocate)(T.sizeof, T.alignof);
    static if (!__traits(isZeroInit, T))
    {
        static immutable T initial = T.init;
        memcpy(cast(void*) item, &initial, T.sizeof);
    }
    return item;
}

T _d_newclassT(T)() pure @trusted
{
    const initial = __traits(initSymbol, T);
    auto item = (cast(Allocation) &allocate)(initial.length, classAlignment);
    return cast(T) memcpy(item, initial.ptr, initial.length);
}

T[] _d_newarrayU(T)(size_t length, bool isShared = false) pure @trusted
{
    auto items = (cast(TypedAllocation) &allocateTypedArray)(typeid(T), length, false);
    return (cast(T*) items)[0 .. length];
}

T[] _d_newarrayT(T)(size_t length, bool isShared = false) pure @trusted
{
    auto items = (cast(TypedAllocation) &allocateTypedArray)(typeid(T), length, !__traits(isZeroInit, T));
    return (cast(T*) items)[0 .. length];
}

Tarr _d_newarraymTX(Tarr : U[], T, U)(scope size_t[] dimensions, bool isShared = false) pure @trusted
{
    if (dimensions.length == 0)
        return null;
    auto result = _d_newarrayT!U(dimensions[0]);
    static if (is(U == V[], V))
        if (dimensions.length > 1)
            foreach (ref row; result)
                row = _d_newarraymTX!(U, T)(dimensions[1 .. $]);
    return result;
}

void* _d_arrayliteralTX(T)(size_t length) pure @trusted
{
    return (cast(TypedAllocation) &allocateTypedArray)(typeid(T), length, false);
}

TTo[] __ArrayCast(TFrom, TTo)(return scope TFrom[] source) pure nothrow @nogc @trusted
{
    static assert(TTo.sizeof != 0, "Array cast requires a destination element size greater than zero");
    static if (TFrom.sizeof != 0)
        if (source.length > size_t.max / TFrom.sizeof)
            assert(0, "Array cast byte length overflow");

    const byteLength = source.length * TFrom.sizeof;
    if (byteLength % TTo.sizeof != 0)
        assert(0, "Array cast requires a whole number of destination elements");

    return (cast(TTo*) source.ptr)[0 .. byteLength / TTo.sizeof];
}

/// Used when LDC copies slice elements bytewise. Lengths are in elements.
extern(C) void _d_array_slice_copy(void* destination, size_t destinationLength,
    const(void)* source, size_t sourceLength, size_t elementSize) nothrow @nogc
{
    assert(destinationLength == sourceLength, "Array copy requires equal lengths");
    assert(elementSize == 0 || destinationLength <= size_t.max / elementSize,
        "Array copy byte length overflow");
    const bytes = destinationLength * elementSize;
    const from = cast(size_t) source;
    const to = cast(size_t) destination;
    const distance = from > to ? from - to : to - from;
    assert(distance >= bytes, "Array copy requires non-overlapping slices");
    if (bytes != 0)
        memcpy(destination, source, bytes);
}

Result _d_arraycatnTX(Result : T[], T, Parts...)(auto ref Parts parts) pure @trusted
{
    static assert(T.sizeof != 0 && !hasElaborateCopyConstructor!T,
        "Array concatenation requires nonzero elements that can be copied byte for byte");

    if (__ctfe)
    {
        Result result;
        foreach (ref part; parts)
            result ~= part;
        return result;
    }

    // Compute the total size first and allocate the result once, regardless of spare capacity in the inputs.
    enum maxLength = userHeapLimitBytes / T.sizeof;
    size_t length;
    foreach (ref part; parts)
    {
        static if (is(typeof(part) : T))
            const count = 1;
        else
            const count = part.length;
        if (count > maxLength - length)
            (cast(noreturn function() pure) &outOfMemory)();
        length += count;
    }

    auto result = _d_newarrayU!T(length);
    auto output = cast(void*) result.ptr;
    foreach (ref part; parts)
    {
        static if (is(typeof(part) : T))
        {
            T value = part;
            memcpy(output, &value, T.sizeof);
            output += T.sizeof;
        }
        else if (part.length != 0)
        {
            const bytes = part.length * T.sizeof;
            memcpy(output, part.ptr, bytes);
            output += bytes;
        }
    }
    return result;
}

// std.exception.enforce uses idup so the exception can keep a copy of the borrowed message.
@property immutable(T)[] idup(T)(scope T[] source) pure @trusted
if (__traits(isPOD, T) && is(T : immutable(T)))
{
    if (source.length == 0)
        return null;

    if (__ctfe)
    {
        immutable(T)[] result;
        foreach (item; source)
            result ~= item;
        return result;
    }

    auto copy = _d_newarrayU!T(source.length);
    memcpy(cast(void*) copy.ptr, source.ptr, source.length * T.sizeof);
    return cast(immutable(T)[]) copy;
}

ref Tarr _d_arrayappendcTX(Tarr : T[], T)(return ref scope Tarr array, size_t count) pure @trusted
{
    static assert(!hasElaborateCopyConstructor!T,
        "Array appending requires elements that can be copied byte for byte");
    if (count == 0)
        return array;

    const oldBytes = arrayBytes(array.length, T.sizeof);
    const extra = arrayBytes(count, T.sizeof);
    auto data = (cast(ArrayGrowth) &appendSpace)(cast(void*) array.ptr, oldBytes, oldBytes + extra, T.alignof);
    array = (cast(T*) data)[0 .. array.length + count];
    return array;
}

ref Tarr _d_arrayappendT(Tarr : T[], T)(return ref scope Tarr array, scope Tarr source) pure @trusted
{
    const oldLength = array.length;
    _d_arrayappendcTX(array, source.length);
    if (source.length != 0)
        memcpy(cast(void*) (array.ptr + oldLength), source.ptr, source.length * T.sizeof);
    return array;
}
