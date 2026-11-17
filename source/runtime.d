/// Implement the memory routines LDC uses to copy, initialize, and compare arrays and structs.
module runtime;

import ldc.llvmasm : __asm;

extern(C) nothrow @nogc:

// x86-64 ABI では DF はクリア済み。LLVM が memcpy や memset への自己呼び出しを生成しないよう命令を直接指定する。
void* memcpy(void* destination, const(void)* source, size_t count)
{
    // QEMU TCG での反復回数を抑えるため、8 バイトずつ転送してから残りをコピーする。
    __asm(q{
        rep movsq
        movq $3, %rcx
        rep movsb
    }, "{rdi},{rsi},{rcx},r,~{rdi},~{rsi},~{rcx},~{memory}",
        destination, source, count / ulong.sizeof, count % ulong.sizeof);
    return destination;
}

void* memset(void* destination, int value, size_t count)
{
    const pattern = cast(ubyte) value * 0x0101_0101_0101_0101UL;
    __asm(q{
        rep stosq
        movq $3, %rcx
        rep stosb
    }, "{rdi},{rax},{rcx},r,~{rdi},~{rcx},~{memory}",
        destination, pattern, count / ulong.sizeof, count % ulong.sizeof);
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
