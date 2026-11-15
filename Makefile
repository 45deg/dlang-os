# UEFIローダーとカーネルをESPに置き、appsでディスク用ELFをビルドする。
# runとrun-guiは別のデータディスクを接続し、testは使い捨てのディスクを使う。
LDC ?= $(firstword $(wildcard build/tools/ldc2-1.43.0-*/bin/ldc2) ldc2)
PHOBOS_IMPORT ?= $(abspath $(dir $(realpath $(shell command -v "$(LDC)")))/../import)
QEMU ?= qemu-system-x86_64
PYTHON ?= python3
# PATHのLLDを優先し、なければインストール済みのRust同梱LLDを使う。
LLD_LINK ?= $(or $(shell command -v lld-link),$(firstword $(wildcard $(shell rustc --print target-libdir 2>/dev/null)/../bin/gcc-ld/lld-link)),lld-link)
DATA_DISK ?= build/data.img
OVMF_CODE ?= $(firstword $(wildcard /opt/homebrew/share/qemu/edk2-x86_64-code.fd /usr/local/share/qemu/edk2-x86_64-code.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd))

# Retinaでもゲスト画面をウィンドウの大きさに合わせて拡大する。
ifeq ($(shell uname -s),Darwin)
QEMU_DISPLAY ?= cocoa,zoom-to-fit=on
endif

ESP := build/uefi-esp
KERNEL := $(ESP)/kernel.elf
BOOT_EFI := $(ESP)/EFI/BOOT/BOOTX64.EFI
SOURCES := $(wildcard source/*.d)
EFI_SOURCES := $(wildcard boot/*.d) source/boot_info.d source/cpu.d source/runtime.d source/serial.d
EFI_D_FLAGS := -mtriple=x86_64-pc-windows-msvc -betterC -O2 -checkaction=halt -Iboot -Isource
FONT_ATLASES := $(wildcard assets/fonts/*.coverage)
FONT_LICENSE := assets/fonts/OFL.txt
PHOBOS_APP_ELFS := build/apps/d_base64.elf build/apps/d_crc.elf build/apps/d_sha.elf
D_APP_ELFS := build/apps/d_init.elf build/apps/d_heap.elf build/apps/d_exception.elf build/apps/d_array.elf \
              $(PHOBOS_APP_ELFS)
APP_ELFS := build/apps/hello.elf build/apps/counter.elf $(D_APP_ELFS)
D_APP_RUNTIME := apps/d_start.d apps/runtime/object.d apps/runtime/d_allocation.d \
                 apps/user_api.d source/user_abi.d source/runtime.d
D_APP_UNWIND := build/apps/d_unwind.o

D_FLAGS := -mtriple=x86_64-unknown-none-elf -betterC -O2 -checkaction=halt \
           -relocation-model=static -code-model=kernel -disable-red-zone \
           -mattr=-mmx,-sse,-sse2 -Isource -Jassets/fonts -Jbuild/apps
APP_D_FLAGS := -mtriple=x86_64-unknown-none-elf -O2 -checkaction=halt \
               -relocation-model=static -disable-red-zone -mattr=-mmx,-sse,-sse2 -Isource -Iapps
FULL_D_FLAGS := $(APP_D_FLAGS) -Iapps/runtime -fno-moduleinfo-localclasses -exception-model=sjlj
APP_LINK_FLAGS := -link-internally -defaultlib= -L=-nostdlib -L=--gc-sections \
                  -L=--strip-all -L=-z -L=max-page-size=4096 -L=-T -L=apps/app.ld

QEMU_FLAGS = -machine pc,accel=tcg -m 128M -nic none -no-reboot \
             -drive "if=pflash,format=raw,readonly=on,file=$(OVMF_CODE)" \
             -drive "if=none,id=esp,format=raw,readonly=on,file=fat:$(abspath $(ESP))" \
             -device virtio-blk-pci,drive=esp,bootindex=1 \
             -monitor none -serial stdio
DATA_DRIVE = -drive "if=ide,index=0,format=raw,file=$(abspath $(DATA_DISK))"

.DELETE_ON_ERROR:
.PHONY: all apps run run-gui test check-ovmf

all: $(KERNEL) $(BOOT_EFI) $(ESP)/FONT-LICENSE.txt
apps: $(APP_ELFS)

# LDCの登録リストで依存元が先に来るように渡し、起動時の依存順を検証する。
build/apps/d_init.elf: apps/d_init.d apps/d_init_dependency.d
build/apps/d_heap.elf: apps/d_heap.d
build/apps/d_exception.elf: apps/d_exception.d
build/apps/d_array.elf: apps/d_array.d
build/apps/d_base64.elf: apps/d_base64.d build/apps/phobos/base64.o
build/apps/d_crc.elf: apps/d_crc.d build/apps/phobos/digest/crc.o build/apps/phobos/ascii.o
build/apps/d_sha.elf: apps/d_sha.d build/apps/phobos/digest/sha.o build/apps/phobos/ascii.o

$(PHOBOS_APP_ELFS): APP_IMPORT_FLAGS = -I"$(PHOBOS_IMPORT)"

$(D_APP_ELFS): $(D_APP_RUNTIME) $(D_APP_UNWIND) apps/app.ld Makefile
	mkdir -p "$(@D)"
	"$(LDC)" $(FULL_D_FLAGS) $(APP_IMPORT_FLAGS) $(APP_LINK_FLAGS) -L=--entry=main -of="$@" \
		$(filter-out $(D_APP_RUNTIME),$(filter %.d,$^)) $(D_APP_RUNTIME) $(filter %.o,$^)
	@test "$$(wc -c < "$@")" -le 16384 || { echo "App exceeds DlangFS file size limit." >&2; exit 1; }

# LDC同梱のPhobosソースを、アプリと同じターゲットのELFオブジェクトにする。
# SHAの展開済みコードを含めてもDlangFSの16 KiBに収まるよう、SHAはサイズ優先にする。
build/apps/phobos/digest/sha.o: FULL_D_FLAGS := $(filter-out -O2,$(FULL_D_FLAGS)) -Os

build/apps/phobos/%.o: $(PHOBOS_IMPORT)/std/%.d apps/runtime/object.d apps/runtime/d_allocation.d Makefile
	mkdir -p "$(@D)"
	"$(LDC)" $(FULL_D_FLAGS) -I"$(PHOBOS_IMPORT)" -c -of="$@" "$<"

# LLVMの最適化でアプリの例外エッジが消えないよう、アンワインダーを別オブジェクトにする。
$(D_APP_UNWIND): apps/runtime/d_unwind.d $(D_APP_RUNTIME) Makefile
	mkdir -p "$(@D)"
	"$(LDC)" $(FULL_D_FLAGS) -fno-moduleinfo -c -of="$@" "$<"

build/apps/%.elf: apps/%.d apps/user_api.d source/user_abi.d apps/app.ld Makefile
	mkdir -p "$(@D)"
	"$(LDC)" $(APP_D_FLAGS) $(APP_LINK_FLAGS) -betterC -of="$@" "$<" apps/user_api.d
	@test "$$(wc -c < "$@")" -le 16384 || { echo "App exceeds DlangFS file size limit." >&2; exit 1; }

$(KERNEL): build/kernel.elf
	mkdir -p "$(@D)"
	cp "$<" "$@"

build/kernel.elf: $(SOURCES) $(FONT_ATLASES) build/apps/counter.elf boot/kernel.ld Makefile
	mkdir -p "$(@D)"
	"$(LDC)" $(D_FLAGS) -link-internally -defaultlib= \
		-L=-nostdlib -L=--gc-sections -L=-z -L=max-page-size=4096 -L=-T -L=boot/kernel.ld -of="$@" $(SOURCES)

build/loader.obj: $(EFI_SOURCES) Makefile
	mkdir -p "$(@D)"
	"$(LDC)" $(EFI_D_FLAGS) -c -singleobj -of="$@" $(EFI_SOURCES)

$(BOOT_EFI): build/loader.obj Makefile
	mkdir -p "$(@D)"
	"$(LLD_LINK)" /nodefaultlib /entry:efiMain /subsystem:efi_application "/out:$@" "$<"

$(ESP)/FONT-LICENSE.txt: $(FONT_LICENSE)
	mkdir -p "$(@D)"
	cp "$<" "$@"

check-ovmf:
	@test -n "$(OVMF_CODE)" && test -r "$(OVMF_CODE)" || { \
		echo "Pass OVMF_CODE=/path/to/x86_64/OVMF_CODE.fd." >&2; exit 1; }

# 既存データはそのまま使い、ファイルがないときにだけ初期化する。
$(DATA_DISK):
	mkdir -p "$(@D)"
	@set -eu; temp=$$(mktemp "$@.XXXXXX"); trap 'rm -f "$$temp"' 0; \
		dd if=/dev/zero of="$$temp" bs=512 count=2048; \
		printf 'DLANGFS2' | dd of="$$temp" conv=notrunc; \
		ln "$$temp" "$@" || test -f "$@"

run: check-ovmf all $(DATA_DISK)
	"$(QEMU)" $(QEMU_FLAGS) $(DATA_DRIVE) -display none

run-gui: check-ovmf all $(DATA_DISK)
	"$(QEMU)" $(QEMU_FLAGS) $(DATA_DRIVE) $(if $(strip $(QEMU_DISPLAY)),-display "$(QEMU_DISPLAY)")

test: check-ovmf all apps
	"$(PYTHON)" tests/qemu_shell.py "$(QEMU)" $(QEMU_FLAGS) -display none
