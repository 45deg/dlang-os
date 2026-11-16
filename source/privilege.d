/// Set up the GDT, TSS, and IDT. enterUser returns with saved Ring 3 state. waitForInterrupt resumes from Ring 0 HLT.
module privilege;

import cpu : readMsr, writeMsr, writePort;
import serial : serialReceiveInterrupt;
import ldc.llvmasm : __asm;

enum ubyte timerVector = 0x40;
enum ubyte syscallVector = 0x80;
private enum ubyte spuriousVector = 0xff;
private enum ushort kernelCode = 0x08;
enum ushort userData = 0x1b;
enum ushort userCode = 0x23;

// Match register order to enterUser and processTrap push/pop sequences and the CPU return frame.
struct UserFrame
{
    ulong r15, r14, r13, r12, r11, r10, r9, r8;
    ulong rdi, rsi, rbp, rbx, rdx, rcx, rax;
    ulong vector, error, rip, cs, flags, rsp, ss;
}

static assert(UserFrame.sizeof == 22 * ulong.sizeof);
static assert(UserFrame.cs.offsetof == 144);

private struct TablePointer
{
    align(1):
    ushort limit;
    ulong base;
}

private struct Gate
{
    ushort lowOffset;
    ushort selector;
    ubyte stackIndex;
    ubyte attributes;
    ushort midOffset;
    uint highOffset;
    uint reserved;
}

static assert(TablePointer.sizeof == 10 && Gate.sizeof == 16);

private __gshared ulong[7] gdt;
private __gshared Gate[256] idt;
align(16) private __gshared ubyte[104] tss;
align(16) private __gshared ubyte[8192] trapStack;

extern(C) private __gshared ubyte idleTimerDelivered;
extern(C) private __gshared ulong resumeKernelStack, resumeKernelCr3;
extern(C) private __gshared UserFrame* runningFrame;

nothrow @nogc:

void initPrivilege()
{
    // Remap the PIC to 0x20/0x28 to avoid CPU exception vectors and enable only UART IRQ4.
    writePort(0x20, 0x11);
    writePort(0xa0, 0x11);
    writePort(0x21, 0x20);
    writePort(0xa1, 0x28);
    writePort(0x21, 4);
    writePort(0xa1, 2);
    writePort(0x21, 1);
    writePort(0xa1, 1);
    writePort(0x21, 0xef);
    writePort(0xa1, 0xff);

    gdt[1] = 0x00af9a000000ffff; // Ring 0, 64-bit code.
    gdt[2] = 0x00cf92000000ffff; // Ring 0, data.
    gdt[3] = 0x00cff2000000ffff; // Ring 3, data.
    gdt[4] = 0x00affa000000ffff; // Ring 3, 64-bit code.
    const tssAddress = cast(ulong) tss.ptr;
    gdt[5] = cast(ulong) (tss.length - 1) | ((tssAddress & 0xffffff) << 16)
        | (0x89UL << 40) | ((tssAddress & 0xff000000) << 32);
    gdt[6] = tssAddress >> 32;
    *cast(ulong*) (tss.ptr + 4) = cast(ulong) (trapStack.ptr + trapStack.length); // RSP0
    *cast(ushort*) (tss.ptr + 102) = cast(ushort) tss.length; // No I/O permission bitmap.

    const gdtr = TablePointer(cast(ushort) (gdt.sizeof - 1), cast(ulong) gdt.ptr);
    loadGdt(&gdtr);

    static foreach (vector; 0 .. 32)
        setGate(vector, &trap!vector);
    setGate(0x24, &serialInterruptEntry);
    setGate(0x27, &ignoreSpurious); // A spurious PIC IRQ7 needs no EOI.
    setGate(timerVector, &trap!timerVector);
    setGate(syscallVector, &trap!syscallVector, 0xee); // Entry callable through INT from Ring 3.
    setGate(spuriousVector, &ignoreSpurious);
    const idtr = TablePointer(cast(ushort) (idt.sizeof - 1), cast(ulong) idt.ptr);
    __asm("lidtq ($0)", "r,~{memory}", &idtr);

    // INT 0x80 is the only syscall entry. Task SIMD and FPU state is unmanaged.
    writeMsr(0xc0000080, (readMsr(0xc0000080) | (1UL << 11)) & ~1UL); // NXE=1, SCE=0
    writeMsr(0x174, 0); // SYSENTER_CS
    __asm("movq %cr0, %rax; orq $$8, %rax; movq %rax, %cr0",
        "~{rax},~{flags},~{memory}");
}

private void setGate(uint vector, void function() nothrow @nogc handler, ubyte attributes = 0x8e)
{
    const address = cast(ulong) handler;
    idt[vector] = Gate(cast(ushort) address, kernelCode, 0, attributes,
        cast(ushort) (address >> 16), cast(uint) (address >> 32), 0);
}

private void loadGdt(const TablePointer*)
{
    asm @nogc nothrow { naked; }
    __asm(q{
        lgdtq (%rdi)
        pushq $$0x08
        leaq 1f(%rip), %rax
        pushq %rax
        lretq
    1:
        movw $$0x10, %ax
        movw %ax, %ss
        movw %ax, %ds
        movw %ax, %es
        movw $$0x28, %ax
        ltrw %ax
        retq
    }, "~{memory}");
}

/// System V ABI. Save the scheduler stack and restore user state, including RIP and RSP.
extern(C) void enterUser(UserFrame*, ulong, ulong)
{
    asm @nogc nothrow { naked; }
    __asm(q{
        pushq %rbp
        pushq %rbx
        pushq %r12
        pushq %r13
        pushq %r14
        pushq %r15
        movq %rsp, resumeKernelStack(%rip)
        movq %rdx, resumeKernelCr3(%rip)
        movq %rdi, runningFrame(%rip)
        movq %rsi, %cr3
        movq %rdi, %rsp
        popq %r15
        popq %r14
        popq %r13
        popq %r12
        popq %r11
        popq %r10
        popq %r9
        popq %r8
        popq %rdi
        popq %rsi
        popq %rbp
        popq %rbx
        popq %rdx
        popq %rcx
        popq %rax
        addq $$16, %rsp
        iretq
    }, "~{memory}");
}

private void trap(uint vector)()
{
    asm @nogc nothrow { naked; }
    static if (vector == timerVector)
        __asm(q{
            testb $$3, 8(%rsp)
            jnz 1f
            movb $$1, idleTimerDelivered(%rip)
            iretq
        1:
            pushq $$0
            pushq $$} ~ vector.stringof ~ q{
            jmp processTrap
        }, "~{memory}");
    else static if (vector == 8 || (vector >= 10 && vector <= 14) || vector == 17
               || vector == 21 || vector == 29 || vector == 30)
        __asm("pushq $$" ~ vector.stringof ~ "; jmp processTrap", "~{memory}");
    else
        __asm("pushq $$0; pushq $$" ~ vector.stringof ~ "; jmp processTrap", "~{memory}");
}

private void ignoreSpurious()
{
    asm @nogc nothrow { naked; }
    __asm("iretq", "~{memory}");
}

extern(C) private void processTrap()
{
    asm @nogc nothrow { naked; }
    __asm(q{
        pushq %rax
        pushq %rcx
        pushq %rdx
        pushq %rbx
        pushq %rbp
        pushq %rsi
        pushq %rdi
        pushq %r8
        pushq %r9
        pushq %r10
        pushq %r11
        pushq %r12
        pushq %r13
        pushq %r14
        pushq %r15
        cld
        testb $$3, 144(%rsp)
        jz 1f
        movq runningFrame(%rip), %rdi
        movq %rsp, %rsi
        movl $$22, %ecx
        rep movsq
        movq resumeKernelCr3(%rip), %rax
        movq %rax, %cr3
        movq resumeKernelStack(%rip), %rsp
        popq %r15
        popq %r14
        popq %r13
        popq %r12
        popq %rbx
        popq %rbp
        retq
    1:
        cli
        hlt
        jmp 1b
    }, "~{memory}");
}

/// Call with IF=0. HLT immediately follows STI so an interrupt cannot be lost between the idle check and halt.
bool waitForInterrupt()
{
    idleTimerDelivered = 0;
    __asm("sti; hlt; cli", "~{memory}");
    return idleTimerDelivered != 0;
}

// Preserve general-purpose registers and the stack layout because this can interrupt any user or idle context.
private void serialInterruptEntry()
{
    asm @nogc nothrow { naked; }
    __asm(q{
        pushq %rax
        pushq %rcx
        pushq %rdx
        pushq %rsi
        pushq %rdi
        pushq %r8
        pushq %r9
        pushq %r10
        pushq %r11
        pushq %rbx
        movq %rsp, %rbx
        andq $$-16, %rsp
        cld
        callq serialReceiveInterrupt
        movq %rbx, %rsp
        popq %rbx
        popq %r11
        popq %r10
        popq %r9
        popq %r8
        popq %rdi
        popq %rsi
        popq %rdx
        popq %rcx
        popq %rax
        iretq
    }, "~{memory}");
}
