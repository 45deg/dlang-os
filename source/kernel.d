/// Limineから起動し、ディスクをマウントしてからシェルとGUIの入出力を順に確認する。
module kernel;

import cpu : haltCpu, pauseCpu;
import desktop : Desktop;
import filesystem : mount;
import limine : supportsRequestedRevision;
import process : initProcesses, runNext;
import serial : initSerial, writeText;
import shell : Shell;

extern(C) noreturn kernelMain() nothrow @nogc
{
    initSerial();
    if (!supportsRequestedRevision())
    {
        writeText("Unsupported Limine base revision.\r\n");
        haltCpu();
    }

    writeText("Dlang OS (x86_64)\r\nType 'help' for commands.\r\n");
    if (!mount())
        writeText("Data disk unavailable.\r\n");

    if (!initProcesses())
        writeText("User processes unavailable.\r\n");

    Desktop desktop;
    if (!desktop.init())
        writeText("Framebuffer unavailable. Use the serial shell.\r\n");

    Shell shell;
    shell.start();
    while (true)
    {
        shell.poll();
        desktop.poll();
        runNext();
        pauseCpu();
    }
}
