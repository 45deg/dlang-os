/// アプリとDlangFSで共有するファイルの上限、世代、結果と入力検証。
module file_api;

enum fileLimit = 16;
enum maxNameBytes = 24;
enum maxFileBytes = 16 * 1024;

enum FsResult { ok, unavailable, notFound, invalidName, tooLarge, full, ioError, conflict }

struct FileVersion
{
    align(1):
    size_t slot = fileLimit;
    uint sequence;
}

nothrow @nogc:

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

const(char)[] errorText(FsResult result)
{
    final switch (result)
    {
        case FsResult.ok: return "Saved.";
        case FsResult.unavailable: return "Data disk unavailable.";
        case FsResult.notFound: return "File not found.";
        case FsResult.invalidName: return "Use 1-24 letters, digits, dots, _ or - (no leading dot).";
        case FsResult.tooLarge: return "File exceeds the volume or application size limit.";
        case FsResult.full: return "Data disk is full.";
        case FsResult.ioError: return "Disk write failed. Restart to remount.";
        case FsResult.conflict: return "File changed or exists. Use Save As.";
    }
}
