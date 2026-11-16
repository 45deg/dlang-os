/// DlangOS LP64 C declarations. Implemented functions live in libc.d; other declarations remain link errors.
/// This is a freestanding ABI, not a claim of POSIX or a complete C library.
module dlangos.cabi;

public import core.stdc.config : c_long, c_ulong;
public import core.stdc.stdarg : va_list;
alias int8_t = byte; alias uint8_t = ubyte;
alias int16_t = short; alias uint16_t = ushort;
alias int32_t = int; alias uint32_t = uint;
alias int64_t = long; alias uint64_t = ulong;
alias intptr_t = long; alias uintptr_t = ulong;
alias intmax_t = long; alias uintmax_t = ulong;
alias time_t = long; alias clock_t = long;
alias wint_t = uint; alias wctype_t = ulong; alias wctrans_t = ulong;
alias sig_atomic_t = int;
struct tm { int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst; }
struct timespec { time_t tv_sec; c_long tv_nsec; }
struct mbstate_t { uint state; uint value; }
struct FILE { int descriptor; }
alias fpos_t = long;
enum EOF = -1, EXIT_SUCCESS = 0, EXIT_FAILURE = 1;
enum CLOCKS_PER_SEC = 1_000_000;
enum WEOF = uint.max;
enum ERANGE = 34, EINVAL = 22, ENOMEM = 12, ENOSYS = 38;
extern(C) extern __gshared FILE* stdout, stderr, stdin;
extern(C) nothrow @nogc:
void* malloc(size_t);
void* calloc(size_t, size_t);
void* realloc(void*, size_t);
void free(void*);
noreturn abort() @safe;
void exit(int);
int atexit(void function());
char* getenv(const(char)*);
int atoi(const(char)*);
c_long strtol(const(char)*, char**, int);
c_ulong strtoul(const(char)*, char**, int);
long strtoll(const(char)*, char**, int);
ulong strtoull(const(char)*, char**, int);
int fprintf(FILE*, const(char)*, ...);
int printf(const(char)*, ...);
int snprintf(char*, size_t, const(char)*, ...);
int vsnprintf(char*, size_t, const(char)*, va_list);
size_t fwrite(const(void)*, size_t, size_t, FILE*);
int fputs(const(char)*, FILE*);
int fputc(int, FILE*);
int fflush(FILE*);
int fclose(FILE*);
FILE* fopen(const(char)*, const(char)*);
size_t fread(void*, size_t, size_t, FILE*);
int ferror(FILE*);
int feof(FILE*);
int fseek(FILE*, c_long, int);
c_long ftell(FILE*);
int remove(const(char)*);
int rename(const(char)*, const(char)*);
int* __errno_location();
ref int errno();

time_t time(time_t*);
pragma(LDC_alloca) void* alloca(size_t) pure;

extern(C) int sscanf(const(char)*, const(char)*, ...) nothrow @nogc;
