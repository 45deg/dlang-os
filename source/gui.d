/// デスクトップの入力を各Ring 3アプリに配送し、コピーと検証が済んだ描画一覧を合成する。
module gui;

import address_space : AddressSpace, copyFromUser, copyToUser;
import boot_info : usableMemoryKiB;
import clock : milliseconds;
import file_api : FsResult, FileVersion, validFilename, maxNameBytes;
import filesystem : generation, isMounted, nameAt, open, save;
import graphics : Rect, Screen;
import gui_abi;
import process : exitedProcesses, faultedProcesses, infoAt, processLimit, processName;
import user_abi : Call, callError;

private struct GuiWindow
{
    uint pid;
    ushort width, height;
    bool focused, changed, inputChanged, seenMounted;
    ulong seenDiskGeneration;
    ubyte head, count;
    GuiInput[64] events;
    GuiFrame frame;
    DirectoryEntry openRequest;
}

private __gshared GuiWindow[maxGuiWindows] windows;
private __gshared GuiFrame incoming;
private __gshared FileTransfer transfer;

nothrow @nogc:

private GuiWindow* find(uint pid)
{
    if (pid != 0)
        foreach (ref window; windows)
            if (window.pid == pid)
                return &window;
    return null;
}

bool hasGui(uint pid) { return find(pid) !is null; }

void attachGui(uint pid, Rect body)
{
    foreach (ref window; windows)
        if (window.pid == 0)
        {
            window.pid = pid;
            window.width = cast(ushort) body.width;
            window.height = cast(ushort) body.height;
            window.focused = false;
            window.changed = false;
            window.inputChanged = true;
            window.seenDiskGeneration = generation();
            window.seenMounted = isMounted();
            window.head = window.count = 0;
            window.frame.commandCount = window.frame.titleLength = window.frame.dirty = 0;
            window.openRequest.length = 0;
            return;
        }
}

void detachGui(uint pid)
{
    auto window = find(pid);
    if (window !is null)
        window.pid = 0;
}

void setGuiFocus(uint pid, bool focused)
{
    auto window = find(pid);
    if (window !is null && window.focused != focused)
    {
        window.focused = focused;
        window.inputChanged = true;
    }
}

/// 未配送の入力、フォーカス、ディスク状態変更で待機中のアプリを再開する。
bool guiInputReady(uint pid)
{
    const window = find(pid);
    return window is null || window.count != 0 || window.inputChanged
        || window.seenDiskGeneration != generation() || window.seenMounted != isMounted();
}

void sendGuiEvent(uint pid, GuiEvent kind, ushort key = 0, int x = 0, int y = 0,
                  scope const(char)[] name = null)
{
    auto window = find(pid);
    if (window is null || name.length > maxNameBytes)
        return;

    const capacity = window.events.length;
    if (window.count != 0 && kind == GuiEvent.drag)
    {
        auto last = &window.events[(window.head + window.count - 1) % capacity];
        if (last.event == GuiEvent.drag)
        {
            last.x = cast(short) x;
            last.y = cast(short) y;
            return;
        }
    }
    if (window.count == capacity)
    {
        if (kind == GuiEvent.drag)
            return;
        window.head = cast(ubyte) ((window.head + 1) % capacity);
        --window.count;
    }
    auto event = &window.events[(window.head + window.count++) % capacity];
    *event = GuiInput.init;
    event.event = kind;
    event.key = key;
    event.x = cast(short) x;
    event.y = cast(short) y;
    event.filenameLength = cast(ubyte) name.length;
    foreach (i, char c; name)
        event.filename[i] = c;
}

bool takeGuiChange(uint pid)
{
    auto window = find(pid);
    if (window is null || !window.changed)
        return false;
    window.changed = false;
    return true;
}

const(char)[] guiTitle(uint pid)
{
    const window = find(pid);
    return window is null ? null : window.frame.title[0 .. window.frame.titleLength];
}

bool guiDirty(uint pid)
{
    const window = find(pid);
    return window !is null && window.frame.dirty != 0;
}

bool takeDocumentRequest(uint pid, out DirectoryEntry request)
{
    auto window = find(pid);
    if (window is null || window.openRequest.length == 0)
        return false;
    request = window.openRequest;
    window.openRequest.length = 0;
    return true;
}

void drawGui(uint pid, ref Screen screen, Rect body)
{
    const window = find(pid);
    if (window is null)
        return;
    screen.clipTo(body);
    foreach (ref command; window.frame.commands[0 .. window.frame.commandCount])
    {
        const x = body.x + command.x;
        const y = body.y + command.y;
        if (command.textLength == 0)
            screen.fill(Rect(x, y, command.width, command.height), command.color);
        else
            screen.text(x, y, window.frame.text[command.textOffset .. command.textOffset + command.textLength],
                command.color, command.height);
    }
    screen.resetClip();
}

ulong guiCall(uint pid, Call number, ref const AddressSpace space, ulong address, ulong length)
{
    auto window = find(pid);
    if (window is null)
        return callError;

    switch (number)
    {
        case Call.guiPoll: return poll(*window, space, address);
        case Call.guiPresent: return present(*window, space, address);
        case Call.guiDirectory: return readDirectory(space, address);
        case Call.guiReadFile: return accessFile(space, address, false);
        case Call.guiSaveFile: return accessFile(space, address, true);
        case Call.guiOpenDocument:
            if (length == 0 || length > maxNameBytes)
                return callError;
            DirectoryEntry request;
            if (!copyFromUser(space, address, request.name[0 .. length])
                || !validFilename(request.name[0 .. length]))
                return callError;
            request.length = cast(ubyte) length;
            window.openRequest = request;
            return 0;
        case Call.guiMonitor: return readMonitor(space, address);
        default: return callError;
    }
}

private ulong poll(ref GuiWindow window, ref const AddressSpace space, ulong address)
{
    GuiInput input;
    if (window.count != 0)
        input = window.events[window.head];
    input.width = window.width;
    input.height = window.height;
    input.focused = window.focused;
    input.now = milliseconds();
    input.mounted = isMounted();
    input.diskGeneration = generation();
    if (!copyToUser(space, address, (cast(const(char)*) &input)[0 .. GuiInput.sizeof]))
        return callError;
    window.inputChanged = false;
    window.seenDiskGeneration = input.diskGeneration;
    window.seenMounted = input.mounted;
    if (window.count != 0)
    {
        window.head = cast(ubyte) ((window.head + 1) % window.events.length);
        --window.count;
    }
    return 0;
}

private ulong present(ref GuiWindow window, ref const AddressSpace space, ulong address)
{
    if (!copyFromUser(space, address, (cast(char*) &incoming)[0 .. GuiFrame.sizeof])
        || incoming.commandCount > incoming.commands.length || incoming.textCount > incoming.text.length
        || incoming.titleLength > incoming.title.length || incoming.dirty > 1)
        return callError;
    foreach (char c; incoming.title[0 .. incoming.titleLength])
        if (c < ' ' || c > '~')
            return callError;
    foreach (char c; incoming.text[0 .. incoming.textCount])
        if (c < ' ' || c > '~')
            return callError;
    size_t nextText;
    foreach (ref command; incoming.commands[0 .. incoming.commandCount])
    {
        if (command.textLength == 0)
        {
            if (command.width <= 0 || command.height <= 0)
                return callError;
        }
        else
        {
            if ((command.height != 1 && command.height != 2) || command.textOffset != nextText)
                return callError;
            nextText += command.textLength;
            if (nextText > incoming.textCount)
                return callError;
        }
    }
    if (nextText != incoming.textCount)
        return callError;

    window.frame = incoming;
    window.changed = true;
    return 0;
}

private ulong readDirectory(ref const AddressSpace space, ulong address)
{
    DirectorySnapshot directory;
    foreach (slot, ref entry; directory)
    {
        const name = nameAt(slot);
        foreach (i, char c; name)
            entry.name[i] = c;
        entry.length = cast(ubyte) name.length;
    }
    return copyToUser(space, address, (cast(const(char)*) &directory)[0 .. DirectorySnapshot.sizeof]) ? 0 : callError;
}

private ulong accessFile(ref const AddressSpace space, ulong address, bool write)
{
    auto request = &transfer.request;
    if (!copyFromUser(space, address, (cast(char*) request)[0 .. FileRequest.sizeof])
        || request.nameLength > request.name.length)
        return callError;
    const name = request.name[0 .. request.nameLength];
    const dataAddress = address + FileTransfer.data.offsetof;
    if (write)
    {
        if (request.length > transfer.data.length)
            return FsResult.tooLarge;
        auto data = transfer.data[0 .. request.length];
        if (!copyFromUser(space, dataAddress, data))
            return callError;
        const result = save(name, data, &request.fileVersion);
        if (result != FsResult.ok)
            return result;
    }

    const(char)[] content;
    FileVersion stored;
    const result = open(name, content, stored);
    if (result != FsResult.ok)
        return result;
    if (write)
        return savedVersion | (cast(ulong) stored.slot << 32) | stored.sequence;

    request.fileVersion = stored;
    request.length = cast(uint) content.length;
    if (!copyToUser(space, address, (cast(const(char)*) request)[0 .. FileRequest.sizeof])
        || !copyToUser(space, dataAddress, content))
        return callError;
    return FsResult.ok;
}

private ulong readMonitor(ref const AddressSpace space, ulong address)
{
    MonitorSnapshot snapshot;
    snapshot.memoryKiB = usableMemoryKiB();
    snapshot.exited = exitedProcesses();
    snapshot.faulted = faultedProcesses();
    static assert(processLimit <= snapshot.rows.length);
    snapshot.capacity = processLimit;
    foreach (slot; 0 .. processLimit)
    {
        const task = infoAt(slot);
        if (task.pid == 0)
            continue;
        auto row = &snapshot.rows[snapshot.running++];
        row.pid = task.pid;
        row.slices = task.slices;
        row.preemptions = task.preemptions;
        const name = processName(task);
        foreach (i, char c; name)
            row.name[i] = c;
        row.nameLength = cast(ubyte) name.length;
    }
    return copyToUser(space, address, (cast(const(char)*) &snapshot)[0 .. MonitorSnapshot.sizeof]) ? 0 : callError;
}
