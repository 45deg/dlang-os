/* UEFIローダーが読み込む上位アドレスのELF。コード、読み取り専用データ、
   書き込み可能なデータを別々のロードセグメントに置く。 */
OUTPUT_FORMAT(elf64-x86-64)
ENTRY(kernelMain)

PHDRS
{
    text     PT_LOAD FLAGS(5);
    rodata   PT_LOAD FLAGS(4);
    data     PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0xffffffff80000000;

    .text ALIGN(0x1000) : { *(.text .text.*) } :text
    .user_app ALIGN(0x1000) : {
        __user_app_start = .;
        KEEP(*(.user_app))
        __user_app_end = .;
    } :text

    ASSERT(SIZEOF(.user_app) > 0 && SIZEOF(.user_app) <= 0x1000, "User program must fit in one page")

    .rodata ALIGN(0x1000) : { *(.rodata .rodata.*) } :rodata
    .data ALIGN(0x1000) : { *(.data .data.*) *(.got .got.*) } :data
    .bss ALIGN(0x1000) : { *(.bss .bss.*) *(COMMON) } :data

    /DISCARD/ : { *(.eh_frame*) *(.note*) }
}
