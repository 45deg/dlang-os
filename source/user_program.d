/// Built-in D user programs avoid references to fixed addresses or kernel functions.
module user_program;

import address_space : pageBytes, userCodeAddress;
import core.volatile : volatileLoad, volatileStore;
import ldc.attributes : section;
import ldc.llvmasm : __asm;
import user_abi : Call;

enum Program : ulong { counter, spin, exit, fault, elf }

/// The argument selects the program. Avoid external references so the code can be relocated.
@section(".user_app")
extern(C) noreturn userMain(Program program, ulong pid) nothrow @nogc
{
    if (program == Program.exit)
        __asm!ulong("int $$0x80", "={rax},0,~{memory}", Call.exit);
    else if (program == Program.fault)
    {
        // Try writing to the unused tail of read-only code to trigger a page fault.
        volatileStore(cast(ubyte*) (userCodeAddress + pageBytes - 1), 0);
    }
    else if (program == Program.counter)
    {
        // Store and publish the value through the user stack, which is private to each process.
        ulong count = 0;
        ulong stackOwner = void;
        volatileStore(&stackOwner, pid);
        while (true)
        {
            if (volatileLoad(&stackOwner) != pid)
                __asm("ud2", "~{memory}");
            __asm("incq ($0)", "r,~{flags},~{memory}", &count);
            __asm!ulong("int $$0x80", "={rax},0,{rdi},~{memory}", Call.publish, count);
        }
    }

    // Never yield explicitly, so the test can check that the timer preempts this program.
    while (true)
        __asm("pause", "~{memory}");
}

const(char)[] programName(Program program) pure nothrow @nogc
{
    final switch (program)
    {
        case Program.counter: return "counter";
        case Program.spin: return "spin";
        case Program.exit: return "exit";
        case Program.fault: return "fault";
        case Program.elf: return "elf";
    }
}
