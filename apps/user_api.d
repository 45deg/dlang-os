/// 独立したDアプリからカーネルのINT 0x80を呼ぶ。
module user_api;

import ldc.llvmasm : __asm;
import user_abi : Call;

ulong call(Call number, ulong first = 0, ulong second = 0) nothrow @nogc
{
    return __asm!ulong("int $$0x80", "={rax},0,{rdi},{rsi},~{memory}",
        cast(ulong) number, first, second);
}

ulong send(Call number, scope const(char)[] text) nothrow @nogc
{
    return call(number, cast(ulong) text.ptr, text.length);
}

noreturn exitApp() nothrow @nogc
{
    call(Call.exit);
    while (true)
        call(Call.yield);
}
