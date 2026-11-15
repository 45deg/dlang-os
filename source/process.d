/// spawnElfでELFとヒープを配置し、runNextでRing 3プロセスをラウンドロビン実行する。
module process;

import address_space : AddressSpace, initPaging, initUserSpace, releaseUserSpace, mapBuiltin, mapUserHeap, resizeHeap, copyFromUser,
    userCodeAddress, userImageEnd, userStackBase, userStackTop, __user_app_start;
import apic_timer : initTimer, arm, cancel;
import cpu : readCr3;
import physical_memory : initPhysicalMemory;
import clock : milliseconds;
import privilege : UserFrame, enterUser, initPrivilege, syscallVector, timerVector, userCode, userData;
import elf : loadElf;
import filesystem : maxNameBytes;
import gui : guiCall;
import gui_abi : maxProcesses;
import serial : writeByte, writeText;
import user_abi : Call, callError, titleLimit, writeLimit;
import user_program : Program, programName, userMain;

enum processLimit = maxProcesses;
enum ElfStart { ok, unavailable, invalid }
private enum ulong userStatusFlags = 0xcd5; // OF, DF, SF, ZF, AF, PF, CF
private enum ulong userInterruptsEnabled = 0x202;

struct ProcessInfo
{
    uint pid;
    Program program;
    ulong value;
    ulong slices;
    ulong preemptions;
    char[maxNameBytes] filename = void;
    size_t filenameLength;
}

private struct Process
{
    ProcessInfo info;
    UserFrame frame;
    char[titleLimit] title;
    size_t titleLength;
    bool windowPending;
    ulong closeDeadline;
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
    initPaging();
    initPhysicalMemory();
    initPrivilege();
    if (!initTimer())
        return false;
    kernelCr3 = readCr3();
    available = true;
    return true;
}

uint spawn(Program program)
{
    const slot = freeSlot();
    if (slot == processLimit)
        return 0;

    bool started;
    scope(exit) if (!started) releaseUserSpace(spaces[slot]);
    if (!initUserSpace(spaces[slot]))
        return 0;
    if (!mapBuiltin(spaces[slot]))
        return 0;

    const entry = userCodeAddress + (cast(ulong) &userMain - cast(ulong) &__user_app_start);
    started = true;
    auto task = activate(slot, program, entry);
    task.frame.rdi = cast(ulong) program;
    task.frame.rsi = task.info.pid;
    return task.info.pid;
}

ElfStart spawnElf(scope const(char)[] name, scope const(char)[] image, out uint pid)
{
    const slot = freeSlot();
    if (slot == processLimit)
        return ElfStart.unavailable;
    bool started;
    scope(exit) if (!started) releaseUserSpace(spaces[slot]);
    if (!initUserSpace(spaces[slot]))
        return ElfStart.unavailable;
    ulong entry;
    if (!loadElf(spaces[slot], image, entry))
        return ElfStart.invalid;
    if (!mapUserHeap(spaces[slot]))
        return ElfStart.unavailable;

    started = true;
    auto task = activate(slot, Program.elf, entry);
    foreach (i, char c; name)
        task.info.filename[i] = c;
    task.info.filenameLength = name.length;
    pid = task.info.pid;
    return ElfStart.ok;
}

const(char)[] processName(return scope ref const ProcessInfo info)
{
    return info.program == Program.elf
        ? info.filename[0 .. info.filenameLength]
        : programName(info.program);
}

private size_t freeSlot()
{
    if (available)
        foreach (slot, ref task; processes)
            if (task.info.pid == 0)
                return slot;
    return processLimit;
}

private Process* activate(size_t slot, Program program, ulong entry)
{
    auto task = &processes[slot];
    *task = Process.init;
    do
    {
        task.info.pid = nextPid++;
    }
    while (task.info.pid == 0 || pidExistsBeforeAssignment(slot, task.info.pid));

    task.info.program = program;
    task.frame.rip = entry;
    task.frame.rsp = userStackTop - 8;
    task.frame.cs = userCode;
    task.frame.ss = userData;
    task.frame.flags = userInterruptsEnabled;
    return task;
}

private bool pidExistsBeforeAssignment(size_t assignedSlot, uint pid)
{
    foreach (slot, ref task; processes)
        if (slot != assignedSlot && task.info.pid == pid)
            return true;
    return false;
}

private Process* find(uint pid)
{
    if (pid != 0)
        foreach (ref task; processes)
            if (task.info.pid == pid)
                return &task;
    return null;
}

bool stop(uint pid)
{
    auto task = find(pid);
    if (task is null)
        return false;
    releaseUserSpace(spaces[task - processes.ptr]);
    task.info.pid = 0;
    return true;
}

/// 保存確認が不要な窓に終了猶予を与える。繰り返し通知しても期限は延長しない。
void requestClose(uint pid)
{
    auto task = find(pid);
    if (task !is null && task.closeDeadline == 0)
        task.closeDeadline = milliseconds() + 1000;
}

bool infoFor(uint pid, out ProcessInfo info)
{
    const task = find(pid);
    if (task is null)
        return false;
    info = task.info;
    return true;
}

uint takeWindowRequest(size_t slot)
{
    auto task = &processes[slot];
    if (task.info.pid == 0 || !task.windowPending)
        return 0;
    task.windowPending = false;
    return task.info.pid;
}

const(char)[] windowTitleFor(uint pid)
{
    const task = find(pid);
    return task is null ? null : task.title[0 .. task.titleLength];
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

        if (task.closeDeadline != 0 && milliseconds() >= task.closeDeadline)
        {
            releaseUserSpace(spaces[slot]);
            task.info.pid = 0;
            continue;
        }
        ++task.info.slices;
        arm();
        enterUser(&task.frame, spaces[slot].cr3, kernelCr3);
        const timerFired = task.frame.vector == timerVector;
        cancel(timerFired);
        if (!validResume(task.frame))
        {
            ++faultedCount;
            task.info.pid = 0;
        }
        else if (timerFired)
            ++task.info.preemptions;
        else if (task.frame.vector == syscallVector)
            handleCall(*task, spaces[slot]);
        else
        {
            ++faultedCount;
            task.info.pid = 0;
        }
        if (task.info.pid == 0)
            releaseUserSpace(spaces[slot]);
        return;
    }
}

private bool validResume(ref UserFrame frame)
{
    // ユーザーが変更できる状態を、次のIRETへ渡す前にABIの範囲へ戻す。
    frame.flags = (frame.flags & userStatusFlags) | userInterruptsEnabled;
    frame.cs = userCode;
    frame.ss = userData;
    return frame.rip >= userCodeAddress && frame.rip < userImageEnd
        && frame.rsp >= userStackBase && frame.rsp <= userStackTop;
}

private void handleCall(ref Process task, ref AddressSpace space)
{
    switch (cast(Call) task.frame.rax)
    {
        case Call.heapResize:
            task.frame.rax = resizeHeap(space, task.frame.rdi);
            break;
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
        case Call.write:
            task.frame.rax = userWrite(space, task.frame.rdi, task.frame.rsi);
            break;
        case Call.guiCreate:
            task.frame.rax = openWindow(task, space);
            break;
        case Call.guiPoll, Call.guiPresent, Call.guiDirectory, Call.guiReadFile, Call.guiSaveFile,
            Call.guiOpenDocument, Call.guiMonitor:
            task.frame.rax = guiCall(task.info.pid, cast(Call) task.frame.rax, space, task.frame.rdi, task.frame.rsi);
            break;
        default:
            task.frame.rax = callError;
            break;
    }
}

private ulong userWrite(ref const AddressSpace space, ulong address, ulong length)
{
    char[writeLimit] buffer = void;
    if (length > buffer.length || !readText(space, address, buffer[0 .. length], true))
        return callError;

    foreach (char c; buffer[0 .. length])
    {
        if (c == '\n')
            writeText("\r\n");
        else
            writeByte(c);
    }
    return length;
}

private ulong openWindow(ref Process task, ref const AddressSpace space)
{
    const length = task.frame.rsi;
    char[titleLimit] title = void;
    if (task.titleLength || length == 0 || length > title.length
        || !readText(space, task.frame.rdi, title[0 .. length], false))
        return callError;

    foreach (i; 0 .. length)
        task.title[i] = title[i];
    task.titleLength = length;
    task.windowPending = true;
    return 0;
}

private bool readText(ref const AddressSpace space, ulong address, scope char[] text, bool allowNewline)
{
    if (text.length && !copyFromUser(space, address, text))
        return false;
    foreach (char c; text)
        if ((c < ' ' || c > '~') && !(allowNewline && c == '\n'))
            return false;
    return true;
}
