/// Validate static ELF64, map PT_LOAD segments, and initialize variant-II main-thread TLS from PT_TLS.
module elf;

import address_space : AddressSpace, mapImage, copyToUser, pageBytes, userCodeAddress, userImageEnd;

private enum ulong tlsAddress = userImageEnd - 128 * 1024;
private enum ulong maxTlsBytes = 64 * 1024;

private enum expectedElfHeaderSize = 64;
private enum expectedProgramHeaderSize = 56;
private enum loadSegment = 1;
private enum dynamicSegment = 2;
private enum interpreterSegment = 3;
private enum tlsSegment = 7;
private enum stackSegment = 0x6474e551;
private enum flagExecute = 1;
private enum flagWrite = 2;
private enum flagRead = 4;

bool loadElf(ref AddressSpace space, scope const(char)[] image, out ulong entry) nothrow @nogc
{
    if (image.length < expectedElfHeaderSize || little(image, 0, 4) != 0x464c457f
        || image[4] != 2 || image[5] != 1 || image[6] != 1
        || little(image, 16, 2) != 2 || little(image, 18, 2) != 62 || little(image, 20, 4) != 1
        || little(image, 52, 2) != expectedElfHeaderSize
        || little(image, 54, 2) != expectedProgramHeaderSize)
        return false;

    const pc = little(image, 24, 8);
    const programHeaders = little(image, 32, 8);
    const count = little(image, 56, 2);
    if (count == 0 || count > 32 || programHeaders < expectedElfHeaderSize
        || !contains(image.length, programHeaders, count * expectedProgramHeaderSize))
        return false;

    bool entryIsExecutable;
    ulong tlsHeader;
    foreach (i; 0 .. count)
    {
        const header = programHeaders + i * expectedProgramHeaderSize;
        const kind = little(image, header, 4);
        const flags = little(image, header + 4, 4);
        if (kind == tlsSegment)
        {
            if (tlsHeader != 0) return false;
            tlsHeader = header;
            continue;
        }
        if (kind == dynamicSegment || kind == interpreterSegment
            || (kind == stackSegment && (flags & flagExecute)))
            return false;
        if (kind != loadSegment)
            continue;

        const offset = little(image, header + 8, 8);
        const address = little(image, header + 16, 8);
        const filesz = little(image, header + 32, 8);
        const memsz = little(image, header + 40, 8);
        const alignment = little(image, header + 48, 8);
        if (flags & ~7UL || !(flags & flagRead) || (flags & 3) == 3
            || alignment != pageBytes || offset % pageBytes != 0
            || filesz > memsz || !contains(image.length, offset, filesz)
            || address < userCodeAddress || address >= tlsAddress || memsz > tlsAddress - address)
            return false;

        const execute = (flags & flagExecute) != 0;
        if (!mapImage(space, address, memsz, image[offset .. offset + filesz], (flags & flagWrite) != 0, execute))
            return false;
        if (execute && pc >= address && pc - address < filesz)
            entryIsExecutable = true;
    }
    if (!entryIsExecutable)
        return false;
    if (tlsHeader && !initializeTls(space, image, tlsHeader))
        return false;
    entry = pc;
    return true;
}

private bool initializeTls(ref AddressSpace space, scope const(char)[] image, ulong header) nothrow @nogc
{
    const flags = little(image, header + 4, 4);
    const offset = little(image, header + 8, 8);
    const address = little(image, header + 16, 8);
    const filesz = little(image, header + 32, 8);
    const memsz = little(image, header + 40, 8);
    const alignment = little(image, header + 48, 8);
    if (flags != flagRead || alignment == 0 || alignment > pageBytes
        || (alignment & (alignment - 1)) != 0 || address % alignment != 0 || offset % alignment != 0
        || memsz == 0 || memsz > maxTlsBytes || filesz > memsz || !contains(image.length, offset, filesz))
        return false;
    // The TLS template must belong to a writable load segment, not arbitrary bytes in the ELF.
    bool contained;
    const programs = little(image, 32, 8);
    foreach (i; 0 .. little(image, 56, 2))
    {
        const load = programs + i * expectedProgramHeaderSize;
        if (little(image, load, 4) != loadSegment || little(image, load + 4, 4) != (flagRead | flagWrite))
            continue;
        const base = little(image, load + 16, 8);
        const fileOffset = little(image, load + 8, 8);
        // .tbss has no load-image backing; only initialized TLS bytes must lie in PT_LOAD.
        if (address >= base && contains(little(image, load + 40, 8), address - base, filesz)
            && offset >= fileOffset && offset - fileOffset == address - base
            && contains(little(image, load + 32, 8), offset - fileOffset, filesz))
            contained = true;
    }
    if (!contained) return false;
    const size = (memsz + alignment - 1) & ~(alignment - 1);
    if (!mapImage(space, tlsAddress, size + ulong.sizeof, image[offset .. offset + filesz], true, false))
        return false;
    space.threadPointer = tlsAddress + size;
    // LLVM local-exec TLS uses negative FS offsets and may load the self pointer at FS:0.
    const pointer = space.threadPointer;
    return copyToUser(space, pointer, (cast(const(char)*) &pointer)[0 .. pointer.sizeof]);
}

private bool contains(ulong span, ulong offset, ulong count) pure nothrow @nogc
{
    return offset <= span && count <= span - offset;
}

private ulong little(scope const(char)[] data, size_t offset, uint size) pure nothrow @nogc
{
    ulong value;
    foreach (i; 0 .. size)
        value |= cast(ulong) cast(ubyte) data[offset + i] << (8 * i);
    return value;
}
