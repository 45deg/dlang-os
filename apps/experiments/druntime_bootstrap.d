/// Exercise an out-of-line call into the pinned upstream druntime archive.
/// A 96 KiB initialized payload also checks large ELF loading beyond the old 16-bit file length.
module druntime_bootstrap;

import core.bitop : bsf;
import core.volatile : volatileLoad;
import user_abi : Call;
import user_api : send, exitApp;

// A mutable function pointer keeps this call out of line, even when bsf requests inlining.
private __gshared int function(uint) pure nothrow @nogc @safe scan = &bsf;
private immutable ubyte[96 * 1024] payload = makePayload();
private ubyte[96 * 1024] makePayload() pure nothrow @nogc
{
    ubyte[96 * 1024] result = void;
    foreach (i, ref value; result)
        value = cast(ubyte) (i % 251);
    return result;
}

extern(C) noreturn appMain() nothrow @nogc
{
    bool valid = scan(0x100) == 8 && scan(0x8000_0000) == 31;
    // Read every byte from the loaded image; prevent constant-folding the payload check.
    foreach (i; 0 .. payload.length)
        if (volatileLoad(cast(ubyte*) payload.ptr + i) != cast(ubyte) (i % 251))
            valid = false;
    send(Call.write, valid ? "Upstream druntime bootstrap and large ELF passed.\n"
                          : "Upstream druntime bootstrap failed.\n");
    exitApp();
}
