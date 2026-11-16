/// Manage the desktop and window stacking order. Redraw and present the affected regions in response to input.
/// launch starts apps, and syncAppWindows handles exits and file-open requests.
module desktop;

import calendar : DateTime, format;
import clock : currentDateTime, milliseconds;

import application : launchDesktopApp;
import app_registry : registration, documentApp, externalApp;
import app_catalog : loadCatalog;
import desktop_theme : App, accent, accentLight, appName, apps, appsButton, button, centeredText,
    divider, drawShortcut, drawWallpaper, ink, labelWithin, menuBounds, menuItem, muted, paper,
    shortcut, taskbarHeight, titleHeight, toolbar, warning;
import filesystem : FsResult, FileVersion, errorText, isText, open;
import graphics : Rect, Screen, maximum, minimum;
import gui : attachGui, detachGui, drawGui, guiDirty, guiTitle, sendGuiEvent, setGuiFocus, takeDocumentRequest,
    takeGuiChange;
import gui_abi : DirectoryEntry, GuiEvent, maxGuiWindows;
import process : ProcessInfo, infoFor, processLimit, takeWindowRequest, stop, requestClose, windowTitleFor;
import ps2 : InputKind, Key, MouseEvent, Ps2;

private enum windowLimit = maxGuiWindows;
private enum noWindow = windowLimit;

private struct Window
{
    Rect bounds;
    App app;
    uint pid;
    DirectoryEntry pendingDocument;
    bool minimized;
    bool open;
}

struct Desktop
{
    private Screen screen;
    private Ps2 devices;
    private Pointer pointer;
    private bool active;
    private ulong clockSecond;
    private bool menuOpen;
    private size_t menuSelection;
    private const(char)[] notice;

    // Window slots stay fixed until close. Move a slot to the end of order to bring its window to the front.
    private Window[windowLimit] windows;
    private size_t[windowLimit] order;
    private size_t windowCount;
    private size_t focused = noWindow;
    private size_t dragged = noWindow;
    private bool draggingContent;
    private int grabX, grabY;

    nothrow @nogc:

    bool init()
    {
        if (!screen.init())
            return false;
        notice = loadCatalog();
        pointer.x = screen.width / 2;
        pointer.y = screen.height / 2;
        active = true;
        if (!devices.init())
            notice = "PS/2 unavailable. Use the serial shell.";
        redraw(fullScreen());
        return true;
    }

    bool hasPendingInput() const
    {
        return active && devices.hasPendingInput();
    }

    void poll()
    {
        if (!active)
            return;

        const event = devices.poll();
        const second = milliseconds() / 1000;
        const clockChanged = second != clockSecond;
        clockSecond = second;
        const windowsChanged = syncAppWindows() || clockChanged;

        if (event.kind == InputKind.keyboard)
        {
            handleKey(event.key);
            redraw(fullScreen());
        }
        else if (event.kind == InputKind.mouse)
        {
            const oldCursor = pointer.bounds();
            Rect movedWindow;
            const changed = handleMouse(event.mouse, movedWindow);
            const cursorDamage = oldCursor.covering(pointer.bounds());
            if (windowsChanged || (changed && movedWindow.width == 0))
                redraw(fullScreen());
            else if (movedWindow.width != 0)
                redraw(movedWindow.covering(cursorDamage));
            else if (event.mouse.dx || event.mouse.dy)
                present(cursorDamage);
        }
        else if (windowsChanged)
            redraw(fullScreen());
        foreach (slot; order[0 .. windowCount])
            setGuiFocus(windows[slot].pid, focused == slot && !menuOpen && !windows[slot].minimized);
    }

    private Rect fullScreen() const
    {
        return Rect(0, 0, screen.width, screen.height);
    }

    private void present(Rect damage)
    {
        // Composite the pointer only during presentation so the desktop buffer can be reused.
        pointer.draw(screen);
        screen.present(damage);
        pointer.erase(screen);
    }

    private void handleKey(Key key)
    {
        dragged = noWindow;
        if (key == Key.appsMenu)
        {
            toggleMenu();
            return;
        }
        if (menuOpen)
        {
            switch (key)
            {
                case Key.escape: menuOpen = false; break;
                case Key.up:
                    menuSelection = (menuSelection + apps.length - 1) % apps.length;
                    break;
                case Key.down:
                    menuSelection = (menuSelection + 1) % apps.length;
                    break;
                case Key.enter:
                    menuOpen = false;
                    launch(apps[menuSelection]);
                    break;
                default: break;
            }
            return;
        }
        notice = null;

        foreach (app; apps)
            if (registration(app).launchKey != Key.init && registration(app).launchKey == key)
            {
                launch(app);
                return;
            }
        switch (key)
        {
            case Key.cycleWindow: cycleWindows(); return;
            case Key.closeWindow:
                if (focused != noWindow)
                    close(focused);
                return;
            default: break;
        }

        if (key == Key.newFile && (focused == noWindow || !registration(windows[focused].app).documents))
            if (launch(documentApp()) == noWindow)
                return;
        if (focused == noWindow)
            return;

        const window = &windows[focused];
        sendGuiEvent(window.pid, GuiEvent.key, cast(ushort) key);
    }

    private void toggleMenu()
    {
        menuOpen = !menuOpen;
        if (menuOpen)
            menuSelection = 0;
    }

    private bool handleMouse(MouseEvent event, out Rect movedWindow)
    {
        pointer.x = maximum(0, minimum(screen.width - 1, pointer.x + event.dx));
        pointer.y = maximum(0, minimum(screen.height - 1, pointer.y + event.dy));
        const pressed = event.leftDown && !pointer.leftDown;
        pointer.leftDown = event.leftDown;
        if (dragged != noWindow)
        {
            if (draggingContent)
            {
                const body = bodyOf(windows[dragged].bounds);
                sendGuiEvent(windows[dragged].pid, event.leftDown ? GuiEvent.drag : GuiEvent.release,
                    0, pointer.x - body.x, pointer.y - body.y);
                if (!event.leftDown)
                    dragged = noWindow;
                return false;
            }
            if (!event.leftDown)
            {
                dragged = noWindow;
                return false;
            }
            auto bounds = &windows[dragged].bounds;
            const x = maximum(0, minimum(screen.width - bounds.width, pointer.x - grabX));
            const y = maximum(0, minimum(screen.height - taskbarHeight - bounds.height, pointer.y - grabY));
            if (x == bounds.x && y == bounds.y)
                return false;
            const previous = withShadow(*bounds);
            bounds.x = x;
            bounds.y = y;
            movedWindow = previous.covering(withShadow(*bounds));
            return true;
        }
        if (!pressed)
            return false;
        notice = null;

        if (appsButton(screen.height).contains(pointer.x, pointer.y))
        {
            toggleMenu();
            return true;
        }
        if (menuOpen)
        {
            menuOpen = false;
            foreach (app; apps)
                if (menuItem(screen.height, app).contains(pointer.x, pointer.y))
                {
                    launch(app);
                    return true;
                }
        }
        if (pointer.y >= screen.height - taskbarHeight)
        {
            int buttonIndex;
            foreach (slot, ref window; windows)
            {
                if (!window.open)
                    continue;
                if (taskButton(buttonIndex++).contains(pointer.x, pointer.y))
                {
                    if (focused == slot)
                        minimize(slot);
                    else
                        bringForward(slot);
                    break;
                }
            }
            return true;
        }

        for (size_t i = windowCount; i > 0; --i)
        {
            const slot = order[i - 1];
            const window = windows[slot];
            if (window.minimized || !window.bounds.contains(pointer.x, pointer.y))
                continue;
            if (closeButton(window.bounds).contains(pointer.x, pointer.y))
                close(slot);
            else if (minimizeButton(window.bounds).contains(pointer.x, pointer.y))
                minimize(slot);
            else
            {
                bringForward(slot);
                if (pointer.y < window.bounds.y + titleHeight)
                {
                    dragged = slot;
                    draggingContent = false;
                    grabX = pointer.x - window.bounds.x;
                    grabY = pointer.y - window.bounds.y;
                }
                else
                {
                    const body = bodyOf(window.bounds);
                    sendGuiEvent(window.pid, GuiEvent.click, 0, pointer.x - body.x, pointer.y - body.y);
                    dragged = slot;
                    draggingContent = true;
                }
            }
            return true;
        }
        foreach (app; apps)
            if (shortcut(app).contains(pointer.x, pointer.y))
            {
                launch(app);
                return true;
            }

        focused = noWindow;
        return true;
    }

    private size_t launch(App app)
    {
        size_t slot = noWindow;
        uint instanceCount;
        const policy = registration(app);
        if (app == externalApp)
        {
            notice = "No document application is registered.";
            return noWindow;
        }
        foreach (i, ref window; windows)
        {
            if (!window.open && slot == noWindow)
                slot = i;
            if (window.open && window.app == app)
            {
                if (policy.instances == 1)
                {
                    bringForward(i);
                    return i;
                }
                ++instanceCount;
            }
        }
        if (slot == noWindow || (policy.instances != 0 && instanceCount >= policy.instances))
        {
            notice = "Close a window before opening another.";
            return noWindow;
        }

        uint pid;
        notice = launchDesktopApp(app, pid);
        if (pid == 0)
            return noWindow;

        attachWindow(slot, app, pid);
        attachGui(pid, bodyOf(windows[slot].bounds));
        return slot;
    }

    private void attachWindow(size_t slot, App app, uint pid)
    {
        windows[slot] = Window.init;
        windows[slot].bounds = initialBounds(app);
        windows[slot].app = app;
        windows[slot].pid = pid;
        windows[slot].open = true;
        order[windowCount++] = slot;
        focused = slot;
    }

    private Rect initialBounds(App app) const
    {
        const offset = cast(int) (windowCount % 4);
        const policy = registration(app);
        const width = policy.bounds.width, height = policy.bounds.height;
        const x = policy.bounds.x + (policy.fromRight ? screen.width : 0) + offset * policy.cascadeX;
        const y = policy.bounds.y + offset * policy.cascadeY;
        return Rect(maximum(12, minimum(x, screen.width - width - 12)),
            maximum(12, minimum(y, screen.height - taskbarHeight - height - 12)), width, height);
    }

    private void bringForward(size_t slot)
    {
        size_t index;
        while (order[index] != slot)
            ++index;
        foreach (i; index .. windowCount - 1)
            order[i] = order[i + 1];
        order[windowCount - 1] = slot;
        windows[slot].minimized = false;
        focused = slot;
    }

    private void focusTop()
    {
        focused = noWindow;
        for (size_t i = windowCount; i > 0; --i)
            if (!windows[order[i - 1]].minimized)
            {
                focused = order[i - 1];
                return;
            }
    }

    private void cycleWindows()
    {
        foreach (slot; order[0 .. windowCount])
            if (!windows[slot].minimized)
            {
                bringForward(slot);
                return;
            }
    }

    private void minimize(size_t slot)
    {
        windows[slot].minimized = true;
        if (dragged == slot)
            dragged = noWindow;
        if (focused == slot)
            focusTop();
    }

    private void close(size_t slot)
    {
        const window = &windows[slot];
        if (guiDirty(window.pid))
            bringForward(slot);
        if (!guiDirty(window.pid))
            requestClose(window.pid);
        sendGuiEvent(window.pid, GuiEvent.close);
    }

    private void remove(size_t slot)
    {
        size_t position;
        while (order[position] != slot)
            ++position;
        --windowCount;
        foreach (i; position .. windowCount)
            order[i] = order[i + 1];
        windows[slot].open = false;
        if (dragged == slot)
            dragged = noWindow;
        if (focused == slot)
            focusTop();
    }

    private bool syncAppWindows()
    {
        bool changed;
        foreach (slot, ref window; windows)
        {
            if (!window.open)
                continue;
            ProcessInfo process;
            const alive = infoFor(window.pid, process);
            if (!alive)
            {
                detachGui(window.pid);
                remove(slot);
                changed = true;
                continue;
            }
            DirectoryEntry request;
            if (takeDocumentRequest(window.pid, request))
            {
                openFile(request.name[0 .. request.length]);
                changed = true;
            }
            if (takeGuiChange(window.pid))
            {
                window.pendingDocument.length = 0;
                changed = changed || !window.minimized;
            }
        }
        foreach (processSlot; 0 .. processLimit)
        {
            const pid = takeWindowRequest(processSlot);
            if (pid == 0)
                continue;
            size_t slot;
            while (slot < windowLimit && windows[slot].open)
                ++slot;
            if (slot == windowLimit)
            {
                notice = "Close a window before opening another.";
                stop(pid);
            }
            else
            {
                attachWindow(slot, externalApp, pid);
                attachGui(pid, bodyOf(windows[slot].bounds));
            }
            changed = true;
        }
        return changed;
    }

    private Rect withShadow(Rect bounds)
    {
        return Rect(bounds.x, bounds.y, bounds.width + 4, bounds.height + 5);
    }

    private void openFile(scope const(char)[] name)
    {
        if (name.length == 0)
            return;
        const(char)[] contents;
        FileVersion storedVersion;
        const result = open(name, contents, storedVersion);
        if (result != FsResult.ok)
        {
            notice = errorText(result);
            return;
        }

        if (!isText(contents))
        {
            notice = "Binary file. Use get NAME in the serial shell.";
            return;
        }

        foreach (slot, ref window; windows)
        {
            if (!window.open || !registration(window.app).documents)
                continue;
            const pending = window.pendingDocument.name[0 .. window.pendingDocument.length];
            if (pending == name || guiTitle(window.pid) == name)
            {
                sendGuiEvent(window.pid, GuiEvent.openDocument, 0, 0, 0, name);
                bringForward(slot);
                return;
            }
        }

        const slot = launch(documentApp());
        if (slot != noWindow)
        {
            auto window = &windows[slot];
            window.pendingDocument.length = cast(ubyte) name.length;
            foreach (i, char c; name)
                window.pendingDocument.name[i] = c;
            sendGuiEvent(window.pid, GuiEvent.openDocument, 0, 0, 0, name);
        }
    }

    private Rect taskButton(int index) const
    {
        const spacing = minimum(100, (screen.width - 230) / windowLimit);
        return Rect(78 + index * spacing, screen.height - taskbarHeight + 6, spacing - 4, 24);
    }

    private Rect bodyOf(Rect bounds)
    {
        return Rect(bounds.x + 1, bounds.y + titleHeight, bounds.width - 2, bounds.height - titleHeight - 1);
    }

    private Rect closeButton(Rect bounds)
    {
        return Rect(bounds.x + bounds.width - 26, bounds.y, 26, titleHeight);
    }

    private Rect minimizeButton(Rect bounds)
    {
        return Rect(bounds.x + bounds.width - 52, bounds.y, 26, titleHeight);
    }

    private void redraw(Rect damage)
    {
        drawWallpaper(screen);
        foreach (app; apps)
            drawShortcut(screen, app);
        foreach (slot; order[0 .. windowCount])
            if (!windows[slot].minimized)
                drawWindow(slot);
        drawTaskbar();
        if (notice.length)
        {
            const rect = Rect(8, screen.height - taskbarHeight - 27, screen.width - 16, 22);
            screen.fill(rect, ink);
            labelWithin(screen, Rect(rect.x + 8, rect.y, rect.width - 16, rect.height), notice, paper);
        }
        if (menuOpen)
            drawMenu();
        present(damage);
    }

    private const(char)[] windowTitle(size_t slot)
    {
        const title = guiTitle(windows[slot].pid);
        if (title.length) return title;
        const requested = windowTitleFor(windows[slot].pid);
        return requested.length ? requested : appName(windows[slot].app);
    }

    private void drawTaskbar()
    {
        const top = screen.height - taskbarHeight;
        screen.fill(Rect(0, top, screen.width, taskbarHeight), ink);
        screen.fill(Rect(0, top, screen.width, 1), 0x576d80);
        button(screen, appsButton(screen.height), "Apps");
        int index;
        foreach (slot, ref window; windows)
        {
            if (!window.open)
                continue;
            const rect = taskButton(index++);
            screen.fill(rect, focused == slot ? accent : window.minimized ? 0x2b4359 : muted);
            screen.fill(Rect(rect.x, rect.y + rect.height - 2, rect.width, 2),
                window.minimized ? muted : 0xa6d6d0);
            centeredText(screen, rect, windowTitle(slot), paper);
        }
        DateTime time;
        if (currentDateTime(time))
        {
            char[10] date;
            char[8] clock;
            format(time, date, clock);
            screen.text(screen.width - 140, top + 3, date[], paper);
            screen.text(screen.width - 140, top + 19, clock[], paper);
        }
        else
            labelWithin(screen, Rect(screen.width - 140, top, 140, taskbarHeight), "RTC unavailable", paper);
    }

    private void drawMenu()
    {
        const rect = menuBounds(screen.height);
        screen.fill(Rect(rect.x + 3, rect.y + 3, rect.width, rect.height), ink);
        screen.fill(rect, paper);
        foreach (index, app; apps)
        {
            const item = menuItem(screen.height, app);
            screen.fill(item, index == menuSelection ? accentLight : toolbar);
            labelWithin(screen, Rect(item.x + 10, item.y, item.width - 20, item.height),
                appName(app), ink);
            labelWithin(screen, Rect(item.x + item.width - 28, item.y, 24, item.height),
                registration(app).keyLabel, muted);
        }
    }

    private void drawWindow(size_t slot)
    {
        const window = windows[slot];
        const bounds = window.bounds;
        const activeWindow = focused == slot;
        screen.fill(Rect(bounds.x + 4, bounds.y + 5, bounds.width, bounds.height), 0x18303f);
        screen.fill(bounds, activeWindow ? accent : muted);
        labelWithin(screen, Rect(bounds.x + 10, bounds.y, bounds.width - 67, titleHeight),
            windowTitle(slot), paper);
        if (guiDirty(window.pid))
            centeredText(screen, Rect(bounds.x + bounds.width - 67, bounds.y, 14, titleHeight), "*", paper);

        const minimizeRect = minimizeButton(bounds);
        screen.fill(minimizeRect, muted);
        centeredText(screen, minimizeRect, "-", paper);
        const closeRect = closeButton(bounds);
        screen.fill(closeRect, warning);
        centeredText(screen, closeRect, "x", paper);
        const body = bodyOf(bounds);
        screen.fill(body, paper);
        drawGui(window.pid, screen, body);
    }

}

private struct Pointer
{
    int x;
    int y;
    bool leftDown;

    private enum shape = [
        "#           ",
        "##          ",
        "#o#         ",
        "#oo#        ",
        "#ooo#       ",
        "#oooo#      ",
        "#ooooo#     ",
        "#oooooo#    ",
        "#ooooooo#   ",
        "#oooo####   ",
        "#oo#o#      ",
        "#o# #o#     ",
        "##  #o#     ",
        "#    #o#    ",
        "     #o#    ",
        "      ##    ",
    ];
    private uint[shape[0].length * shape.length] under;

    Rect bounds() const nothrow @nogc
    {
        return Rect(x, y, cast(int) shape[0].length, cast(int) shape.length);
    }

    void erase(ref Screen screen) nothrow @nogc
    {
        foreach (row, mask; shape)
            foreach (column, c; mask)
            {
                const px = x + cast(int) column;
                const py = y + cast(int) row;
                if (c != ' ' && px < screen.width && py < screen.height)
                    screen.putPixel(px, py, under[row * mask.length + column]);
            }
    }

    void draw(ref Screen screen) nothrow @nogc
    {
        const outline = screen.encode(ink);
        const inside = screen.encode(paper);
        foreach (row, mask; shape)
            foreach (column, c; mask)
            {
                const px = x + cast(int) column;
                const py = y + cast(int) row;
                if (c == ' ' || px >= screen.width || py >= screen.height)
                    continue;
                under[row * mask.length + column] = screen.pixel(px, py);
                screen.putPixel(px, py, c == '#' ? outline : inside);
            }
    }
}
