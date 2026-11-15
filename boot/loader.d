/// efiMainはESPのカーネルを読み、GOPとページテーブルを準備する。
/// finishBootは最終メモリマップを取得し、UEFIを終了してカーネルへ渡す。
module loader;

import boot_info : BootFramebuffer, BootInfo, bootPhysicalLimit, directMapOffset;
import boot_paging;
import cpu : haltCpu;
import kernel_image : KernelImage, maxKernelBytes;
import runtime : memset;
import serial : initSerial, writeText;
import uefi;

private enum ulong stackBytes = 64 * 1024;
private enum ulong framebufferAddress = directMapOffset + bootPhysicalLimit;

private struct Display
{
    BootFramebuffer framebuffer;
    ulong physical, bytes;

    ulong backBufferBytes() const pure nothrow @nogc
    {
        return cast(ulong) framebuffer.width * framebuffer.height * uint.sizeof;
    }
}

extern(C) Status efiMain(Handle handle, SystemTable* system) nothrow @nogc
{
    initSerial();
    if (!supportsKernelPaging())
        return fail("Four-level paging with NX is required.", unsupported);

    auto services = system.bootServices;
    LoadedImage* loaded;
    auto status = services.handleProtocol(handle, &loadedImageGuid, cast(void**) &loaded);
    if (status != success)
        return fail("Cannot locate the loader image.", status);

    auto display = findDisplay(services);
    ubyte[] file;
    status = readKernel(services, loaded.deviceHandle, file);
    if (status != success)
        return fail("Cannot read kernel.elf.", status);

    // ファイルとUEFIのハンドルは、最終メモリマップを取る前に解放する。
    Handoff handoff;
    status = prepareKernel(services, loaded, file, display, handoff);
    services.freePool(file.ptr);
    if (status != success)
        return fail("Cannot prepare the kernel image or page tables.", status);

    bool exitAttempted;
    status = finishBoot(services, handle, handoff, exitAttempted);
    if (exitAttempted)
    {
        // 失敗でもファームウェアが部分的に終了していることがある。
        fail("Cannot exit UEFI boot services.", status);
        haltCpu();
    }
    services.freePages(handoff.arenaPhysical, handoff.arenaPages);
    return fail("Cannot obtain the UEFI memory map.", status);
}

private Status readKernel(BootServices* services, Handle device, out ubyte[] image) nothrow @nogc
{
    SimpleFileSystem* filesystem;
    auto status = services.handleProtocol(device, &simpleFileSystemGuid, cast(void**) &filesystem);
    if (status != success)
        return status;

    File* root;
    status = filesystem.openVolume(filesystem, &root);
    if (status != success)
        return status;
    scope(exit) root.close(root);

    File* file;
    enum ulong openRead = 1;
    status = root.open(root, &file, "\\kernel.elf"w.ptr, openRead, 0);
    if (status != success)
        return status;
    scope(exit) file.close(file);

    ulong bytes;
    status = file.setPosition(file, ulong.max); // ファイル末尾
    if (status != success)
        return status;
    status = file.getPosition(file, &bytes);
    if (status != success)
        return status;
    if (bytes == 0 || bytes > maxKernelBytes)
        return loadError;
    status = file.setPosition(file, 0);
    if (status != success)
        return status;

    void* buffer;
    status = services.allocatePool(loaderData, bytes, &buffer);
    if (status != success)
        return status;
    size_t readBytes = bytes;
    status = file.read(file, &readBytes, buffer);
    if (status != success || readBytes != bytes)
    {
        services.freePool(buffer);
        return status == success ? loadError : status;
    }
    image = (cast(ubyte*) buffer)[0 .. bytes];
    return success;
}

private Display findDisplay(BootServices* services) nothrow @nogc
{
    GraphicsOutput* gop;
    if (services.locateProtocol(&graphicsOutputGuid, null, cast(void**) &gop) != success)
        return Display.init;

    // 既存のデスクトップと同じ解像度を優先する。なければ現在のモードを使う。
    foreach (mode; 0 .. gop.mode.maxMode)
    {
        GraphicsInfo* info;
        size_t infoSize;
        if (gop.queryMode(gop, mode, &infoSize, &info) != success)
            continue;
        const preferred = infoSize >= GraphicsInfo.sizeof && info.width == 800 && info.height == 600
            && info.pixelFormat != PixelFormat.bltOnly;
        services.freePool(info);
        if (preferred && (mode == gop.mode.mode || gop.setMode(gop, mode) == success))
            break;
    }

    const mode = gop.mode;
    const info = mode.info;
    if (info is null || mode.infoSize < GraphicsInfo.sizeof
        || mode.framebufferBase == 0 || mode.framebufferBase % uint.sizeof != 0
        || info.width < 640 || info.height < 480 || info.width > 8192 || info.height > 8192
        || info.pixelsPerScanLine < info.width || info.pixelsPerScanLine > 8192)
        return Display.init;

    const pitch = info.pixelsPerScanLine * uint.sizeof;
    const bytes = pitch * info.height;
    if (bytes > mode.framebufferSize || mode.framebufferBase >= (1UL << 52)
        || bytes > (1UL << 52) - mode.framebufferBase)
        return Display.init;

    BootFramebuffer framebuffer;
    framebuffer.width = info.width;
    framebuffer.height = info.height;
    framebuffer.pitchBytes = cast(uint) pitch;
    switch (info.pixelFormat)
    {
    case PixelFormat.rgb:
        framebuffer.greenShift = 8;
        framebuffer.blueShift = 16;
        break;
    case PixelFormat.bgr:
        framebuffer.redShift = 16;
        framebuffer.greenShift = 8;
        break;
    case PixelFormat.bitMask:
        if (!byteShift(info.redMask, framebuffer.redShift)
            || !byteShift(info.greenMask, framebuffer.greenShift)
            || !byteShift(info.blueMask, framebuffer.blueShift)
            || framebuffer.redShift == framebuffer.greenShift || framebuffer.redShift == framebuffer.blueShift
            || framebuffer.greenShift == framebuffer.blueShift)
            return Display.init;
        break;
    default:
        return Display.init;
    }
    return Display(framebuffer, mode.framebufferBase, bytes);
}

private bool byteShift(uint mask, out ubyte shift) pure nothrow @nogc
{
    foreach (ubyte bits; [0, 8, 16, 24])
    {
        if (mask == 0xffU << bits)
        {
            shift = bits;
            return true;
        }
    }
    return false;
}

private struct Handoff
{
    ulong arenaPhysical, arenaPages;
    ulong root, stackTop, entry;
    BootInfo* info;
}

private Status prepareKernel(BootServices* services, const(LoadedImage)* loaded,
    const(ubyte)[] file, ref Display display, out Handoff handoff) nothrow @nogc
{
    KernelImage kernel;
    if (!kernel.parse(file))
        return loadError;

    // 上位マッピングとダイレクトマップの両方にカーネルを含める。
    // 各範囲の境界跨ぎと上位テーブル用にページを追加する。
    const dataBytes = kernel.memoryBytes + stackBytes + pageBytes + roundToPage(display.backBufferBytes());
    const loaderBytes = roundToPage(loaded.imageSize);
    const tablePages = 32 + (dataBytes + kernel.memoryBytes + display.bytes + loaderBytes) / pageTableCoverage;
    const arenaPages = dataBytes / pageBytes + tablePages;
    ulong arena = bootPhysicalLimit - 1;
    const status = services.allocatePages(allocateMaxAddress, loaderData, arenaPages, &arena);
    if (status != success)
        return status;

    memset(cast(void*) arena, 0, arenaPages * pageBytes);
    BootPages pages = BootPages(arena, arenaPages * pageBytes);
    const kernelPhysical = pages.take(kernel.memoryBytes);
    const stackPhysical = pages.take(stackBytes);
    auto info = cast(BootInfo*) pages.take(pageBytes);

    if (display.bytes != 0)
    {
        const backBuffer = pages.take(roundToPage(display.backBufferBytes()));
        info.backBuffer = cast(uint*) (directMapOffset + backBuffer);
        info.framebuffer = display.framebuffer;
        info.framebuffer.address = cast(uint*) (framebufferAddress + display.physical % pageBytes);
    }

    PageTables tables = PageTables(pages);
    const loaderBase = cast(ulong) loaded.imageBase;
    const workspaceBytes = arenaPages * pageBytes - kernel.memoryBytes;
    if (!tables.map(directMapOffset + stackPhysical, stackPhysical, workspaceBytes, pageWritable | pageNoExecute)
        || !tables.map(loaderBase, loaderBase, loaderBytes, 0)
        || !kernel.load(kernelPhysical, tables)
        || (display.bytes != 0
            && !tables.map(framebufferAddress, display.physical & ~(pageBytes - 1),
                display.bytes + display.physical % pageBytes, pageWritable | pageUncached | pageNoExecute)))
    {
        services.freePages(arena, arenaPages);
        return loadError;
    }

    handoff = Handoff(arena, arenaPages, tables.root, directMapOffset + stackPhysical + stackBytes, kernel.entry, info);
    return success;
}

private Status finishBoot(BootServices* services, Handle handle, ref Handoff handoff,
    out bool exitAttempted) nothrow @nogc
{
    size_t required, key, descriptorBytes;
    uint descriptorVersion;
    auto status = services.getMemoryMap(&required, null, &key, &descriptorBytes, &descriptorVersion);
    if (status != bufferTooSmall)
        return status == success ? loadError : status;

    void* map;
    scope(exit)
        if (!exitAttempted && map !is null)
            services.freePool(map);

    // バッファの確保やファームウェア内の処理でマップが変わる。古いキーで失敗したら取り直す。
    size_t capacity;
    foreach (_; 0 .. 8)
    {
        if (required > capacity)
        {
            if (map !is null)
                services.freePool(map);
            map = null;
            capacity = required + pageBytes;
            status = services.allocatePool(loaderData, capacity, &map);
            if (status != success)
                return status;
        }

        required = capacity;
        status = services.getMemoryMap(&required, map, &key, &descriptorBytes, &descriptorVersion);
        if (status == bufferTooSmall)
            continue;
        if (status != success)
            return status;
        if (descriptorBytes < MemoryDescriptor.sizeof || required % descriptorBytes != 0)
            return loadError;

        ulong usableKiB;
        const entries = cast(const(ubyte)*) map;
        for (size_t offset = 0; offset < required; offset += descriptorBytes)
        {
            const descriptor = cast(const(MemoryDescriptor)*) (entries + offset);
            if (descriptor.type == conventionalMemory)
                usableKiB += descriptor.pageCount * (pageBytes / 1024);
        }
        handoff.info.usableKiB = usableKiB;

        exitAttempted = true;
        status = services.exitBootServices(handle, key);
        if (status == success)
        {
            enterKernel(handoff.root, handoff.stackTop, handoff.entry,
                directMapOffset + cast(ulong) handoff.info);
            haltCpu();
        }
        if (status != invalidParameter)
            return status;
    }
    return status;
}

private Status fail(scope const(char)[] message, Status status) nothrow @nogc
{
    writeText("UEFI loader: ");
    writeText(message);
    writeText("\r\n");
    return status;
}
