/* Static ELF for DlangFS. Expose .init_array to d_start and the SjLj exception table bounds to d_unwind. */
OUTPUT_FORMAT(elf64-x86-64)
ENTRY(appMain)

PHDRS
{
    code PT_LOAD FILEHDR PHDRS FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    /* Put the headers in the first page so alignment gaps do not eat into the 16 KiB file limit. */
    . = 0x00400000 + SIZEOF_HEADERS;
    .text : { *(.text .text.*) *(.rodata .rodata.*) } :code
    .gcc_except_table : {
        PROVIDE_HIDDEN(__exception_table_start = .);
        *(.gcc_except_table .gcc_except_table.*)
        PROVIDE_HIDDEN(__exception_table_end = .);
    } :code
    . = ALIGN(0x1000);
    .data : { *(.data .data.*) *(.got .got.*) } :data
    .init_array : {
        PROVIDE_HIDDEN(__init_array_start = .);
        KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
        KEEP(*(.init_array))
        PROVIDE_HIDDEN(__init_array_end = .);
    } :data
    .bss ALIGN(0x1000) : { *(.bss .bss.*) *(COMMON) } :data
    /DISCARD/ : { *(.eh_frame*) *(.note*) }
}
