/// DlangFSはルート直下のテキストファイルを専用ATAディスクに保存する。
/// mountで2世代分のレコードを検査し、save/removeは古い方に書いてから公開する。
module filesystem;

import ata : Sector, initDisk, readSector, sectorBytes, writeSector;

enum fileLimit = 16;
enum maxNameBytes = 24;
enum maxTextBytes = 478;

enum FsResult { ok, unavailable, notFound, invalidName, invalidText, tooLarge, full, ioError, conflict }

struct FileVersion
{
    size_t slot = fileLimit;
    uint sequence;
}

private struct Record
{
    uint sequence;
    uint checksum;
    ushort textLength;
    char[maxNameBytes] name = 0;
    char[maxTextBytes] text = 0;
}

private union DiskRecord
{
    Record file;
    Sector sector;
}

private struct Entry
{
    Record file;
    bool secondCopy;
}

static assert(Record.sizeof == sectorBytes && Record.text.offsetof == 34);
private enum magic = "DLANGFS1";
private __gshared Entry[fileLimit] entries;
private __gshared bool mounted;
private __gshared ulong changes;

nothrow @nogc:

bool mount()
{
    Sector header;
    if (!initDisk() || !readSector(0, header))
        return false;
    const bytes = (cast(const(char)*) header.ptr)[0 .. magic.length];
    if (!equal(bytes, magic))
        return false;

    foreach (slot, ref entry; entries)
    {
        DiskRecord first = void;
        DiskRecord second = void;
        if (!readSector(recordLba(slot, false), first.sector)
            || !readSector(recordLba(slot, true), second.sector))
            return false;

        const firstValid = valid(first.file);
        const secondValid = valid(second.file);
        if (secondValid && (!firstValid || isNewer(second.file.sequence, first.file.sequence)))
            entry = Entry(second.file, true);
        else if (firstValid)
            entry = Entry(first.file, false);
        else if (!isBlank(first.sector) && !isBlank(second.sector))
            return false;
    }
    mounted = true;
    return true;
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
    if (!mounted || slot >= fileLimit)
        return null;
    return filename(entries[slot].file);
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

/// textは次にファイルシステムを更新するまで有効な読み取り専用ビュー。
FsResult open(scope const(char)[] name, out const(char)[] text, out FileVersion fileVersion)
{
    if (!mounted)
        return FsResult.unavailable;
    if (!validFilename(name))
        return FsResult.invalidName;

    const slot = find(name);
    if (slot == fileLimit)
        return FsResult.notFound;
    const record = &entries[slot].file;
    text = record.text[0 .. record.textLength];
    fileVersion = FileVersion(slot, record.sequence);
    return FsResult.ok;
}

/// expectedがある場合は、GUIで開いたときの世代と一致するファイルだけを更新する。
/// FileVersion.initを指定すると、同名ファイルが存在しない場合だけ新規保存する。
FsResult save(scope const(char)[] name, scope const(char)[] text,
              scope const(FileVersion)* expected = null)
{
    if (!mounted)
        return FsResult.unavailable;
    if (!validFilename(name))
        return FsResult.invalidName;
    if (text.length > maxTextBytes)
        return FsResult.tooLarge;
    if (!validText(text))
        return FsResult.invalidText;

    auto slot = find(name);
    if (expected !is null
        && (slot != expected.slot
            || (slot != fileLimit && entries[slot].file.sequence != expected.sequence)))
        return FsResult.conflict;

    if (slot == fileLimit)
    {
        foreach (candidate, ref entry; entries)
            if (entry.file.name[0] == 0)
            {
                slot = candidate;
                break;
            }
        if (slot == fileLimit)
            return FsResult.full;
    }

    DiskRecord next = void;
    // charの既定値は0xff。ディスク形式では名前の終端を0にする。
    next.sector[] = 0;
    next.file.textLength = cast(ushort) text.length;
    foreach (i, char c; name)
        next.file.name[i] = c;
    foreach (i, char c; text)
        next.file.text[i] = c;
    return commit(slot, next);
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

    // 空の名前と0バイトの内容を持つ新しい世代を削除記録として保存する。
    DiskRecord next = void;
    next.sector[] = 0;
    return commit(slot, next);
}

private FsResult commit(size_t slot, ref DiskRecord next)
{
    auto entry = &entries[slot];
    next.file.sequence = entry.file.sequence + 1;
    if (next.file.sequence == 0)
        next.file.sequence = 1;
    next.file.checksum = checksum(next.file);
    const secondCopy = !entry.secondCopy;
    if (!writeSector(recordLba(slot, secondCopy), next.sector))
    {
        // 成否が不明な世代の上に書き込むのを避ける。再起動時にディスクを再検査する。
        mounted = false;
        ++changes;
        return FsResult.ioError;
    }
    *entry = Entry(next.file, secondCopy);
    ++changes;
    return FsResult.ok;
}

private uint recordLba(size_t slot, bool secondCopy)
{
    return cast(uint) (1 + 2 * slot + secondCopy);
}

private size_t find(scope const(char)[] name)
{
    foreach (slot, ref entry; entries)
        if (equal(filename(entry.file), name))
            return slot;
    return fileLimit;
}

private const(char)[] filename(return scope ref const Record record)
{
    size_t length;
    while (length < record.name.length && record.name[length] != 0)
        ++length;
    return record.name[0 .. length];
}

private bool valid(ref const Record record)
{
    if (record.sequence == 0 || record.textLength > maxTextBytes
        || record.checksum != checksum(record))
        return false;
    const name = filename(record);
    if (name.length == 0)
        return record.textLength == 0;
    return validFilename(name) && validText(record.text[0 .. record.textLength]);
}

private bool validText(scope const(char)[] text)
{
    foreach (char c; text)
        if (c != '\n' && (c < ' ' || c > '~'))
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

private uint checksum(ref const Record record)
{
    enum offset = Record.checksum.offsetof;
    const bytes = (cast(const(ubyte)*) &record)[0 .. Record.sizeof];
    uint hash = 2166136261;
    foreach (i, byteValue; bytes)
    {
        if (i < offset || i >= offset + uint.sizeof)
            hash = (hash ^ byteValue) * 16777619;
    }
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
        case FsResult.invalidText: return "Only printable ASCII and LF can be saved.";
        case FsResult.tooLarge: return "File is limited to 478 bytes.";
        case FsResult.full: return "Data disk has 16 files and is full.";
        case FsResult.ioError: return "Disk write failed. Restart to remount.";
        case FsResult.conflict: return "File changed or exists. Use Save As.";
    }
}
