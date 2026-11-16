/// Supply the freestanding C services needed by druntime startup: allocation, serial output, strings and errno.
/// malloc/free manage a process-local list; exit ends the process. Unsupported C APIs have no definitions.
module dlangos.libc;

import dlangos.cabi : FILE, EINVAL, ENOMEM;
import core.stdc.stdarg : va_list, va_start, va_end, va_arg;
import user_abi : Call, userHeapBase, userHeapLimitBytes, userHeapInitialBytes, callError;
import user_api : call, send, exitApp;
import runtime : memcpy, memset;

private struct Block { size_t size; Block* next; bool available; }
private enum headerBytes = (Block.sizeof + 15) & ~15;
private __gshared Block* first;
private __gshared size_t used, committed = userHeapInitialBytes;
private int errorNumber;
private __gshared FILE outputFile = FILE(1), errorFile = FILE(2), inputFile = FILE(0);
extern(C) __gshared FILE* stdout = &outputFile, stderr = &errorFile, stdin = &inputFile;

extern(C) nothrow @nogc:
int* __errno_location() { return &errorNumber; }
ref int errno() { return errorNumber; }

void* malloc(size_t size)
{
    if (size == 0) size = 1;
    if (size > userHeapLimitBytes - headerBytes - 15) { errorNumber = ENOMEM; return null; }
    size = (size + 15) & ~15UL;
    Block* last;
    for (auto block = first; block !is null; last = block, block = block.next)
    {
        if (!block.available || block.size < size) continue;
        if (block.size >= size + headerBytes + 16)
        {
            auto remainder = cast(Block*) (cast(ubyte*) block + headerBytes + size);
            *remainder = Block(block.size - size - headerBytes, block.next, true);
            block.size = size;
            block.next = remainder;
        }
        block.available = false;
        return cast(ubyte*) block + headerBytes;
    }
    if (used > userHeapLimitBytes - headerBytes - size) { errorNumber = ENOMEM; return null; }
    const required = used + headerBytes + size;
    if (required > committed)
    {
        const actual = call(Call.heapResize, required);
        if (actual == callError) { errorNumber = ENOMEM; return null; }
        committed = actual;
    }
    auto block = cast(Block*) (userHeapBase + used);
    *block = Block(size, null, false);
    if (last is null) first = block; else last.next = block;
    used = required;
    return cast(ubyte*) block + headerBytes;
}

void free(void* pointer)
{
    if (pointer is null) return;
    auto block = cast(Block*) (cast(ubyte*) pointer - headerBytes);
    block.available = true;
    for (auto current = first; current !is null;)
    {
        if (current.available && current.next !is null && current.next.available)
        {
            current.size += headerBytes + current.next.size;
            current.next = current.next.next;
        }
        else current = current.next;
    }
}

void* realloc(void* pointer, size_t size)
{
    if (pointer is null) return malloc(size);
    if (size == 0) { free(pointer); return null; }
    auto block = cast(Block*) (cast(ubyte*) pointer - headerBytes);
    if (block.size >= size) return pointer;
    auto replacement = malloc(size);
    if (replacement is null) return null;
    memcpy(replacement, pointer, block.size);
    free(pointer);
    return replacement;
}

void* calloc(size_t count, size_t size)
{
    if (size && count > size_t.max / size) { errorNumber = ENOMEM; return null; }
    auto pointer = malloc(count * size);
    if (pointer !is null) memset(pointer, 0, count * size);
    return pointer;
}

noreturn abort() { send(Call.write, "D runtime aborted.\n"); exitApp(); }
noreturn exit(int status) { call(Call.publish, cast(uint) status); exitApp(); }
char* getenv(const(char)* name) { return null; } // This OS has no environment entries.
size_t strlen(const(char)* text) { size_t n; while (text[n]) ++n; return n; }
int strcmp(const(char)* a, const(char)* b)
{
    while (*a && *a == *b) { ++a; ++b; }
    return cast(ubyte)*a - cast(ubyte)*b;
}
int toupper(int c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
int isspace(int c) { return c == ' ' || (c >= 9 && c <= 13); }
int isdigit(int c) { return c >= '0' && c <= '9'; }
char* strerror(int code) { return cast(char*) "DlangOS C service error"; }
int fflush(FILE* stream)
{
    if (stream is null || stream is stdout || stream is stderr) return 0; // Serial writes are synchronous.
    errorNumber = EINVAL; return -1;
}
size_t fwrite(const(void)* data, size_t size, size_t count, FILE* stream)
{
    if (size == 0 || count == 0) return 0;
    if ((stream !is stdout && stream !is stderr) || count > size_t.max / size)
    { errorNumber = EINVAL; return 0; }
    auto bytes = cast(const(char)*) data;
    const length = size * count;
    size_t sent;
    while (sent < length)
    {
        const n = length - sent < 128 ? length - sent : 128;
        if (send(Call.write, bytes[sent .. sent + n]) == callError) return sent / size;
        sent += n;
    }
    return count;
}
int fputs(const(char)* text, FILE* stream)
{
    const length = strlen(text);
    return fwrite(text, 1, length, stream) == length ? 0 : -1;
}
int fprintf(FILE* stream, const(char)* format, ...)
{
    va_list args;
    va_start(args, format);
    scope(exit) va_end(args);
    int count;
    while (*format)
    {
        if (*format != '%')
        {
            if (fwrite(format++, 1, 1, stream) != 1) return -1;
            ++count; continue;
        }
        ++format;
        int precision = -1;
        if (*format == '.' && format[1] == '*')
        { precision = va_arg!int(args); format += 2; }
        if (*format == 's')
        {
            auto value = va_arg!(const(char)*)(args);
            size_t length;
            while ((precision < 0 || length < precision) && value[length]) ++length;
            if (fwrite(value, 1, length, stream) != length) return -1;
            count += length;
        }
        else if (*format == '%')
        { if (fwrite(format, 1, 1, stream) != 1) return -1; ++count; }
        else if (*format == 'd' || *format == 'u')
        {
            import core.internal.string : signedToTempString, unsignedToTempString;
            char[32] buffer;
            auto text = *format == 'd' ? signedToTempString(va_arg!int(args), buffer[])
                                      : unsignedToTempString(va_arg!uint(args), buffer[]);
            if (fwrite(text.ptr, 1, text.length, stream) != text.length) return -1;
            count += text.length;
        }
        else { errorNumber = EINVAL; return -1; } // Unsupported formats must not pretend success.
        ++format;
    }
    return count;
}

noreturn onOutOfMemoryError(void*, string, size_t)
{
    send(Call.write, "D runtime allocation failed.\n");
    exitApp();
}
