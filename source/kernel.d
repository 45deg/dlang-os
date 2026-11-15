/// UEFIローダーから起動情報を受け取り、ディスク、プロセス、GUIを初期化してシェルを開始する。
module kernel;

import boot_info : BootInfo, initBootInfo;
import cpu : pauseCpu;
import desktop : Desktop;
import filesystem : mount;
import process : initProcesses, runNext;
import serial : initSerial, writeText;
import shell : Shell;

// 最大16 KiBの文書を持つ各ウィンドウと転送領域を、ブートスタックの外に置く。
private __gshared Desktop desktop;
private __gshared Shell shell;

extern(C) noreturn kernelMain(BootInfo* info) nothrow @nogc
{
    initBootInfo(info);
    initSerial();

    writeText("Dlang OS (x86_64)\r\nType 'help' for commands.\r\n");
    if (!mount())
        writeText("Data disk unavailable.\r\n");

    if (!initProcesses())
        writeText("User processes unavailable.\r\n");

    if (!desktop.init())
        writeText("Framebuffer unavailable. Use the serial shell.\r\n");

    shell.start();
    while (true)
    {
        shell.poll();
        desktop.poll();
        runNext();
        pauseCpu();
    }
}
