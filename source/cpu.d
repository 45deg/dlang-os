/// x86-64固有の命令。8・16ビットのI/Oポートアクセス、待機、CPUの停止をまとめる。
module cpu;

import ldc.llvmasm : __asm;

nothrow @nogc:

ubyte readPort(ushort port)
{
    return __asm!ubyte("inb $1, $0", "={al},{dx},~{memory}", port);
}

void writePort(ushort port, ubyte value)
{
    __asm("outb $0, $1", "{al},{dx},~{memory}", value, port);
}

noreturn haltCpu()
{
    __asm("cli", "~{memory}");
    while (true)
        __asm("hlt", "~{memory}");
}

ushort readPortWord(ushort port)
{
    return __asm!ushort("inw $1, $0", "={ax},{dx},~{memory}", port);
}

void writePortWord(ushort port, ushort value)
{
    __asm("outw $0, $1", "{ax},{dx},~{memory}", value, port);
}

void pauseCpu()
{
    __asm("pause", "~{memory}");
}

ulong ticks()
{
    return __asm!ulong("rdtsc; shlq $$32, %rdx; orq %rdx, %rax",
        "={rax},~{rdx},~{flags},~{memory}");
}

ulong readMsr(uint number)
{
    return __asm!ulong("rdmsr; shlq $$32, %rdx; orq %rdx, %rax",
        "={rax},{ecx},~{rdx},~{flags},~{memory}", number);
}

void writeMsr(uint number, ulong value)
{
    __asm("wrmsr", "{ecx},{eax},{edx},~{memory}", number, cast(uint) value, cast(uint) (value >> 32));
}

ulong readCr3()
{
    return __asm!ulong("movq %cr3, $0", "=r,~{memory}");
}

void writeCr3(ulong value)
{
    __asm("movq $0, %cr3", "r,~{memory}", value);
}
