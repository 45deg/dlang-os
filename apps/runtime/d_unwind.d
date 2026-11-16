/// Handle SjLj exceptions in Ring 3. Walk the frames registered by LLVM and use
/// selectLandingPad to choose a catch or cleanup. _Unwind_Resume advances to the next frame after cleanup.
module d_unwind;

import ldc.llvmasm : __asm;
import user_abi : Call, writeLimit;
import user_api : exitApp, send;

private struct LandingPad
{
    uint index;
    int selector = -1; // -1 skips the frame, 0 runs cleanup, and positive values identify catch types.
}

private alias Personality = extern(C) LandingPad function(const(Frame)*, TypeInfo_Class) nothrow @nogc;

// x86-64 SjLj context for LDC 1.43.0. Slots within a function are 32 bits wide,
// and user space for the exception object is below 4 GiB.
private struct Frame
{
    Frame* previous;
    int callSite;
    uint[4] landingValues;
    Personality personality;
    const(ubyte)* table;
    size_t[5] jumpBuffer;
}

static assert(Frame.callSite.offsetof == 8 && Frame.landingValues.offsetof == 12);
static assert(Frame.personality.offsetof == 32 && Frame.table.offsetof == 40 && Frame.jumpBuffer.offsetof == 48);

private __gshared Frame* activeFrame;
extern(C) extern __gshared ubyte __exception_table_start, __exception_table_end;

extern(C) void _Unwind_SjLj_Register(Frame* frame) nothrow @nogc
{
    frame.previous = activeFrame;
    activeFrame = frame;
}

extern(C) void _Unwind_SjLj_Unregister(Frame* frame) nothrow @nogc
{
    assert(activeFrame is frame);
    activeFrame = frame.previous;
}

private bool containsTableBytes(const(ubyte)* address, size_t count) nothrow @nogc
{
    const start = cast(size_t) &__exception_table_start;
    const end = cast(size_t) &__exception_table_end;
    const at = cast(size_t) address;
    return at >= start && at <= end && count <= end - at;
}

private ubyte tableByte(ref const(ubyte)* cursor) nothrow @nogc
{
    assert(containsTableBytes(cursor, 1));
    return *cursor++;
}

// LSDA offsets fit in 32 bits because this ELF is limited to 16 KiB.
private long tableLeb(ref const(ubyte)* cursor, bool signedValue = false) nothrow @nogc
{
    long value;
    for (uint shift = 0; shift < 32; shift += 7)
    {
        const part = tableByte(cursor);
        value |= cast(long)(part & 0x7f) << shift;
        if (!(part & 0x80))
            return signedValue && (part & 0x40) ? value | (-1L << (shift + 7)) : value;
    }
    assert(0, "Invalid SjLj LEB128");
}

private bool catches(TypeInfo_Class type, TypeInfo_Class target) nothrow @nogc
{
    if (target is null)
        return true; // catch-all
    for (; type !is null; type = type.base)
        if (type is target)
            return true;
    return false;
}

// LLVM registers this symbol's address. Within this application it receives only the SjLj frame and D type.
private extern(C) pragma(mangle, "_d_eh_personality")
LandingPad selectLandingPad(const(Frame)* frame, TypeInfo_Class thrownType) nothrow @nogc
{
    const(ubyte)* cursor = frame.table;
    const landingBaseEncoding = tableByte(cursor);
    assert(landingBaseEncoding == 0xff); // LPStart is omitted.
    const encoding = tableByte(cursor);
    assert(encoding == 0xff || encoding == 0x03); // Type pointers are omitted or encoded as absolute 32-bit values.

    const(ubyte)* types;
    if (encoding != 0xff)
    {
        const offset = tableLeb(cursor);
        assert(containsTableBytes(cursor, offset));
        types = cursor + offset;
    }

    tableByte(cursor); // SjLj call-site entries use ULEB128 regardless of this encoding byte.
    const callSiteBytes = tableLeb(cursor);
    assert(containsTableBytes(cursor, callSiteBytes));
    const actions = cursor + callSiteBytes;

    LandingPad pad;
    long action;
    // callSite is one-based. Landing pad numbers in the table are zero-based.
    foreach (_; 0 .. frame.callSite)
    {
        assert(cursor < actions);
        pad.index = cast(uint) tableLeb(cursor);
        action = tableLeb(cursor);
        assert(cursor <= actions);
    }
    if (action == 0)
        return LandingPad(pad.index, 0);

    const(ubyte)* entry = actions + action - 1;
    const maxActions = cast(size_t) &__exception_table_end - cast(size_t) actions;
    // If no type matches but cleanup is present, enter the landing pad with selector 0.
    foreach (_; 0 .. maxActions)
    {
        assert(entry >= actions);
        const filter = tableLeb(entry, true);
        assert(filter >= 0);
        if (filter == 0)
            pad.selector = 0;
        else
        {
            assert(types !is null);
            const address = types - filter * uint.sizeof;
            assert(containsTableBytes(address, uint.sizeof));
            auto target = cast(TypeInfo_Class) cast(void*) cast(size_t) *cast(const(uint)*) address;
            if (catches(thrownType, target))
                return LandingPad(pad.index, cast(int) filter);
        }
        auto afterFilter = entry;
        const next = tableLeb(afterFilter, true);
        if (next == 0)
            return pad;
        entry += next;
    }
    assert(0, "Cyclic SjLj action table");
}

// Restore RBP, RSP, and the dispatch target in the same order as LLVM's built-in longjmp.
private extern(C) noreturn jumpToLandingPad(const(size_t)*) nothrow @nogc
{
    asm @nogc nothrow { naked; }
    __asm(q{
        movq 0(%rdi), %rbp
        movq 16(%rdi), %rsp
        jmpq *8(%rdi)
    }, "~{memory}");
    assert(0);
}

private noreturn unwind(Throwable thrown, Frame* frame) nothrow @nogc
{
    assert(thrown !is null && cast(size_t) cast(void*) thrown <= uint.max);
    auto type = typeid(thrown);
    for (; frame !is null; frame = frame.previous)
    {
        if (frame.callSite <= 0)
            continue;
        const pad = frame.personality(frame, type);
        if (pad.selector < 0)
            continue;

        activeFrame = frame;
        frame.callSite = cast(int) pad.index;
        frame.landingValues[0] = cast(uint) cast(size_t) cast(void*) thrown;
        frame.landingValues[1] = cast(uint) pad.selector;
        jumpToLandingPad(frame.jumpBuffer.ptr);
    }

    send(Call.write, "Uncaught D throwable: ");
    send(Call.write, thrown.msg[0 .. thrown.msg.length < writeLimit ? thrown.msg.length : writeLimit]);
    send(Call.write, "\n");
    exitApp();
}

extern(C) noreturn _d_throw_exception(Throwable thrown)
{
    unwind(thrown, activeFrame);
}

extern(C) noreturn _Unwind_Resume(Throwable thrown)
{
    assert(activeFrame !is null);
    unwind(thrown, activeFrame.previous);
}

extern(C) Throwable _d_eh_enter_catch(Throwable thrown) nothrow @nogc
{
    return thrown;
}
