/// カーネルに同梱するD製ユーザープログラム。固定アドレスやカーネルの関数を参照しない。
module user_program;

import address_space : pageBytes, userCodeAddress;
import core.volatile : volatileLoad, volatileStore;
import ldc.attributes : section;
import ldc.llvmasm : __asm;
import user_abi : Call;

enum Program : ulong { counter, spin, exit, fault, elf }

/// 引数はプログラムの種類。再配置時に使う外部参照を作らない。
@section(".user_app")
extern(C) noreturn userMain(Program program, ulong pid) nothrow @nogc
{
    if (program == Program.exit)
        __asm!ulong("int $$0x80", "={rax},0,~{memory}", Call.exit);
    else if (program == Program.fault)
    {
        // 未使用の末尾への書き込みを試し、読み取り専用コードでページフォルトを起こす。
        volatileStore(cast(ubyte*) (userCodeAddress + pageBytes - 1), 0);
    }
    else if (program == Program.counter)
    {
        // ユーザースタックを経由して値を保持し、公開する。保存先はプロセスごとに独立。
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

    // 自分では一度もyieldしない。タイマーで実行を取り戻せることを確認できる。
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
