/* Static druntime ELF: registration, initialized/zero TLS, and SjLj exception tables. */
OUTPUT_FORMAT(elf64-x86-64)
ENTRY(appMain)

PHDRS
{
    code PT_LOAD FILEHDR PHDRS FLAGS(5);
    data PT_LOAD FLAGS(6);
    tls PT_TLS FLAGS(4);
}

SECTIONS
{
    /* Put the headers in the first page so alignment gaps do not waste space in the file. */
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
    .tdata ALIGN(0x1000) : {
        __tls_start = .;
        *(.tdata .tdata.*)
    } :data :tls
    .tbss : { *(.tbss .tbss.*) } :data :tls
    __tls_size = ALIGN(ADDR(.tbss) + SIZEOF(.tbss) - ADDR(.tdata), MAX(ALIGNOF(.tdata), ALIGNOF(.tbss)));
    .bss ALIGN(0x1000) : { *(.bss .bss.*) *(COMMON) } :data
    /DISCARD/ : { *(.eh_frame*) *(.note*) }
}
