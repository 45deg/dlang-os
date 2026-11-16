/// Read and write DlangFS from Ring 3. Use the most recently fetched directory listing.
module app_files;

import file_api : FsResult, FileVersion, maxFileBytes;
import gui_abi : DirectorySnapshot, FileTransfer, GuiFrame, savedVersion;
import user_abi : Call, callError, userHeapBase, userHeapInitialBytes;
import user_api : call;

private enum transferAddress = userHeapBase + GuiFrame.sizeof;
static assert(GuiFrame.sizeof % FileTransfer.alignof == 0);
private enum documentAddress = transferAddress + FileTransfer.sizeof;
static assert(GuiFrame.sizeof + FileTransfer.sizeof + maxFileBytes <= userHeapInitialBytes);

char[] documentBuffer() pure nothrow @nogc
{
    return (cast(char*) documentAddress)[0 .. maxFileBytes];
}

private __gshared DirectorySnapshot directory;
private __gshared ulong diskGeneration;
private __gshared bool mounted;

nothrow @nogc:

void updateDisk(bool available, ulong revision)
{
    mounted = available;
    diskGeneration = revision;
}

bool isMounted() { return mounted; }
ulong generation() { return diskGeneration; }

void refreshDirectory()
{
    call(Call.guiDirectory, cast(ulong) &directory);
}

const(char)[] nameAt(size_t slot)
{
    const entry = &directory[slot];
    return entry.name[0 .. entry.length];
}

private FileTransfer* prepare(scope const(char)[] name)
{
    auto transfer = cast(FileTransfer*) transferAddress;
    transfer.request.nameLength = cast(uint) name.length;
    foreach (i, char c; name)
        transfer.request.name[i] = c;
    return transfer;
}

FsResult open(scope const(char)[] name, out const(char)[] data, out FileVersion stored)
{
    if (name.length > FileTransfer.request.name.length)
        return FsResult.invalidName;
    auto transfer = prepare(name);
    const result = call(Call.guiReadFile, transferAddress);
    if (result > FsResult.max)
        return FsResult.ioError;
    if (result == FsResult.ok)
    {
        stored = transfer.request.fileVersion;
        data = transfer.data[0 .. transfer.request.length];
    }
    return cast(FsResult) result;
}

FsResult save(scope const(char)[] name, scope const(char)[] data, FileVersion expected, out FileVersion stored)
{
    if (name.length > FileTransfer.request.name.length)
        return FsResult.invalidName;
    if (data.length > maxFileBytes)
        return FsResult.tooLarge;
    auto transfer = prepare(name);
    transfer.request.fileVersion = expected;
    transfer.request.length = cast(uint) data.length;
    foreach (i, char c; data)
        transfer.data[i] = c;
    const result = call(Call.guiSaveFile, transferAddress);
    if ((result & savedVersion) && result != callError)
    {
        stored = FileVersion((result & ~savedVersion) >> 32, cast(uint) result);
        return FsResult.ok;
    }
    return result <= FsResult.max ? cast(FsResult) result : FsResult.ioError;
}
