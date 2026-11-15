# kernel.elfをリンクし、LimineとともにUEFI用ディレクトリへ置く。
# runとrun-guiは別のデータディスクを接続し、testは使い捨てのディスクを使う。
LDC ?= $(firstword $(wildcard build/tools/ldc2-1.43.0-*/bin/ldc2) ldc2)
QEMU ?= qemu-system-x86_64
PYTHON ?= python3
DATA_DISK ?= build/data.img
OVMF_CODE ?= $(firstword $(wildcard /opt/homebrew/share/qemu/edk2-x86_64-code.fd /usr/local/share/qemu/edk2-x86_64-code.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd))

LIMINE_VERSION := 12.10.0
LIMINE_SHA256 := 365ba8785d4e4b55c3368738a642681b31f606afec9f77179e07fc26ebe841e2
LIMINE_ARCHIVE := build/downloads/limine-$(LIMINE_VERSION).tar.gz
ESP := build/esp
KERNEL := $(ESP)/kernel.elf
BOOT_EFI := $(ESP)/EFI/BOOT/BOOTX64.EFI
SOURCES := $(wildcard source/*.d)
FONT_ATLASES := $(wildcard assets/fonts/*.coverage)
FONT_LICENSE := assets/fonts/OFL.txt

D_FLAGS := -mtriple=x86_64-unknown-none-elf -betterC -O2 -checkaction=halt \
           -relocation-model=static -code-model=kernel -disable-red-zone \
           -mattr=-mmx,-sse,-sse2 -Isource -Jassets/fonts

QEMU_FLAGS = -machine pc,accel=tcg -m 128M -nic none -no-reboot \
             -drive "if=pflash,format=raw,readonly=on,file=$(OVMF_CODE)" \
             -drive "if=none,id=esp,format=raw,readonly=on,file=fat:$(abspath $(ESP))" \
             -device virtio-blk-pci,drive=esp,bootindex=1 \
             -monitor none -serial stdio
DATA_DRIVE = -drive "if=ide,index=0,format=raw,file=$(abspath $(DATA_DISK))"

.DELETE_ON_ERROR:
.PHONY: all run run-gui test check-ovmf

all: $(KERNEL) $(BOOT_EFI) $(ESP)/limine.conf $(ESP)/FONT-LICENSE.txt

$(KERNEL): build/kernel.elf
	mkdir -p "$(@D)"
	cp "$<" "$@"

build/kernel.elf: $(SOURCES) $(FONT_ATLASES) boot/kernel.ld Makefile
	mkdir -p "$(@D)"
	"$(LDC)" $(D_FLAGS) -link-internally -defaultlib= \
		-L=-nostdlib -L=--gc-sections -L=-T -L=boot/kernel.ld -of="$@" $(SOURCES)

$(LIMINE_ARCHIVE):
	mkdir -p "$(@D)"
	curl -fsSL --retry 2 -o "$@.tmp" \
		"https://github.com/Limine-Bootloader/Limine/releases/download/v$(LIMINE_VERSION)/limine-binary.tar.gz"
	printf '%s  %s\n' "$(LIMINE_SHA256)" "$@.tmp" | shasum -a 256 -c
	mv "$@.tmp" "$@"

$(BOOT_EFI): $(LIMINE_ARCHIVE) Makefile
	printf '%s  %s\n' "$(LIMINE_SHA256)" "$<" | shasum -a 256 -c
	mkdir -p "$(@D)"
	tar -xOf "$<" limine-binary/BOOTX64.EFI > "$@"

$(ESP)/limine.conf: boot/limine.conf
	mkdir -p "$(@D)"
	cp "$<" "$@"

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
		printf 'DLANGFS1' | dd of="$$temp" conv=notrunc; \
		ln "$$temp" "$@" || test -f "$@"

run: check-ovmf all $(DATA_DISK)
	"$(QEMU)" $(QEMU_FLAGS) $(DATA_DRIVE) -display none

run-gui: check-ovmf all $(DATA_DISK)
	"$(QEMU)" $(QEMU_FLAGS) $(DATA_DRIVE)

test: check-ovmf all
	"$(PYTHON)" tests/qemu_shell.py "$(QEMU)" $(QEMU_FLAGS) -display none
