/// Return the main thread's static TLS range from the linker bounds and x86-64 FS self pointer.
module dlangos.tls;
import ldc.llvmasm : __asm;
extern(C) extern __gshared ubyte __tls_size;
void[] mainTlsRange() nothrow @nogc
{
    auto self = __asm!(void*)("movq %fs:0, $0", "=r");
    const size = cast(size_t) &__tls_size;
    return (self - size)[0 .. size];
}
