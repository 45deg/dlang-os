/// sleep中は実行されず、期限後に再開し、長い待機中でもkillできることを試す。
module sleep_example;

import user_abi : Call;
import user_api : call;

extern(C) noreturn appMain() nothrow @nogc
{
    call(Call.publish, 1);
    call(Call.sleep, 1000);
    call(Call.publish, 2);
    call(Call.sleep, ulong.max);
    while (true) call(Call.yield);
}
