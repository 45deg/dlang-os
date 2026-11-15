/// 固定スロットのRing 3プロセスを管理し、runNextで1つずつラウンドロビン実行する。
module process;

import address_space : AddressSpace, initPaging, initUserSpace, resetUserStack,
    userCodeAddress, userStackTop, __user_app_start;
import apic_timer : initTimer, arm, cancel;
import cpu : readCr3;
import privilege : UserFrame, enterUser, initPrivilege, syscallVector, timerVector, userCode, userData;
import user_program : Call, Program, userMain;

enum processLimit = 8;

struct ProcessInfo
{
    uint pid;
    Program program;
    ulong value;
    ulong slices;
    ulong preemptions;
}

private struct Process
{
    ProcessInfo info;
    UserFrame frame;
}

private __gshared Process[processLimit] processes;
private __gshared AddressSpace[processLimit] spaces;
private __gshared bool available;
private __gshared uint nextPid = 1;
private __gshared size_t turn;
private __gshared ulong kernelCr3;
private __gshared ulong exitedCount, faultedCount;

nothrow @nogc:

bool initProcesses()
{
    if (!initPaging())
        return false;
    initPrivilege();
    if (!initTimer())
        return false;
    foreach (ref space; spaces)
        if (!initUserSpace(space))
            return false;
    kernelCr3 = readCr3();
    available = true;
    return true;
}

bool canSpawn()
{
    if (!available)
        return false;
    foreach (ref task; processes)
        if (task.info.pid == 0)
            return true;
    return false;
}

uint spawn(Program program)
{
    if (!available)
        return 0;
    foreach (slot, ref task; processes)
    {
        if (task.info.pid != 0)
            continue;

        resetUserStack(spaces[slot]);
        task = Process.init;
        do
        {
            task.info.pid = nextPid++;
        }
        while (task.info.pid == 0 || pidExistsBeforeAssignment(slot, task.info.pid));

        task.info.program = program;
        task.frame.rdi = cast(ulong) program;
        task.frame.rsi = task.info.pid;
        task.frame.rip = userCodeAddress + (cast(ulong) &userMain - cast(ulong) &__user_app_start);
        task.frame.rsp = userStackTop - 8; // System V ABIの関数入口に揃える
        task.frame.cs = userCode;
        task.frame.ss = userData;
        task.frame.flags = 0x202; // IF=1。I/O特権はRing 0のまま
        return task.info.pid;
    }
    return 0;
}

private bool pidExistsBeforeAssignment(size_t assignedSlot, uint pid)
{
    foreach (slot, ref task; processes)
        if (slot != assignedSlot && task.info.pid == pid)
            return true;
    return false;
}

bool stop(uint pid)
{
    if (pid == 0)
        return false;
    foreach (ref task; processes)
        if (task.info.pid == pid)
        {
            task.info.pid = 0;
            return true;
        }
    return false;
}

bool infoFor(uint pid, out ProcessInfo info)
{
    if (pid == 0)
        return false;
    foreach (ref task; processes)
        if (task.info.pid == pid)
        {
            info = task.info;
            return true;
        }
    return false;
}

ProcessInfo infoAt(size_t slot)
{
    return processes[slot].info;
}

ulong exitedProcesses() { return exitedCount; }
ulong faultedProcesses() { return faultedCount; }

void runNext()
{
    if (!available)
        return;

    foreach (_; 0 .. processLimit)
    {
        const slot = turn;
        turn = (turn + 1) % processLimit;
        auto task = &processes[slot];
        if (task.info.pid == 0)
            continue;

        ++task.info.slices;
        arm();
        enterUser(&task.frame, spaces[slot].cr3, kernelCr3);
        const timerFired = task.frame.vector == timerVector;
        cancel(timerFired);
        if (timerFired)
            ++task.info.preemptions;
        else if (task.frame.vector == syscallVector)
            handleCall(*task);
        else
        {
            ++faultedCount;
            task.info.pid = 0;
        }
        return;
    }
}

private void handleCall(ref Process task)
{
    switch (cast(Call) task.frame.rax)
    {
        case Call.yield:
            task.frame.rax = 0;
            break;
        case Call.publish:
            task.info.value = task.frame.rdi;
            task.frame.rax = 0;
            break;
        case Call.exit:
            ++exitedCount;
            task.info.pid = 0;
            break;
        default:
            task.frame.rax = ulong.max;
            break;
    }
}
