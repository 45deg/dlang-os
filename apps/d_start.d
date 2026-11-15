/// 通常のDアプリの起動処理。_d_run_mainでモジュールを登録し、共有コンストラクタの後にmainを呼ぶ。
module d_start;

import user_abi : Call;
import user_api : exitApp, send;

private alias InitFunction = extern(C) void function();
private alias MainFunction = extern(C) int function(char[][] args);

// x86_64-unknown-none-elf向けLDCは、各モジュールの登録ノードをこのリストの先頭に追加する。
private struct ModuleReference
{
    ModuleReference* next;
    ModuleInfo* info;
}

extern(C) __gshared ModuleReference* _Dmodule_ref;
extern(C) extern __gshared InitFunction __init_array_start, __init_array_end;

// 共有コンストラクタと依存モジュールの配列は、固定長ヘッダの後ろにある。
// この2つより前のオプションフィールドは、D ABIではすべてポインタ1個分。
private const(void)* moduleField(const(ModuleInfo)* info, uint field)
{
    auto fields = cast(const(void*)*)(info + 1);
    for (uint flag = MItlsctor; flag < field; flag <<= 1)
        if (info._flags & flag)
            ++fields;
    return fields;
}

private bool importsInitialized(const(ModuleInfo)* info)
{
    if (!(info._flags & MIimportedModules))
        return true;

    auto count = cast(const(size_t)*) moduleField(info, MIimportedModules);
    auto dependencies = cast(const(ModuleInfo*)*)(count + 1);
    foreach (dependency; dependencies[0 .. *count])
        if (dependency !is null && !(dependency._flags & MIctordone))
            return false;
    return true;
}

private void initializeModules()
{
    // LDCは単一オブジェクトではリストを事前に作れる。空の.init_arrayでは両端が同じアドレスになる。
    for (auto init = &__init_array_start; cast(size_t) init < cast(size_t) &__init_array_end; ++init)
        (*init)();

    size_t remaining;
    for (auto moduleRef = _Dmodule_ref; moduleRef !is null; moduleRef = moduleRef.next)
        ++remaining;

    // スタックは1ページ。再帰を使わず、依存先が初期化済みのモジュールから進める。
    while (remaining != 0)
    {
        const before = remaining;
        for (auto moduleRef = _Dmodule_ref; moduleRef !is null; moduleRef = moduleRef.next)
        {
            auto info = moduleRef.info;
            if ((info._flags & MIctordone) || !importsInitialized(info))
                continue;

            if (info._flags & MIctor)
            {
                auto ctor = *cast(const(void function())*) moduleField(info, MIctor);
                ctor();
            }
            info._flags |= MIctordone;
            --remaining;
        }
        if (remaining == before)
        {
            send(Call.write, "Cannot initialize D modules with circular imports.\n");
            exitApp();
        }
    }
}

// ELFの入口はLDCが生成するCのmain。OSは引数や終了コードの受け渡しを行わない。
extern(C) int _d_run_main(int argc, char** argv, MainFunction dMain)
{
    initializeModules();
    dMain(null);
    exitApp();
}
