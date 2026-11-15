/// 起動時の空きメモリとスケジューラの統計を、Monitorウィンドウの表に描く。
module monitor;

import desktop_theme : accent, accentLight, divider, ink, labelWithin, muted, paper, toolbar;
import font : textHeight, textWidth;
import graphics : Rect, Screen;
import boot_info : usableMemoryKiB;
import numbers : decimalText;
import process : exitedProcesses, faultedProcesses, infoAt, processLimit, processName;

void drawMonitor(ref Screen screen, Rect body) nothrow @nogc
{
    screen.fill(body, paper);
    screen.fill(Rect(body.x, body.y, body.width, 78), toolbar);

    size_t running;
    foreach (slot; 0 .. processLimit)
        if (infoAt(slot).pid != 0)
            ++running;

    const x = body.x + 14;
    screen.text(x, body.y + 13, "Usable RAM at boot", muted);
    screen.text(x + 170, body.y + 13, "User processes", muted);
    drawMetric(screen, x, body.y + 33, usableMemoryKiB() / 1024, 2);
    screen.text(x + 65, body.y + 40, "MiB", muted);
    drawMetric(screen, x + 170, body.y + 33, running, 2);
    screen.text(x + 193, body.y + 40, "/", muted);
    drawMetric(screen, x + 207, body.y + 40, processLimit, 1);
    foreach (slot; 0 .. processLimit)
        screen.fill(Rect(x + 170 + cast(int) slot * 13, body.y + 61, 10, 4),
            slot < running ? accent : divider);

    const heading = body.y + 88;
    screen.text(x, heading, "PID", muted);
    screen.text(x + 80, heading, "Program", muted);
    screen.text(x + 174, heading, "Slices", muted);
    screen.text(x + 274, heading, "Preemptions", muted);
    screen.fill(Rect(body.x + 8, heading + 16, body.width - 16, 1), divider);
    if (running == 0)
        screen.text(x, heading + 26, "No user processes running", muted);

    int row;
    foreach (slot; 0 .. processLimit)
    {
        const task = infoAt(slot);
        if (task.pid == 0)
            continue;
        const y = heading + 20 + row * 18;
        screen.fill(Rect(body.x + 8, y, body.width - 16, 18), row % 2 ? toolbar : accentLight);
        const textY = y + (18 - textHeight) / 2;
        tableNumber(screen, x, textY, 9, task.pid);
        labelWithin(screen, Rect(x + 80, textY, 88, textHeight), processName(task), ink);
        tableNumber(screen, x + 174, textY, 11, task.slices);
        tableNumber(screen, x + 274, textY, 13, task.preemptions);
        ++row;
    }

    const footer = body.y + body.height - 31;
    screen.fill(Rect(body.x, footer, body.width, 31), toolbar);
    screen.text(x, footer + 11, "Exited", muted);
    tableNumber(screen, x + 57, footer + 11, 11, exitedProcesses());
    screen.text(x + 158, footer + 11, "Faulted", muted);
    tableNumber(screen, x + 223, footer + 11, 17, faultedProcesses());
}

private void tableNumber(ref Screen screen, int x, int y, int characters, ulong value) nothrow @nogc
{
    char[20] digits = void;
    const text = decimalText(value, digits);
    labelWithin(screen, Rect(x, y, characters * textWidth, textHeight),
        text.length > characters ? ">max" : text, ink);
}

private void drawMetric(ref Screen screen, int x, int y, ulong value, int scale) nothrow @nogc
{
    char[20] digits = void;
    screen.text(x, y, decimalText(value, digits), ink, scale);
}
