/// Run ELF registration functions, then enter the upstream _d_run_main lifecycle with no arguments.
module dlangos.entry;
import dlangos.cabi : exit;
private alias Init = extern(C) void function();
extern(C) extern __gshared Init __init_array_start, __init_array_end;
extern(C) int _Dmain(char[][]);
private alias Main = extern(C) int function(char[][]);
extern(C) int _d_run_main(int, char**, Main);
extern(C) noreturn appMain()
{
    for (auto p = &__init_array_start; p < &__init_array_end; ++p) (*p)();
    exit(_d_run_main(0, null, &_Dmain));
    assert(0);
}
