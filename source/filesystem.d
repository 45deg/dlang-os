/// DlangFSの固定スロットと2世代保存。mountは旧形式を検査して新領域へ移す。
/// commitは本文を先に書き、世代番号とチェックサムを最後に公開する。
module filesystem;

import ata : Sector, initDisk, readSector, sectorBytes, writeSector;

enum fileLimit = 16;
enum maxNameBytes = 24;
enum maxFileBytes = 16 * 1024;

enum FsResult { ok, unavailable, notFound, invalidName, tooLarge, full, ioError, conflict }

struct FileVersion
{
    size_t slot = fileLimit;
    uint sequence;
}

private struct Metadata
{
    align(1):
    uint sequence;
    uint checksum;
    ushort length;
    char[maxNameBytes] name = 0;
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
private enum uint migrationMarkerLba = 1 + fileLimit * 2;
private enum uint recordsLba = migrationMarkerLba + 1;
private enum uint sectorsPerCopy = 1 + maxFileBytes / sectorBytes;
private enum uint lastLba = recordsLba + fileLimit * 2 * sectorsPerCopy - 1;
private enum uint hashSeed = 2166136261;

private __gshared Entry[fileLimit] entries;
private __gshared char[maxFileBytes] scratch = void;
private __gshared bool mounted;
private __gshared ulong changes;

nothrow @nogc:

bool mount()
{
    Sector header, last;
    if (!initDisk() || !readSector(0, header) || !readSector(lastLba, last))
        return false;
    if (hasMagic(header, currentMagic))
        mounted = loadCurrent();
    else if (hasMagic(header, legacyMagic))
    {
        Sector marker;
        if (!readSector(migrationMarkerLba, marker))
            return false;
        if (hasMagic(marker, currentMagic))
            mounted = loadCurrent();
        else if (isBlank(marker))
            mounted = loadLegacy() && migrateLegacy();
    }
    return mounted;
}

private bool loadCurrent()
{
    foreach (slot, ref entry; entries)
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
    if (!validMetadata(fields, maxFileBytes))
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
    // 先にすべての旧レコードを検査する。破損を見つけた場合はディスクに一切書かない。
    foreach (slot, ref entry; entries)
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
    // v1のチェックサムは使用済み本文だけでなく、旧レコードの末尾までを含む。
    return old.fields.checksum == checksum(old.fields, old.payload[])
        && isText(old.payload[0 .. old.fields.length]);
}

private bool migrateLegacy()
{
    const Sector blank = 0;
    foreach (slot, ref entry; entries)
    {
        // 移行途中で停止していた場合も、旧形式を正本として新領域を作り直す。
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
    // このセクタが永続化するまで、v1のヘッダと本文が起動時の正本。
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
    return mounted && slot < fileLimit ? filename(entries[slot].fields) : null;
}

bool validFilename(scope const(char)[] name)
{
    if (name.length == 0 || name.length > maxNameBytes || name[0] == '.')
        return false;
    foreach (char c; name)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
              || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.'))
            return false;
    return true;
}

bool isText(scope const(char)[] data)
{
    foreach (char c; data)
        if (c != '\n' && (c < ' ' || c > '~'))
            return false;
    return true;
}

/// dataは次のファイルシステム更新まで有効な、任意のバイト列のビュー。
FsResult open(scope const(char)[] name, out const(char)[] data, out FileVersion fileVersion)
{
    if (!mounted)
        return FsResult.unavailable;
    if (!validFilename(name))
        return FsResult.invalidName;

    const slot = find(name);
    if (slot == fileLimit)
        return FsResult.notFound;
    const entry = &entries[slot];
    data = entry.payload[0 .. entry.fields.length];
    fileVersion = FileVersion(slot, entry.fields.sequence);
    return FsResult.ok;
}

/// expectedがある場合は指定した世代だけを更新する。FileVersion.initは新規作成のみ。
FsResult save(scope const(char)[] name, scope const(char)[] data,
              scope const(FileVersion)* expected = null)
{
    if (!mounted)
        return FsResult.unavailable;
    if (!validFilename(name))
        return FsResult.invalidName;
    if (data.length > maxFileBytes)
        return FsResult.tooLarge;

    auto slot = find(name);
    if (expected !is null
        && (slot != expected.slot
            || (slot != fileLimit && entries[slot].fields.sequence != expected.sequence)))
        return FsResult.conflict;

    if (slot == fileLimit)
    {
        foreach (candidate, ref entry; entries)
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
    if (!validFilename(name))
        return FsResult.invalidName;
    const slot = find(name);
    if (slot == fileLimit)
        return FsResult.notFound;

    // 名前のない新しい世代を、削除の記録として保存する。
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

    // ATAドライバは各書き込みをフラッシュする。本文が揃ってからメタデータを確定する。
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
    foreach (slot, ref entry; entries)
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

const(char)[] errorText(FsResult result)
{
    final switch (result)
    {
        case FsResult.ok: return "Saved.";
        case FsResult.unavailable: return "Data disk unavailable.";
        case FsResult.notFound: return "File not found.";
        case FsResult.invalidName: return "Use 1-24 letters, digits, dots, _ or - (no leading dot).";
        case FsResult.tooLarge: return "File is limited to 16384 bytes.";
        case FsResult.full: return "Data disk has 16 files and is full.";
        case FsResult.ioError: return "Disk write failed. Restart to remount.";
        case FsResult.conflict: return "File changed or exists. Use Save As.";
    }
}
