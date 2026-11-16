/// Verify that a sleeping process stops running, resumes at its deadline, and can be killed during a long wait.
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
