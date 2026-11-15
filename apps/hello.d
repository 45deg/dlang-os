/// ELFのデータとゼロ初期化領域を使い、シリアルへ1行出して終了する例。
module hello;

import core.volatile : volatileLoad, volatileStore;
import user_abi : Call, callError;
import user_api : call, exitApp, send;

private __gshared uint initialized = 42;
private __gshared uint[1300] emptyPage;

extern(C) noreturn appMain() nothrow @nogc
{
    auto end = &emptyPage[$ - 1];
    if (call(Call.write, 0, 1) != callError)
        send(Call.write, "Invalid syscall pointer was accepted.\n");
    else if (volatileLoad(&initialized) != 42 || volatileLoad(end) != 0)
        send(Call.write, "ELF data initialization failed.\n");
    else
    {
        volatileStore(end, 1);
        send(Call.write, "Hello from a D ELF on disk!\n");
    }
    exitApp();
}
