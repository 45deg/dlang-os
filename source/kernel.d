/// Receive boot information from UEFI, initialize the disk, processes, and GUI, and start the shell.
module kernel;

import boot_info : BootInfo, initBootInfo;
import cpu : haltCpu;
import apic_timer : idle;
import clock : initClock;
import desktop : Desktop;
import filesystem : mount;
import process : initProcesses, runNext;
import serial : initSerial, writeText;
import shell : Shell;

// Keep window state, including documents up to 16 KiB, and transfer buffers off the boot stack.
private __gshared Desktop desktop;
private __gshared Shell shell;

extern(C) noreturn kernelMain(BootInfo* info) nothrow @nogc
{
    initBootInfo(info);
    initSerial();

    writeText("Dlang OS (x86_64)\r\nType 'help' for commands.\r\n");
    if (!initClock())
    {
        writeText("Clock calibration failed.\r\n");
        haltCpu();
    }
    if (!mount())
        writeText("Data disk unavailable.\r\n");

    if (!initProcesses())
        writeText("User processes unavailable.\r\n");

    if (!desktop.init())
        writeText("Framebuffer unavailable. Use the serial shell.\r\n");

    shell.start();
    while (true)
    {
        const serialProgress = shell.poll();
        desktop.poll();
        const ranProcess = runNext();
        if (!ranProcess && !serialProgress && !desktop.hasPendingInput())
            idle();
    }
}
