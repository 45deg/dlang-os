/// 10進の数値を呼び出し元が用意したバッファへ書く。ランタイムの文字列生成は使わない。
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
