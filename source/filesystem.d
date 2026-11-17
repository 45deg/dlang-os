/// mount validates DlangFS4 headers and loadEntries recovers the last committed state of each slot.
/// commit writes the file data first and publishes its generation number and checksum last.
module filesystem;

import block_device : BlockDevice, Sector, sectorBytes;
import storage : initStorage, blockDevices;

private __gshared BlockDevice disk;

public import file_api;

// The on-disk name width is part of the format and independent of the ABI buffer limit.
private enum diskNameBytes = 24;
static assert(maxNameBytes >= diskNameBytes);

private struct Metadata
{
    align(1):
    uint sequence;
    uint checksum;
    uint length;
    char[diskNameBytes] name = 0;
}

private union HeaderSector
{
    Metadata fields;
    Sector raw;
}

private struct Entry
{
    Metadata fields;
    bool secondCopy;
    char[maxStoredFileBytes] payload = void;
}

private enum CopyStatus { blank, invalid, valid, ioError }

static assert(Metadata.sizeof == 36 && Metadata.checksum.offsetof == 4);
static assert(maxStoredFileBytes % sectorBytes == 0);

private struct LayoutHeader
{
    align(1):
    char[8] magic;
    uint versionNumber, sectorSize, slots, fileBytes, recordsLba, sectorsPerCopy;
    uint metadataBytes, nameBytes, checksum;
}
private union LayoutSector { LayoutHeader fields; Sector raw; }
static assert(LayoutHeader.sizeof == 44 && LayoutHeader.checksum.offsetof == 40);
private __gshared uint volumeSlots, volumeFileBytes, recordsLba, sectorsPerCopy;
private enum uint hashSeed = 2166136261;

private __gshared Entry[fileLimit] entries;
private __gshared char[maxStoredFileBytes] scratch = void;
private __gshared bool mounted;
private __gshared ulong changes;

nothrow @nogc:

bool mount()
{
    mounted = false;
    entries[] = Entry.init;
    Sector header, last;
    if (!initStorage()) return false;
    bool found;
    foreach (candidate; blockDevices())
    {
        Sector first;
        if (!candidate.read(0, first)) continue;
        const magic = (cast(const(char)*) first.ptr)[0 .. 8];
        if (!equal(magic, "DLANGFS4"))
            continue;
        // Avoid choosing a write target by attachment order when several disks could contain DlangFS.
        if (found) return false;
        disk = candidate;
        header = first;
        found = true;
    }
    if (!found) return false;
    if (!readLayout(header)) return false;
    // Use 64-bit arithmetic to check that the layout fits on the selected block device.
    const end = cast(ulong) recordsLba + cast(ulong) volumeSlots * 2 * sectorsPerCopy;
    if (volumeSlots == 0 || volumeSlots > fileLimit || volumeFileBytes == 0 || volumeFileBytes > maxStoredFileBytes
        || recordsLba == 0
        || sectorsPerCopy < 1 + (volumeFileBytes + sectorBytes - 1) / sectorBytes
        || end > disk.sectorCount || end > 0x1_0000_0000 || !readSector(cast(uint) (end - 1), last))
        return false;
    mounted = loadEntries();
    return mounted;
}

private bool readLayout(ref const Sector raw)
{
    LayoutSector header;
    header.raw = raw;
    const bytes = (cast(const(char)*) raw.ptr)[0 .. sectorBytes];
    const fields = header.fields;
    if (!equal(fields.magic[], "DLANGFS4") || fields.versionNumber != 4
        || fields.sectorSize != sectorBytes
        || fields.metadataBytes != Metadata.sizeof
        || fields.nameBytes != diskNameBytes
        || fields.checksum != hashBytes(hashBytes(hashSeed, bytes[0 .. 40]), bytes[44 .. $]))
        return false;
    foreach (c; bytes[44 .. $])
        if (c != 0) return false;
    volumeSlots = fields.slots;
    volumeFileBytes = fields.fileBytes;
    recordsLba = fields.recordsLba;
    sectorsPerCopy = fields.sectorsPerCopy;
    return true;
}

uint capacity() { return mounted ? volumeSlots : 0; }
uint fileSizeLimit() { return mounted ? volumeFileBytes : 0; }

private bool loadEntries()
{
    foreach (slot, ref entry; entries[0 .. volumeSlots])
    {
        Metadata first, second;
        const a = readCopy(copyLba(slot, false), first, entry.payload);
        const b = readCopy(copyLba(slot, true), second, scratch);
        if (a == CopyStatus.ioError || b == CopyStatus.ioError)
            return false;
        if (b == CopyStatus.valid && (a != CopyStatus.valid || isNewer(second.sequence, first.sequence)))
        {
            entry.fields = second;
            entry.secondCopy = true;
            foreach (i; 0 .. second.length)
                entry.payload[i] = scratch[i];
        }
        else if (a == CopyStatus.valid)
        {
            entry.fields = first;
            entry.secondCopy = false;
        }
        // 初回保存は B 側に書く。A 側が空なら、B 側の無効な世代は未完了の初回保存として扱う。
        else if (a != CopyStatus.blank)
            return false;
    }
    return true;
}

private CopyStatus readCopy(uint lba, out Metadata fields, ref char[maxStoredFileBytes] payload)
{
    HeaderSector header = void;
    if (!readSector(lba, header.raw))
        return CopyStatus.ioError;
    if (isBlank(header.raw))
        return CopyStatus.blank;
    fields = header.fields;
    if (!validMetadata(fields, volumeFileBytes))
        return CopyStatus.invalid;

    size_t copied;
    while (copied < fields.length)
    {
        Sector sector;
        if (!readSector(++lba, sector))
            return CopyStatus.ioError;

        const count = sectorLength(fields.length - copied);
        const bytes = cast(const(char)*) sector.ptr;
        foreach (i; 0 .. count)
            payload[copied + i] = bytes[i];
        copied += count;
    }
    return fields.checksum == checksum(fields, payload[0 .. fields.length])
        ? CopyStatus.valid : CopyStatus.invalid;
}

bool isMounted()
{
    return mounted;
}

ulong generation()
{
    return changes;
}

const(char)[] nameAt(size_t slot)
{
    return mounted && slot < volumeSlots ? filename(entries[slot].fields) : null;
}

/// data is a view of arbitrary bytes, valid until the next filesystem update.
FsResult open(scope const(char)[] name, out const(char)[] data, out FileVersion fileVersion)
{
    if (!mounted)
        return FsResult.unavailable;
    if (!validFilename(name) || name.length > diskNameBytes)
        return FsResult.invalidName;

    const slot = find(name);
    if (slot == fileLimit)
        return FsResult.notFound;
    const entry = &entries[slot];
    data = entry.payload[0 .. entry.fields.length];
    fileVersion = FileVersion(slot, entry.fields.sequence);
    return FsResult.ok;
}

/// If expected is provided, update only the specified generation. FileVersion.init allows creation only.
FsResult save(scope const(char)[] name, scope const(char)[] data,
              scope const(FileVersion)* expected = null)
{
    if (!mounted)
        return FsResult.unavailable;
    if (!validFilename(name) || name.length > diskNameBytes)
        return FsResult.invalidName;
    if (data.length > volumeFileBytes)
        return FsResult.tooLarge;

    auto slot = find(name);
    if (expected !is null
        && (slot != expected.slot
            || (slot != fileLimit && entries[slot].fields.sequence != expected.sequence)))
        return FsResult.conflict;

    if (slot == fileLimit)
    {
        foreach (candidate, ref entry; entries[0 .. volumeSlots])
            if (entry.fields.name[0] == 0)
            {
                slot = candidate;
                break;
            }
        if (slot == fileLimit)
            return FsResult.full;
    }

    Metadata next;
    next.length = cast(uint) data.length;
    foreach (i, char c; name)
        next.name[i] = c;
    return commit(slot, next, data);
}

FsResult remove(scope const(char)[] name)
{
    if (!mounted)
        return FsResult.unavailable;
    if (!validFilename(name) || name.length > diskNameBytes)
        return FsResult.invalidName;
    const slot = find(name);
    if (slot == fileLimit)
        return FsResult.notFound;

    // Store a new generation without a name to record deletion.
    Metadata removed;
    return commit(slot, removed, null);
}

private FsResult commit(size_t slot, ref Metadata next, scope const(char)[] data)
{
    auto entry = &entries[slot];
    next.sequence = entry.fields.sequence + 1;
    if (next.sequence == 0)
        next.sequence = 1;
    const secondCopy = !entry.secondCopy;
    if (!writeCopy(copyLba(slot, secondCopy), next, data))
    {
        mounted = false;
        ++changes;
        return FsResult.ioError;
    }
    entry.fields = next;
    entry.secondCopy = secondCopy;
    foreach (i, char c; data)
        entry.payload[i] = c;
    ++changes;
    return FsResult.ok;
}

private bool writeCopy(uint lba, ref Metadata fields, scope const(char)[] data)
{
    size_t written;
    uint sectorLba = lba;
    while (written < data.length)
    {
        Sector sector = 0;
        auto bytes = cast(char*) sector.ptr;
        const count = sectorLength(data.length - written);
        foreach (i; 0 .. count)
            bytes[i] = data[written + i];
        if (!writeSector(++sectorLba, sector))
            return false;
        written += count;
    }

    // The ATA driver flushes each write. Commit metadata only after all file data is written.
    HeaderSector header = void;
    header.raw[] = 0;
    fields.checksum = checksum(fields, data);
    header.fields = fields;
    return writeSector(lba, header.raw);
}

private uint copyLba(size_t slot, bool secondCopy)
{
    return recordsLba + cast(uint) (slot * 2 + secondCopy) * sectorsPerCopy;
}

private size_t sectorLength(size_t remaining)
{
    return remaining < sectorBytes ? remaining : sectorBytes;
}

private size_t find(scope const(char)[] name)
{
    foreach (slot, ref entry; entries[0 .. volumeSlots])
        if (equal(filename(entry.fields), name))
            return slot;
    return fileLimit;
}

private const(char)[] filename(return scope ref const Metadata fields)
{
    size_t length;
    while (length < fields.name.length && fields.name[length] != 0)
        ++length;
    return fields.name[0 .. length];
}

private bool validMetadata(ref const Metadata fields, size_t limit)
{
    if (fields.sequence == 0 || fields.length > limit)
        return false;
    const name = filename(fields);
    return name.length == 0 ? fields.length == 0 : validFilename(name);
}

private bool isBlank(ref const Sector sector)
{
    foreach (word; sector)
        if (word != 0)
            return false;
    return true;
}

private bool isNewer(uint candidate, uint other)
{
    return cast(int) (candidate - other) > 0;
}

private uint checksum(ref const Metadata fields, scope const(char)[] payload)
{
    enum offset = Metadata.checksum.offsetof;
    const bytes = (cast(const(char)*) &fields)[0 .. Metadata.sizeof];
    return hashBytes(hashBytes(hashBytes(hashSeed, bytes[0 .. offset]),
        bytes[offset + uint.sizeof .. $]), payload);
}

private uint hashBytes(uint hash, scope const(char)[] bytes)
{
    foreach (char value; bytes)
        hash = (hash ^ cast(ubyte) value) * 16777619;
    return hash;
}

private bool equal(scope const(char)[] left, scope const(char)[] right)
{
    if (left.length != right.length)
        return false;
    foreach (i, c; left)
        if (c != right[i])
            return false;
    return true;
}

private bool readSector(uint lba, out Sector sector)
{
    return disk.read(lba, sector);
}

private bool writeSector(uint lba, ref const Sector sector)
{
    return disk.write(lba, sector);
}
