/// Write decimal numbers into a caller-supplied buffer without runtime string construction.
module numbers;

const(char)[] decimalText(ulong value, return ref char[20] buffer) pure nothrow @nogc
{
    size_t first = buffer.length;
    do
    {
        buffer[--first] = cast(char) ('0' + value % 10);
        value /= 10;
    }
    while (value != 0);
    return buffer[first .. $];
}
