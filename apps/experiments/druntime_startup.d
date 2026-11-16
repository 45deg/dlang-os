/// Run real C ABI calls and upstream module lifecycle, then retain distinct TLS values across process switches.
module druntime_startup;
import druntime_dependency : sharedOrder, threadOrder;
import core.stdc.config : c_long, c_ulong;
import core.stdc.stddef : wchar_t;
import core.stdc.stdlib : malloc, calloc, realloc, free;
import core.stdc.errno : errno;
import dlangos.tls : mainTlsRange;
import core.volatile : volatileLoad, volatileStore;
import user_abi : Call;
import user_api : send, call;

extern(C) struct AbiPair { c_long value; void* pointer; }
private alias Callback = extern(C) c_long function(c_long) nothrow @nogc;
extern(C) AbiPair abi_pair(c_long, c_ulong, void*) nothrow @nogc;
extern(C) c_ulong abi_widths() nothrow @nogc;
extern(C) c_long abi_callback(Callback, c_long) nothrow @nogc;
extern(C) c_long twice(c_long n) nothrow @nogc { return n * 2; }
version (TlsSecond) private enum token = 202; else private enum token = 101;
align(64) int initialized = 41;
int zero;
int[2049] zeroArea;
shared static this() { assert(sharedOrder == 1); sharedOrder = 2; }
static this()
{
    assert(sharedOrder == 2 && threadOrder == 1 && initialized == 41 && zero == 0);
    foreach (value; zeroArea) assert(value == 0);
    threadOrder = 2;
    initialized = token;
    zero = token + 1;
    errno = token;
}
void main()
{
    auto range = mainTlsRange();
    assert(cast(void*)&initialized >= range.ptr && cast(void*)&initialized < range.ptr + range.length);
    assert(cast(void*)&zeroArea >= range.ptr && cast(void*)(&zeroArea + 1) <= range.ptr + range.length);
    assert(cast(size_t)&initialized % 64 == 0);
    assert(abi_widths() == (c_long.sizeof | ((void*).sizeof << 8) | (wchar_t.sizeof << 16)));
    auto pair = abi_pair(-0x123456789L, 0xabcdefUL, &zero);
    assert(pair.value == (-0x123456789L ^ 0xabcdefL) && pair.pointer == &zero);
    assert(abi_callback(&twice, 0x123456789L) == 0x2468acf12L + 5);
    auto memory = cast(ubyte*) calloc(32, 1);
    assert(memory !is null);
    foreach (i; 0 .. 32) { assert(memory[i] == 0); memory[i] = cast(ubyte)i; }
    memory = cast(ubyte*) realloc(memory, 128);
    assert(memory !is null);
    foreach (i; 0 .. 32) assert(memory[i] == i);
    free(memory);
    call(Call.sleep, 200); // Allow the other ELF to enter main before the CPU-bound phase.
    foreach (i; 0 .. 4)
    {
        foreach (_; 0 .. 10_000_000)
        {
            assert(volatileLoad(cast(uint*)&initialized) == token);
            volatileStore(cast(uint*)&zero, cast(uint)(token + 1));
        }
        call(Call.yield);
        assert(initialized == token && zero == token + 1 && errno == token);
    }
    call(Call.publish, token);
    call(Call.sleep, 500); // Let the host observe both processes' preemption counts before they exit.
    send(Call.write, "Standard druntime C ABI and main TLS passed.\n");
}
static ~this()
{
    assert(initialized == token && zero == token + 1 && threadOrder == 2);
    threadOrder = 3;
    send(Call.write, "TLS destructor passed.\n");
}
shared static ~this()
{
    assert(sharedOrder == 2); sharedOrder = 3;
    send(Call.write, "Shared destructor passed.\n");
}
