/* Exercise the actual x86-64 C calling convention from D, without host libc headers. */
typedef struct { long value; void *pointer; } AbiPair;
AbiPair abi_pair(long value, unsigned long mask, void *pointer)
{
    AbiPair result = { (long)((unsigned long)value ^ mask), pointer };
    return result;
}
unsigned long abi_widths(void)
{
    return sizeof(long) | (sizeof(void *) << 8) | (sizeof(__WCHAR_TYPE__) << 16);
}
long abi_callback(long (*callback)(long), long value)
{
    return callback(value) + 5;
}
