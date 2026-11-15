/// DlangFS上のELFを読み込み、独立したユーザープロセスとして起動する。
module application;

import app_registry : App, registration;
import filesystem : FsResult, FileVersion, errorText, open;
import process : ElfStart, spawnElf;

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

const(char)[] launchDesktopApp(App app, out uint pid) nothrow @nogc
{
    return launchFile(registration(app).executable, pid);
}
