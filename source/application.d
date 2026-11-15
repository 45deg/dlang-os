/// DlangFS上のELFを起動する。Counterの配布用コピーは、初回の起動操作でディスクに置く。
module application;

import filesystem : FsResult, FileVersion, errorText, maxFileBytes, open, save;
import process : ElfStart, spawnElf;

private enum counterName = "counter.elf";
private immutable string counterPackage = import("counter.elf");
static assert(counterPackage.length <= maxFileBytes);

const(char)[] launchFile(scope const(char)[] name, out uint pid) nothrow @nogc
{
    const(char)[] image;
    FileVersion stored;
    const result = open(name, image, stored);
    if (result != FsResult.ok)
        return errorText(result);
    final switch (spawnElf(name, image, pid))
    {
        case ElfStart.ok: return null;
        case ElfStart.unavailable: return "No user process slot is available.";
        case ElfStart.invalid: return "Unsupported or invalid ELF executable.";
    }
}

const(char)[] launchCounter(out uint pid) nothrow @nogc
{
    const(char)[] image;
    FileVersion stored;
    const found = open(counterName, image, stored);
    if (found == FsResult.notFound)
    {
        const empty = FileVersion.init;
        const installed = save(counterName, counterPackage, &empty);
        if (installed != FsResult.ok)
            return errorText(installed);
    }
    else if (found != FsResult.ok)
        return errorText(found);

    return launchFile(counterName, pid);
}
