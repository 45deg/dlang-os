/// LDCが配列と構造体のコピー・初期化・比較に使うメモリ関数をDで提供する。
module runtime;

import core.volatile : volatileLoad, volatileStore;

extern(C) nothrow @nogc:

void* memcpy(void* destination, const(void)* source, size_t count)
{
    auto output = cast(ubyte*) destination;
    auto input = cast(const(ubyte)*) source;
    // LLVMがこの実装自体をmemcpy呼び出しに置き換えないようにする。
    foreach (i; 0 .. count)
        volatileStore(output + i, input[i]);
    return destination;
}

void* memset(void* destination, int value, size_t count)
{
    auto output = cast(ubyte*) destination;
    foreach (i; 0 .. count)
        volatileStore(output + i, cast(ubyte) value);
    return destination;
}

int memcmp(const(void)* left, const(void)* right, size_t count)
{
    auto a = cast(const(ubyte)*) left;
    auto b = cast(const(ubyte)*) right;
    foreach (i; 0 .. count)
    {
        const difference = cast(int) a[i] - cast(int) b[i];
        if (difference != 0)
            return difference;
    }
    return 0;
}
