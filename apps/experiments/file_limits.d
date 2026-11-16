/// Check that large stored files cannot overflow the fixed-size GUI document ABI.
module file_limits;

import core.volatile : volatileStore;
import file_api : FsResult, maxFileBytes;
import gui_abi : FileTransfer;
import user_abi : Call, callError;
import user_api : call, send, exitApp;

private __gshared FileTransfer transfer;

extern(C) noreturn appMain() nothrow @nogc
{
    if (send(Call.guiCreate, "File limits") == callError) exitApp();
    transfer.request.name[0 .. 8] = "full.bin";
    transfer.request.nameLength = 8;
    transfer.request.length = 123;
    foreach (i; 0 .. transfer.data.length)
        volatileStore(cast(ubyte*) transfer.data.ptr + i, cast(ubyte) 'x');
    bool valid = call(Call.guiReadFile, cast(ulong) &transfer) == FsResult.tooLarge;
    valid = valid && transfer.request.length == 123;
    foreach (value; transfer.data)
        if (value != 'x') valid = false;
    transfer.request.length = maxFileBytes + 1;
    valid = valid && call(Call.guiSaveFile, cast(ulong) &transfer) == FsResult.tooLarge;
    send(Call.write, valid ? "GUI document size limit preserved.\n" : "GUI file limit failed.\n");
    exitApp();
}
