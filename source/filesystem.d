/// Read the DlangFS layout from its header and retain two generations per file. Fixed layouts keep v1 and v2 readable.
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
    ushort length;
    char[diskNameBytes] name = 0;
}

private union HeaderSector
{
    Metadata fields;
    Sector raw;
}

private struct LegacyRecord
{
    Metadata fields;
    char[sectorBytes - Metadata.sizeof] payload;
}

private union LegacySector
{
    LegacyRecord record;
    Sector raw;
}

private struct Entry
{
    Metadata fields;
    bool secondCopy;
    char[maxFileBytes] payload = void;
}

private enum CopyStatus { blank, invalid, valid, ioError }

static assert(Metadata.sizeof == 34 && Metadata.checksum.offsetof == 4);
static assert(LegacyRecord.sizeof == sectorBytes && maxFileBytes % sectorBytes == 0);
private enum legacyMagic = "DLANGFS1";
private enum currentMagic = "DLANGFS2";
// Read existing v1 and v2 disks with their original layouts even if API limits change.
private enum uint oldFileSlots = 16;
private enum uint oldFileBytes = 16 * 1024;
private enum uint migrationMarkerLba = 33;
private enum uint oldRecordsLba = 34;
private enum uint oldSectorsPerCopy = 33;
private enum layoutMagic = "DLANGFS3";

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
private __gshared char[maxFileBytes] scratch = void;
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
        if (!equal(magic, legacyMagic) && !equal(magic, currentMagic) && !equal(magic, layoutMagic))
            continue;
        // Avoid choosing a write target by attachment order when several disks could contain DlangFS.
        if (found) return false;
        disk = candidate;
        header = first;
        found = true;
    }
    if (!found) return false;
    if (hasMagic(header, currentMagic) || hasMagic(header, legacyMagic))
    {
        volumeSlots = oldFileSlots;
        volumeFileBytes = oldFileBytes;
        recordsLba = oldRecordsLba;
        sectorsPerCopy = oldSectorsPerCopy;
    }
    else if (!readLayout(header))
        return false;
    // Use 64-bit arithmetic to check that the layout fits on the selected block device.
    const end = cast(ulong) recordsLba + cast(ulong) volumeSlots * 2 * sectorsPerCopy;
    if (volumeSlots == 0 || volumeSlots > fileLimit || volumeFileBytes == 0 || volumeFileBytes > maxFileBytes
        || volumeFileBytes > ushort.max || recordsLba == 0
        || sectorsPerCopy < 1 + (volumeFileBytes + sectorBytes - 1) / sectorBytes
        || end > disk.sectorCount || end > 0x1_0000_0000 || !readSector(cast(uint) (end - 1), last))
        return false;
    if (hasMagic(header, legacyMagic))
    {
        Sector marker;
        if (!readSector(migrationMarkerLba, marker))
            return false;
        if (hasMagic(marker, currentMagic))
            mounted = loadCurrent();
        else if (isBlank(marker))
            mounted = loadLegacy() && migrateLegacy();
    }
    else
        mounted = loadCurrent();
    return mounted;
}

private bool readLayout(ref const Sector raw)
{
    LayoutSector header;
    header.raw = raw;
    const bytes = (cast(const(char)*) raw.ptr)[0 .. sectorBytes];
    const fields = header.fields;
    if (!equal(fields.magic[], layoutMagic) || fields.versionNumber != 3
        || fields.sectorSize != sectorBytes || fields.metadataBytes != Metadata.sizeof
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

private bool loadCurrent()
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
        else if (a != CopyStatus.blank || b != CopyStatus.blank)
            return false;
    }
    return true;
}

private CopyStatus readCopy(uint lba, out Metadata fields, ref char[maxFileBytes] payload)
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

private bool loadLegacy()
{
    // Validate all legacy records first so corruption can be rejected before any disk write.
    foreach (slot, ref entry; entries[0 .. volumeSlots])
    {
        LegacySector first = void;
        LegacySector second = void;
        const lba = cast(uint) (1 + slot * 2);
        if (!readSector(lba, first.raw) || !readSector(lba + 1, second.raw))
            return false;

        const firstValid = validLegacy(first.record);
        const secondValid = validLegacy(second.record);
        if (secondValid && (!firstValid || isNewer(second.record.fields.sequence, first.record.fields.sequence)))
            copyLegacy(entry, second.record);
        else if (firstValid)
            copyLegacy(entry, first.record);
        else if (!isBlank(first.raw) || !isBlank(second.raw))
            return false;
    }
    return true;
}

private void copyLegacy(ref Entry entry, ref const LegacyRecord old)
{
    entry.fields = old.fields;
    foreach (i; 0 .. old.fields.length)
        entry.payload[i] = old.payload[i];
}

private bool validLegacy(ref const LegacyRecord old)
{
    if (!validMetadata(old.fields, old.payload.length))
        return false;
    // The v1 checksum covers the entire legacy record, including bytes beyond the used data.
    return old.fields.checksum == checksum(old.fields, old.payload[])
        && isText(old.payload[0 .. old.fields.length]);
}

private bool migrateLegacy()
{
    const Sector blank = 0;
    foreach (slot, ref entry; entries[0 .. volumeSlots])
    {
        // If migration stopped partway through, rebuild the new area from the original format.
        if (!writeSector(copyLba(slot, true), blank))
            return false;
        const lba = copyLba(slot, false);
        if (entry.fields.sequence == 0)
        {
            if (!writeSector(lba, blank))
                return false;
        }
        else if (!writeCopy(lba, entry.fields, entry.payload[0 .. entry.fields.length]))
            return false;
    }

    Sector marker = 0;
    auto bytes = cast(char*) marker.ptr;
    foreach (i, char c; currentMagic)
        bytes[i] = c;
    // Until this sector is durable, the v1 header and data remain authoritative at boot.
    return writeSector(migrationMarkerLba, marker);
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
    next.length = cast(ushort) data.length;
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

private bool hasMagic(ref const Sector sector, scope const(char)[] magic)
{
    const bytes = (cast(const(char)*) sector.ptr)[0 .. sectorBytes];
    if (!equal(bytes[0 .. magic.length], magic))
        return false;
    foreach (char c; bytes[magic.length .. $])
        if (c != 0)
            return false;
    return true;
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
