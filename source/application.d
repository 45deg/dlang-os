/// DlangFS上のELFを読み込み、独立したユーザープロセスとして起動する。
module application;

import desktop_theme : App;
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
    final switch (app)
    {
        case App.files: return launchFile("files.elf", pid);
        case App.editor: return launchFile("editor.elf", pid);
        case App.calc: return launchFile("calc.elf", pid);
        case App.game: return launchFile("game.elf", pid);
        case App.monitor: return launchFile("monitor.elf", pid);
        case App.counter: return launchFile("counter.elf", pid);
    }
}
