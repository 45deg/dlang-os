/// デスクトップとウィンドウの重なり順を管理し、入力から描画と画面転送を更新する。
module desktop;

import application : launchCounter;
import calculator : Calculator;
import cpu : ticks;
import desktop_theme : App, accent, accentLight, appName, apps, appsButton, button, centeredText,
    divider, drawShortcut, drawWallpaper, ink, labelWithin, menuBounds, menuItem, muted, paper,
    shortcut, taskbarHeight, titleHeight, toolbar, warning;
import editor : Editor, EditorClick, EditorClipboard;
import filesystem : FsResult, FileVersion, errorText, fileLimit, generation, isMounted, isText, nameAt, open;
import graphics : Rect, Screen, maximum, minimum;
import monitor : drawMonitor;
import numbers : decimalText;
import process : AppWindow, processLimit, takeWindowRequest, windowFor, windowInput, windowTitleFor;
import ps2 : InputKind, Key, MouseEvent, Ps2;
import snake : Snake;
import user_abi : WindowEvent;

private enum windowLimit = 7;
private enum editorLimit = 4;
private enum noWindow = windowLimit;
private enum int fileRowHeight = 16;
private immutable string[apps.length] launchKeys = ["F5", "F8", "F9", "", "", ""];

private struct Window
{
    Rect bounds;
    App app;
    uint pid;
    bool minimized;
    bool open;
}

struct Desktop
{
    private Screen screen;
    private Ps2 devices;
    private Pointer pointer;
    private bool active;
    private bool menuOpen;
    private size_t menuSelection;
    private const(char)[] notice;

    // 番号は窓を閉じるまで固定。orderは手前に出したときだけ並べ替える。
    private Window[windowLimit] windows;
    private Editor[windowLimit] editors;
    private EditorClipboard clipboard;
    private Calculator[windowLimit] calculators;
    private Snake game;
    private size_t[windowLimit] order;
    private size_t windowCount;
    private size_t focused = noWindow;
    private size_t dragged = noWindow;
    private EditorClick editorDrag;
    private int grabX, grabY;
    private ulong lastLivePaint;

    private size_t[fileLimit] fileSlots;
    private size_t fileCount;
    private size_t selectedFile;
    private ulong seenGeneration;

    nothrow @nogc:

    bool init()
    {
        if (!screen.init())
            return false;
        pointer.x = screen.width / 2;
        pointer.y = screen.height / 2;
        active = true;
        if (!devices.init())
            notice = "PS/2 unavailable. Use the serial shell.";
        refreshFiles();
        redraw(fullScreen());
        return true;
    }

    void poll()
    {
        if (!active)
            return;

        const event = devices.poll();
        const windowsChanged = syncAppWindows();
        const filesChanged = seenGeneration != generation();
        if (filesChanged)
            refreshFiles();
        const now = ticks();
        const gameDamage = advanceGame(now);

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
            if (windowsChanged || filesChanged || (changed && movedWindow.width == 0))
                redraw(fullScreen());
            else if (movedWindow.width != 0 || gameDamage.width != 0)
                redraw(movedWindow.covering(gameDamage).covering(cursorDamage).covering(liveDamage()));
            else if (event.mouse.dx || event.mouse.dy)
                present(cursorDamage);
        }
        else if (windowsChanged || filesChanged)
            redraw(fullScreen());
        else if (gameDamage.width != 0 || now - lastLivePaint >= 120_000_000)
        {
            const damage = gameDamage.covering(liveDamage());
            if (damage.width > 0)
                redraw(damage);
        }
    }

    private Rect fullScreen() const
    {
        return Rect(0, 0, screen.width, screen.height);
    }

    private void present(Rect damage)
    {
        // RAM上のデスクトップを使い回せるよう、ポインタは転送の間だけ合成する。
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

        switch (key)
        {
            case Key.openFiles: launch(App.files); return;
            case Key.newEditor: launch(App.editor); return;
            case Key.newCounter: launch(App.counter); return;
            case Key.cycleWindow: cycleWindows(); return;
            case Key.closeWindow:
                if (focused != noWindow)
                    close(focused);
                return;
            default: break;
        }

        if (key == Key.newFile && (focused == noWindow || windows[focused].app != App.editor))
            launch(App.editor);
        if (focused == noWindow)
            return;

        if (windows[focused].app == App.editor)
        {
            if (editors[focused].keyPress(key, clipboard))
                close(focused);
        }
        else if (windows[focused].app == App.calc)
            calculators[focused].keyPress(key);
        else if (windows[focused].app == App.game)
            game.keyPress(key, ticks());
        else if (windows[focused].app == App.counter && (key == Key.enter || key == ' '))
            windowInput(windows[focused].pid, WindowEvent.activate);
        else if (windows[focused].app == App.files)
        {
            if (key == Key.up && selectedFile > 0)
                --selectedFile;
            else if (key == Key.down && selectedFile + 1 < fileCount)
                ++selectedFile;
            else if (key == Key.enter)
                openSelectedFile();
        }
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
            if (editorDrag != EditorClick.none)
            {
                const body = bodyOf(windows[dragged].bounds);
                auto editor = &editors[dragged];
                const changed = editorDrag == EditorClick.select
                    ? editor.dragSelection(body, pointer.x, pointer.y)
                    : editor.scrollPointer(body, pointer.y);
                if (!event.leftDown)
                    dragged = noWindow;
                if (changed)
                    movedWindow = body;
                return changed;
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
                    editorDrag = EditorClick.none;
                    grabX = pointer.x - window.bounds.x;
                    grabY = pointer.y - window.bounds.y;
                }
                else if (window.app == App.editor)
                {
                    const action = editors[slot].click(bodyOf(window.bounds), pointer.x, pointer.y, clipboard);
                    if (action == EditorClick.close)
                        close(slot);
                    else if (action == EditorClick.select || action == EditorClick.scroll)
                    {
                        dragged = slot;
                        editorDrag = action;
                    }
                }
                else if (window.app == App.files)
                    clickFiles(bodyOf(window.bounds));
                else if (window.app == App.calc)
                    calculators[slot].click(bodyOf(window.bounds), pointer.x, pointer.y);
                else if (window.app == App.game)
                    game.click(bodyOf(window.bounds), pointer.x, pointer.y, ticks());
                else if (window.app == App.counter)
                    windowInput(window.pid, WindowEvent.activate);
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
        uint editorCount;
        foreach (i, ref window; windows)
        {
            if (!window.open && slot == noWindow)
                slot = i;
            if (window.open && window.app == app)
            {
                if (app == App.files || app == App.game || app == App.monitor)
                {
                    bringForward(i);
                    return i;
                }
                if (app == App.editor)
                    ++editorCount;
            }
        }
        if (slot == noWindow || editorCount >= editorLimit)
        {
            notice = "Close a window before opening another.";
            return noWindow;
        }

        if (app == App.counter)
        {
            uint pid;
            notice = launchCounter(pid);
            return noWindow; // ELFがwindowOpenを呼び出した時点で窓を作る。
        }
        if (app == App.editor)
            editors[slot] = Editor.init;
        else if (app == App.calc)
            calculators[slot] = Calculator.init;
        else if (app == App.game)
            game = Snake.init;
        attachWindow(slot, app, 0);
        return slot;
    }

    private void attachWindow(size_t slot, App app, uint pid)
    {
        windows[slot] = Window(initialBounds(app), app, pid, false, true);
        order[windowCount++] = slot;
        focused = slot;
    }

    private Rect initialBounds(App app) const
    {
        const offset = cast(int) (windowCount % 4);
        int x, y, width, height;
        final switch (app)
        {
            case App.files: x = 128; y = 49; width = 294; height = 354; break;
            case App.editor: x = 199 + offset * 24; y = 76 + offset * 29; width = 468; height = 340; break;
            case App.counter: x = screen.width - 292 - offset * 33; y = 113 + offset * 81;
                width = 256; height = 123; break;
            case App.calc: x = 185 + offset * 18; y = 64 + offset * 20;
                width = 282; height = 312; break;
            case App.game: x = 207 + offset * 22; y = 94 + offset * 25;
                width = 334; height = 303; break;
            case App.monitor: x = screen.width - 448 - offset * 14; y = 55 + offset * 17;
                width = 420; height = 319; break;
        }
        return Rect(minimum(x, screen.width - width - 12),
            minimum(y, screen.height - taskbarHeight - height - 12), width, height);
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
        const window = windows[slot];
        if (window.app == App.editor && editors[slot].unsaved())
        {
            bringForward(slot);
            editors[slot].keepOpen();
            return;
        }
        if (window.app == App.counter)
            windowInput(window.pid, WindowEvent.close);
        remove(slot);
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
            AppWindow info;
            if (window.open && window.app == App.counter && !windowFor(window.pid, info))
            {
                remove(slot);
                changed = true;
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
                windowInput(pid, WindowEvent.close);
            }
            else
                attachWindow(slot, App.counter, pid);
            changed = true;
        }
        return changed;
    }

    private Rect liveDamage()
    {
        Rect damage;
        foreach (ref window; windows)
            if (window.open && !window.minimized && (window.app == App.counter || window.app == App.monitor))
                damage = damage.covering(bodyOf(window.bounds));
        return damage;
    }

    private Rect advanceGame(ulong now)
    {
        foreach (slot, ref window; windows)
            if (window.open && window.app == App.game)
            {
                const changed = game.advance(now, !window.minimized && !menuOpen && focused == slot);
                if (changed && !window.minimized)
                    return bodyOf(window.bounds);
                break;
            }
        return Rect.init;
    }

    private Rect withShadow(Rect bounds)
    {
        return Rect(bounds.x, bounds.y, bounds.width + 4, bounds.height + 5);
    }

    private void refreshFiles()
    {
        const previous = fileCount > 0 ? fileSlots[selectedFile] : fileLimit;
        fileCount = 0;
        foreach (slot; 0 .. fileLimit)
            if (nameAt(slot).length)
                fileSlots[fileCount++] = slot;
        if (fileCount == 0 || selectedFile >= fileCount)
            selectedFile = 0;
        foreach (i; 0 .. fileCount)
            if (fileSlots[i] == previous)
                selectedFile = i;
        seenGeneration = generation();
    }

    private void clickFiles(Rect body)
    {
        if (openButton(body).contains(pointer.x, pointer.y))
            openSelectedFile();
        else
        {
            const items = Rect(body.x + 8, body.y + 46, body.width - 16, cast(int) fileCount * fileRowHeight);
            if (items.contains(pointer.x, pointer.y))
                selectedFile = cast(size_t) ((pointer.y - items.y) / fileRowHeight);
        }
    }

    private void openSelectedFile()
    {
        if (fileCount == 0)
            return;
        const name = nameAt(fileSlots[selectedFile]);
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
            if (window.open && window.app == App.editor && editors[slot].isEditing(name))
            {
                editors[slot].reopen(name, contents, storedVersion);
                bringForward(slot);
                return;
            }

        const slot = launch(App.editor);
        if (slot != noWindow)
            editors[slot].loadDocument(name, contents, storedVersion);
    }

    private Rect taskButton(int index) const
    {
        const spacing = minimum(100, (screen.width - 163) / windowLimit);
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

    private Rect openButton(Rect body)
    {
        return Rect(body.x + 10, body.y + 9, 52, 24);
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
        lastLivePaint = ticks();
        present(damage);
    }

    private const(char)[] windowTitle(size_t slot)
    {
        if (windows[slot].app == App.counter)
            return windowTitleFor(windows[slot].pid);
        return windows[slot].app == App.editor ? editors[slot].title() : appName(windows[slot].app);
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
        labelWithin(screen, Rect(screen.width - 76, top, 76, taskbarHeight), "Dlang OS", paper);
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
                launchKeys[cast(size_t) app], muted);
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
        if (window.app == App.editor && editors[slot].unsaved())
            centeredText(screen, Rect(bounds.x + bounds.width - 67, bounds.y, 14, titleHeight), "*", paper);

        const minimizeRect = minimizeButton(bounds);
        screen.fill(minimizeRect, muted);
        centeredText(screen, minimizeRect, "-", paper);
        const closeRect = closeButton(bounds);
        screen.fill(closeRect, warning);
        centeredText(screen, closeRect, "x", paper);
        const body = bodyOf(bounds);
        final switch (window.app)
        {
            case App.files: drawFiles(body); break;
            case App.editor: editors[slot].draw(screen, body, activeWindow, clipboard.hasText()); break;
            case App.counter: drawCounter(body, window.pid); break;
            case App.calc: calculators[slot].draw(screen, body); break;
            case App.game: game.draw(screen, body); break;
            case App.monitor: drawMonitor(screen, body); break;
        }
    }

    private void drawFiles(Rect body)
    {
        screen.fill(body, paper);
        screen.fill(Rect(body.x, body.y, body.width, 41), toolbar);
        button(screen, openButton(body), "Open", fileCount != 0);
        screen.text(body.x + 72, body.y + 17, "Select a file, then Open", muted);
        if (fileCount == 0)
            screen.text(body.x + 12, body.y + 54, isMounted() ? "No saved files" : "Data disk unavailable", muted);
        foreach (i; 0 .. fileCount)
        {
            const row = Rect(body.x + 8, body.y + 46 + cast(int) i * fileRowHeight, body.width - 16, fileRowHeight);
            if (i == selectedFile)
            {
                screen.fill(row, accentLight);
                labelWithin(screen, Rect(row.x + 5, row.y, 8, row.height), ">", accent);
            }
            labelWithin(screen, Rect(row.x + 19, row.y, row.width - 19, row.height), nameAt(fileSlots[i]), ink);
        }
    }

    private void drawCounter(Rect body, uint pid)
    {
        screen.fill(body, paper);
        AppWindow app;
        if (!windowFor(pid, app))
            return;
        screen.text(body.x + 13, body.y + 11, "User process", muted);
        screen.text(body.x + 167, body.y + 11, "PID", muted);
        drawNumber(body.x + 199, body.y + 11, pid, 1);
        const line = app.text[0 .. app.textLength];
        if (line.length <= 14)
            screen.text(body.x + 13, body.y + 34, line, ink, 2);
        else
            screen.text(body.x + 13, body.y + 39, line, ink);
        screen.text(body.x + 13, body.y + 71, "Click or Enter sends input", muted);
    }

    private void drawNumber(int x, int y, ulong value, int scale)
    {
        char[20] digits = void;
        screen.text(x, y, decimalText(value, digits), ink, scale);
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
