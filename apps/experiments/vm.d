/// Verify BSS beyond the old 32 KiB limit, heap growth and shrinkage, and rollback on allocation failure.
module vm;

import core.volatile : volatileLoad, volatileStore;
import user_abi : Call, callError, userHeapBase, userHeapInitialBytes, userHeapLimitBytes;
import user_api : call, exitApp, send;

private __gshared ubyte[96 * 1024] largeBss;

extern(C) noreturn appMain() nothrow @nogc
{
    foreach (i; 0 .. largeBss.length / 4096)
    {
        check(volatileLoad(&largeBss[i * 4096]) == 0);
        volatileStore(&largeBss[i * 4096], cast(ubyte) (i + 1));
    }
    // Read and write a local buffer too large for the old one-page stack.
    ubyte[8192] stack = void;
    foreach (i; 0 .. stack.length)
        volatileStore(&stack[i], cast(ubyte) i);
    foreach (i; 0 .. stack.length)
        check(volatileLoad(&stack[i]) == cast(ubyte) i);

    auto heap = cast(ubyte*) userHeapBase;
    volatileStore(heap, 42);
    const expanded = 3 * 1024 * 1024;
    check(call(Call.heapResize, expanded) == expanded);
    foreach (i; userHeapInitialBytes / 4096 .. expanded / 4096)
    {
        check(volatileLoad(heap + i * 4096) == 0);
        volatileStore(heap + i * 4096, 99);
    }
    check(call(Call.heapResize, ulong.max) == callError);
    // The test guest has less than 1.5 GiB of RAM. The original contents must survive a partial allocation.
    check(call(Call.heapResize, userHeapLimitBytes) == callError);
    check(volatileLoad(heap) == 42 && volatileLoad(heap + expanded - 4096) == 99);
    check(call(Call.heapResize, userHeapInitialBytes) == userHeapInitialBytes);
    check(call(Call.write, userHeapBase + expanded - 4096, 1) == callError);
    check(call(Call.heapResize, expanded) == expanded);
    check(volatileLoad(heap + expanded - 4096) == 0);
    check(call(Call.heapResize, 0) == 0);
    check(call(Call.write, userHeapBase, 1) == callError);
    check(call(Call.heapResize, 1) == 4096);
    check(volatileLoad(heap) == 0);
    foreach (i; 0 .. largeBss.length / 4096)
        check(volatileLoad(&largeBss[i * 4096]) == cast(ubyte) (i + 1));
    send(Call.write, "VM: large BSS, stack, heap growth, shrink and OOM rollback passed.\n");
    exitApp();
}

private void check(bool condition) nothrow @nogc
{
    if (!condition)
    {
        send(Call.write, "VM test failed.\n");
        exitApp();
    }
}
