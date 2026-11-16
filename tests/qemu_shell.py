"""QEMUを起動し、verify_shellでCOM1、verify_desktopで画面とPS/2入力を確認する。
使い捨てのディスクで永続化と復旧を試し、Ring 3でのELF起動、Dランタイム、Phobos、ウィンドウ操作も確認する。
"""

from contextlib import ExitStack, contextmanager
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time


PROMPT = b"dlang> "
UPLOAD_READY = b"Send hex, then . on its own line. ! cancels.\r\n"


class SerialConsole:
    def __init__(self, guest):
        self.input = guest.stdin
        self.output = guest.stdout
        self.pending = b""

    def send(self, data):
        self.input.write(data)
        self.input.flush()

    def read_until(self, marker, timeout=5):
        deadline = time.monotonic() + timeout
        while marker not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.output], [], [], remaining)[0]:
                raise AssertionError(f"Timed out waiting for {marker!r}; got {self.pending!r}")
            received = os.read(self.output.fileno(), 4096)
            if not received:
                raise AssertionError(f"QEMU exited while waiting for {marker!r}; got {self.pending!r}")
            self.pending += received
        output, self.pending = self.pending.split(marker, 1)
        return output

    def command(self, data):
        self.send(data)
        return self.read_until(PROMPT)


def expect_equal(actual, expected):
    if actual != expected:
        raise AssertionError(f"Expected {expected!r}; got {actual!r}")


def verify_shell(console):
    help_output = console.command(b"help\r")
    for command in (b"help", b"echo", b"uname", b"mem", b"ls", b"cat", b"write",
                    b"put", b"get", b"rm", b"clear", b"halt"):
        if not re.search(rb"(?:^|\r\n)" + command + rb" +\S", help_output):
            raise AssertionError(f"Help is missing {command!r}: {help_output!r}")

    # 直前のCRに続くLFは改行として数えず、DELと矢印キーはコマンド文字列に残さない。
    expect_equal(console.command(b"\necho helx\x7fl\x1b[Do\r"), b"echo helx\b \blo\r\nhello\r\n")
    expect_equal(console.command(b"uname\n"), b"uname\r\nDlang OS x86_64\r\n")
    expect_equal(console.command(b"missing\r"), b"missing\r\nUnknown command: missing\r\n")

    memory = console.command(b"mem\r")
    match = re.fullmatch(rb"mem\r\nUsable memory: ([0-9]+) KiB\r\nFree pages: ([0-9]+) KiB\r\n", memory)
    if match is None or not 0 < int(match[1]) <= 128 * 1024:
        raise AssertionError(f"Expected usable memory within the 128 MiB guest; got {memory!r}")

    # 末尾に収まる127バイトは実行し、1バイト超えた行は先頭のechoも実行しない。
    argument = b"a" * 122
    full_line = b"echo " + argument
    expect_equal(console.command(full_line + b"\r"), full_line + b"\r\n" + argument + b"\r\n")
    expect_equal(
        console.command(full_line + b"b\r"),
        full_line + b"\a\r\nLine too long (max 127 bytes).\r\n",
    )
    expect_equal(console.command(b"clear\r"), b"clear\r\n\x1b[2J\x1b[H")
    expect_equal(console.command(b"halt extra\r"), b"halt extra\r\nUsage: halt\r\n")

def verify_halt(console):
    console.send(b"halt\r")
    expect_equal(console.read_until(b"CPU halted.\r\n"), b"halt\r\n")
    # 停止メッセージを出した後、シェルへ戻らないことを確認する。
    console.send(b"echo still-running\r")
    if console.pending or select.select([console.output], [], [], 0.5)[0]:
        raise AssertionError("QEMU produced more output after halt")



class Qmp:
    def __init__(self, connection):
        self.stream = connection.makefile("rwb")
        if "QMP" not in self.receive():
            raise AssertionError("Missing QMP greeting")
        self.execute("qmp_capabilities")

    def receive(self):
        line = self.stream.readline()
        if not line:
            raise AssertionError("QEMU closed the QMP connection")
        return json.loads(line)

    def execute(self, command, **arguments):
        request = {"execute": command, "arguments": arguments}
        self.stream.write(json.dumps(request).encode() + b"\n")
        self.stream.flush()
        while True:
            response = self.receive()
            if "event" in response:
                continue
            if "error" in response:
                raise AssertionError(f"QMP {command}: {response['error']}")
            return response["return"]

    def keys(self, *codes):
        for code in codes:
            self.chord(code)
            # 短いPS/2の受信キューに一度にスキャンコードを詰め込まない。
            time.sleep(0.015)

    def chord(self, *codes):
        self.execute("input-send-event", events=[
            {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": code}}}
            for down, sequence in ((True, codes), (False, reversed(codes)))
            for code in sequence
        ])

    def move_to(self, x, y):
        old_x, old_y = self.pointer
        self.move(x - old_x, y - old_y)
        self.pointer = x, y

    def move(self, dx, dy):
        # PS/2の1パケットに収まる移動量で送信する。
        while dx or dy:
            step_x = max(-100, min(100, dx))
            step_y = max(-100, min(100, dy))
            self.execute(
                "input-send-event",
                events=[
                    {"type": "rel", "data": {"axis": axis, "value": distance}}
                    for axis, distance in (("x", step_x), ("y", step_y))
                    if distance
                ],
            )
            dx -= step_x
            dy -= step_y

    def button(self, down):
        self.execute("input-send-event", events=[
            {"type": "btn", "data": {"button": "left", "down": down}}
        ])

    def click(self):
        self.button(True)
        self.button(False)

    def capture(self, path):
        self.execute("screendump", filename=str(path))
        return path.read_bytes()

    def wait_screen(self, path, label, check):
        deadline = time.monotonic() + 8
        while True:
            magic, dimensions, maximum, pixels = self.capture(path).split(b"\n", 3)
            width, height = map(int, dimensions.split())
            if magic != b"P6" or maximum != b"255" or len(pixels) != width * height * 3:
                raise AssertionError(f"Unexpected QEMU screen: {(magic, dimensions, maximum)!r}")
            if check(width, height, pixels):
                return width, height
            if time.monotonic() >= deadline:
                raise AssertionError(f"Missing screen result: {label}")
            time.sleep(0.05)

    def until_pixel(self, path, x, y, expected):
        return self.wait_screen(
            path, f"pixel ({x}, {y}) = {expected.hex()}",
            lambda width, height, data: x < width and y < height and pixel(data, width, x, y) == expected,
        )

    def until_region_color(self, path, x, y, w, h, color):
        return self.wait_screen(
            path, f"color {color.hex()} inside ({x}, {y}, {w}, {h})",
            lambda width, _height, data: any(
                pixel(data, width, col, row) == color
                for row in range(y, y + h) for col in range(x, x + w)
            ),
        )


def pixel(data, width, x, y):
    offset = 3 * (y * width + x)
    return data[offset:offset + 3]


# 文字列の期待値は各テストに直接書き、字形の画素は同梱データから組み立てる。
FONT_DIRECTORY = Path(__file__).resolve().parents[1] / "assets" / "fonts"
PROJECT = Path(__file__).resolve().parents[1]
APP_DIRECTORY = PROJECT / "build" / "apps"
DESKTOP_ELFS = ("calc.elf", "game.elf", "monitor.elf", "files.elf", "editor.elf", "counter.elf")
FONT_ATLASES = {
    (width, height): (FONT_DIRECTORY / f"ui-{width}x{height}.coverage").read_bytes()
    for width, height in ((8, 14), (16, 24))
}


def expect_text(qmp, path, x, y, value, scale, background, foreground=bytes.fromhex("152843")):
    cell_width, cell_height = (16, 24) if scale == 2 else (8, 14)
    atlas = FONT_ATLASES[cell_width, cell_height]

    def matches(width, _height, data):
        for index, char in enumerate(value):
            start = (ord(char) - 32) * cell_width * cell_height
            for row in range(cell_height):
                for col in range(cell_width):
                    alpha = atlas[start + row * cell_width + col]
                    expected = bytes(
                        (ink * alpha + under * (255 - alpha) + 127) // 255
                        for ink, under in zip(foreground, background)
                    )
                    if pixel(data, width, x + index * cell_width + col, y + row) != expected:
                        return False
        return True

    qmp.wait_screen(path, f"text {value!r} at ({x}, {y})", matches)


@contextmanager
def boot(qemu_command, disk, *, with_qmp=False, disk_ready=True, drive_index=0, extra_drives=()):
    command = [*qemu_command, "-drive", f"if=ide,index={drive_index},format=raw,file={disk}"]
    for index, path in extra_drives:
        command += ["-drive", f"if=ide,index={index},format=raw,file={path}"]
    with ExitStack() as stack:
        pass_fds = ()
        if with_qmp:
            host, child = socket.socketpair()
            stack.enter_context(host)
            stack.enter_context(child)
            host.settimeout(10)
            pass_fds = (child.fileno(),)
            command += ["-chardev", f"socket,id=qmp,fd={child.fileno()}",
                        "-mon", "chardev=qmp,mode=control"]
        guest = stack.enter_context(subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, pass_fds=pass_fds,
        ))
        if with_qmp:
            child.close()
        try:
            console = SerialConsole(guest)
            log = console.read_until(PROMPT, timeout=35)
            unavailable = b"Data disk unavailable" in log
            if b"Dlang OS (x86_64)\r\n" not in log or unavailable == disk_ready:
                raise AssertionError(f"Unexpected startup or disk state: {log!r}")
            qmp = Qmp(host) if with_qmp else None
            if qmp is not None:
                stack.enter_context(qmp.stream)
            yield console, qmp
        finally:
            if guest.poll() is None:
                guest.terminate()
                try:
                    guest.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    guest.kill()


def expect_command(console, command, response=b""):
    expect_equal(console.command(command + b"\r"), command + b"\r\n" + response)


def verify_files(console):
    expect_command(console, b"ls")
    expect_command(console, b"write history.txt first version", b"Saved.\r\n")
    expect_command(console, b"write history.txt second version", b"Saved.\r\n")
    expect_command(console, b"cat history.txt", b"second version\r\n")
    expect_command(console, b"write removed.txt old", b"Saved.\r\n")
    expect_command(console, b"rm removed.txt", b"Deleted.\r\n")
    expect_command(console, b"write ../invalid no", b"Use 1-24 letters, digits, dots, _ or - (no leading dot).\r\n")
    expect_command(console, b"ls", b"history.txt\r\n")


def verify_desktop(console, qmp, image_path):
    ink = bytes.fromhex("152843")
    paper = bytes.fromhex("ffffff")
    accent = bytes.fromhex("135a56")
    accent_light = bytes.fromhex("d9ece8")
    wallpaper = bytes.fromhex("142941")
    width, height = qmp.until_pixel(image_path, 0, 0, wallpaper)
    qmp.pointer = width // 2, height // 2
    qmp.until_pixel(image_path, 22, 24, bytes.fromhex("213d54"))
    qmp.until_pixel(image_path, 10, 572, accent)

    # ポインタだけが動くとき、元の場所も含め画面が完全に復元される。
    original = qmp.capture(image_path)
    qmp.move_to(123, 41)
    qmp.until_pixel(image_path, 123, 41, ink)
    qmp.move_to(width // 2, height // 2)
    qmp.until_pixel(image_path, width // 2, height // 2, ink)
    if qmp.capture(image_path) != original:
        raise AssertionError("Cursor movement left damage on the desktop")
    preview = os.environ.get("DLANG_DESKTOP_PREVIEW")
    if preview:
        qmp.capture(Path(preview).resolve())

    # デスクトップのEditorアイコンを開き、窓のNewとSaveをマウスで使う。
    qmp.move_to(49, 126)
    qmp.until_pixel(image_path, 49, 126, ink)
    qmp.click()
    qmp.until_pixel(image_path, 201, 78, accent)
    qmp.move_to(236, 121)
    qmp.until_pixel(image_path, 236, 121, ink)
    qmp.click()
    qmp.until_pixel(image_path, 450, 192, accent_light)
    qmp.keys("n", "o", "t", "e", "dot", "t", "x", "t", "ret",
             "h", "e", "l", "l", "o", "ret", "d", "l", "a", "n", "g")
    qmp.until_pixel(image_path, 450, 192, paper)
    expect_text(qmp, image_path, 214, 209, "dlang", 2, paper)
    qmp.move_to(291, 121)
    qmp.until_pixel(image_path, 291, 121, ink)
    qmp.click()

    deadline = time.monotonic() + 5
    expected = b"cat note.txt\r\nhello\r\ndlang\r\n"
    while True:
        received = console.command(b"cat note.txt\r")
        if received == expected:
            break
        if time.monotonic() >= deadline:
            expect_equal(received, expected)
        time.sleep(0.05)

    # 保存後に別の経路で更新された内容を、古い下書きから上書きしない。
    expect_command(console, b"write note.txt from serial", b"Saved.\r\n")
    qmp.keys("ret", "o", "l", "d", "f3")
    expect_text(qmp, image_path, 214, 154, "Unsaved changes", 1, paper, bytes.fromhex("8e381b"))
    expect_command(console, b"cat note.txt", b"from serial\r\n")
    qmp.keys("f4", "c", "o", "p", "y", "dot", "t", "x", "t", "ret")
    expect_text(qmp, image_path, 214, 154, "Saved", 1, paper, accent)
    expect_command(console, b"cat note.txt", b"from serial\r\n")
    expect_command(console, b"cat copy.txt", b"hello\r\ndlang\r\nold\r\n")
    verify_editor_save(console, qmp, image_path)
    verify_editor_mouse(console, qmp, image_path)


def verify_editor_save(console, qmp, image_path):
    ink = bytes.fromhex("152843")
    accent_light = bytes.fromhex("d9ece8")
    paper = bytes.fromhex("ffffff")
    original = b"hello\r\ndlang\r\nold"

    def click(x, y):
        qmp.move_to(x, y)
        qmp.until_pixel(image_path, x, y, ink)
        qmp.click()

    # Ctrl+Shift+S を押しただけでは元ファイルを書き換えない。
    qmp.keys("x")
    qmp.chord("ctrl", "shift", "s")
    time.sleep(0.05)
    expect_command(console, b"cat copy.txt", original + b"\r\n")
    qmp.until_pixel(image_path, 450, 192, accent_light)
    qmp.keys("m", "o", "u", "s", "e", "dot", "t", "x", "t")
    click(260, 277)
    qmp.until_pixel(image_path, 450, 192, paper)
    expect_command(console, b"cat mouse.txt", original + b"x\r\n")
    expect_command(console, b"cat copy.txt", original + b"\r\n")

    # 同名で保存できなくても下書きを保持し、Cancelの後は通常保存できる。
    qmp.keys("y")
    click(359, 121)
    qmp.keys("n", "o", "t", "e", "dot", "t", "x", "t", "ret")
    qmp.until_pixel(image_path, 450, 192, accent_light)
    expect_command(console, b"cat note.txt", b"from serial\r\n")
    expect_command(console, b"cat mouse.txt", original + b"x\r\n")
    click(360, 277)
    qmp.until_pixel(image_path, 450, 192, paper)
    qmp.chord("ctrl", "s")
    expect_text(qmp, image_path, 214, 154, "Saved", 1, bytes.fromhex("ffffff"), bytes.fromhex("135a56"))
    expect_command(console, b"cat mouse.txt", original + b"xy\r\n")

    # 長い名前の末尾を黙って切り捨てて、意図した名前と別のファイルに保存してはいけない。
    qmp.keys("f4", *("a",) * 24, "b", "ret")
    expect_command(console, b"cat " + b"a" * 24, b"File not found.\r\n")
    qmp.until_pixel(image_path, 450, 192, accent_light)
    qmp.keys("backspace", "ret")
    qmp.until_pixel(image_path, 450, 192, paper)
    expect_command(console, b"cat " + b"a" * 24, original + b"xy\r\n")


def verify_editor_mouse(console, qmp, image_path):
    ink = bytes.fromhex("152843")
    highlight = bytes.fromhex("d9ece8")
    toolbar = bytes.fromhex("e9eef4")
    muted = bytes.fromhex("405772")
    file = b"cat " + b"a" * 24
    saved = b"world\r\ndlang\r\n"

    def click(x, y):
        qmp.move_to(x, y)
        qmp.until_pixel(image_path, x, y, ink)
        qmp.click()

    def select_line(y):
        qmp.move_to(215, y)
        qmp.until_pixel(image_path, 215, y, ink)
        qmp.button(True)
        qmp.move_to(295, y)
        qmp.button(False)

    # マウスで選んだ範囲を文字入力で置き換え、別の範囲をBackspaceで削除する。
    select_line(188)
    qmp.until_pixel(image_path, 218, 208, highlight)
    qmp.keys("w", "o", "r", "l", "d")
    select_line(240)
    qmp.until_pixel(image_path, 218, 260, highlight)
    qmp.keys("backspace")
    click(291, 121)
    expect_text(qmp, image_path, 214, 154, "Saved", 1, bytes.fromhex("ffffff"), bytes.fromhex("135a56"))
    expect_command(console, file, saved)

    editor_preview = os.environ.get("DLANG_EDITOR_PREVIEW")
    if editor_preview:
        qmp.capture(Path(editor_preview).resolve())

    # スクロールで先頭を表示しても、カーソルへ勝手に戻らない。
    click(215, 240)
    qmp.keys(*("ret",) * 12, "z")
    qmp.until_pixel(image_path, 645, 185, toolbar)
    click(647, 184)
    qmp.until_pixel(image_path, 645, 185, muted)
    expect_text(qmp, image_path, 214, 183, "world", 2, bytes.fromhex("ffffff"))

    # 未保存で閉じる場合も、マウスで残すか破棄するかを選べる。
    click(654, 88)
    qmp.until_pixel(image_path, 510, 397, bytes.fromhex("8e381b"))
    click(620, 403)
    qmp.until_pixel(image_path, 510, 397, toolbar)
    click(654, 88)
    click(540, 403)
    qmp.until_pixel(image_path, 80, 572, ink)
    expect_command(console, file, saved)


def spawn_process(console, program):
    response = console.command(b"spawn " + program + b"\r")
    match = re.fullmatch(rb"spawn " + program + rb"\r\nStarted PID ([0-9]+)\r\n", response)
    if match is None:
        raise AssertionError(f"Unable to start {program!r}: {response!r}")
    return int(match[1])


def process_list(console):
    response = console.command(b"ps\r")
    rows = re.findall(rb"^([0-9]+) ([A-Za-z0-9_.-]+) ([0-9]+) ([0-9]+) ([0-9]+)\r$", response, re.M)
    totals = re.search(rb"Exited: ([0-9]+)  Faulted: ([0-9]+)", response)
    if totals is None:
        raise AssertionError(f"Missing process totals: {response!r}")
    return {int(pid): (name, int(value), int(slices), int(preemptions))
            for pid, name, value, slices, preemptions in rows}, tuple(map(int, totals.groups()))


def wait_process_names(console, *names):
    expected = sorted(names)
    deadline = time.monotonic() + 5
    while True:
        running, totals = process_list(console)
        actual = sorted(task[0] for task in running.values())
        if actual == expected:
            return running, totals
        if time.monotonic() >= deadline:
            expect_equal(actual, expected)
        time.sleep(0.05)


def stop_process(console, pid):
    expect_command(console, f"kill {pid}".encode(), b"Stopped.\r\n")


def free_memory(console):
    response = console.command(b"mem\r")
    match = re.search(rb"Free pages: ([0-9]+) KiB", response)
    if match is None:
        raise AssertionError(f"Missing allocator statistics: {response!r}")
    return int(match[1])


def verify_processes(console):
    baseline_memory = free_memory(console)
    spin = spawn_process(console, b"spin")
    first = spawn_process(console, b"counter")
    second = spawn_process(console, b"counter")
    exited = spawn_process(console, b"exit")
    faulted = spawn_process(console, b"fault")

    if free_memory(console) >= baseline_memory:
        raise AssertionError("Live processes did not consume physical pages")
    before, _ = process_list(console)
    deadline = time.monotonic() + 5
    while True:
        after, totals = process_list(console)
        if (all(pid in before and pid in after and after[pid][1] > before[pid][1]
                for pid in (first, second))
                and spin in before and spin in after and after[spin][3] > before[spin][3]):
            break
        if time.monotonic() >= deadline:
            raise AssertionError(f"Runnable processes did not make progress: {before}, {after}")
        time.sleep(0.01)
    # spinにはsyscallがない。実際のタイマー割り込みと、他の2タスクの進行を同時に確認する。
    if (spin not in before or spin not in after or after[spin][0] != b"spin"
            or after[spin][3] <= before[spin][3]):
        raise AssertionError(f"Non-yielding process did not get preempted: {before}, {after}")
    for pid in (first, second):
        if (pid not in before or pid not in after or after[pid][0] != b"counter"
                or not before[pid][1] < after[pid][1]):
            raise AssertionError(f"Counter {pid} lost progress or its stack: {before}, {after}")
    expect_equal(totals, (1, 1))
    if exited in after or faulted in after:
        raise AssertionError(f"A finished process is still runnable: {after}")

    for pid in (spin, first, second):
        stop_process(console, pid)
    expect_equal(free_memory(console), baseline_memory)
    expect_equal(process_list(console)[0], {})


def verify_windows(console, qmp, image_path):
    accent = bytes.fromhex("135a56")
    inactive = bytes.fromhex("405772")
    cursor = bytes.fromhex("152843")
    qmp.keys("f8", "f2", "a", "dot", "t", "x", "t", "ret", "o", "n", "e")
    qmp.until_pixel(image_path, 201, 78, accent)
    qmp.keys("f8", "f2", "b", "dot", "t", "x", "t", "ret", "t", "w", "o")
    qmp.until_pixel(image_path, 225, 107, accent)
    qmp.until_pixel(image_path, 201, 78, inactive)
    qmp.keys("f10")
    qmp.until_pixel(image_path, 225, 107, accent)
    expect_command(console, b"cat b.txt", b"File not found.\r\n")

    qmp.keys("f7", "f3")
    qmp.until_pixel(image_path, 201, 78, accent)
    expect_command(console, b"cat a.txt", b"one\r\n")
    qmp.keys("f7", "f3")
    qmp.until_pixel(image_path, 225, 107, accent)
    expect_command(console, b"cat b.txt", b"two\r\n")

    qmp.move_to(370, 115)
    qmp.until_pixel(image_path, 370, 115, cursor)
    qmp.button(True)
    qmp.move_to(405, 173)
    qmp.button(False)
    qmp.until_pixel(image_path, 260, 165, accent)
    qmp.move_to(713, 175)
    qmp.until_pixel(image_path, 713, 175, cursor)
    qmp.click()
    qmp.until_pixel(image_path, 201, 78, accent)
    expect_command(console, b"cat b.txt", b"two\r\n")

    # タイトルバーで最小化し、タスクバーから同じ文書を復元する。
    qmp.move_to(628, 88)
    qmp.until_pixel(image_path, 628, 88, cursor)
    qmp.click()
    qmp.until_pixel(image_path, 80, 572, bytes.fromhex("2b4359"))
    qmp.move_to(125, 582)
    qmp.until_pixel(image_path, 125, 582, cursor)
    qmp.click()
    qmp.until_pixel(image_path, 201, 78, accent)

    qmp.keys("f9", "f9")
    qmp.until_pixel(image_path, 444, 277, accent)
    qmp.until_pixel(image_path, 477, 196, inactive)
    running, totals = wait_process_names(console, b"editor.elf", b"counter.elf", b"counter.elf")
    counters = {pid for pid, task in running.items() if task[0] == b"counter.elf"}
    if any(running[pid][1] == 0 for pid in counters):
        raise AssertionError(f"Counter windows did not launch independent tasks: {running}")
    expect_file_bytes(console, b"counter.elf", (APP_DIRECTORY / "counter.elf").read_bytes())

    # GUIからELFへ入力を送り、ELFが返したテキストで止まったことを確認する。
    qmp.move_to(540, 372)
    qmp.until_pixel(image_path, 540, 372, cursor)
    qmp.click()
    expect_text(qmp, image_path, 456, 334, "Paused", 2, bytes.fromhex("ffffff"))
    paused, _ = process_list(console)
    top_pid = max(counters)
    assert_quiescent(console, top_pid)
    qmp.keys("ret")
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        moving, _ = process_list(console)
        if moving[top_pid][1] > paused[top_pid][1]:
            break
    else:
        raise AssertionError("Counter did not resume after the Enter event")

    preview = os.environ.get("DLANG_GUI_PREVIEW")
    if preview:
        time.sleep(0.25)
        qmp.capture(Path(preview).resolve())

    qmp.keys("f10")
    qmp.until_pixel(image_path, 477, 196, accent)
    remaining, after_close = wait_process_names(console, b"editor.elf", b"counter.elf")
    expect_equal({pid for pid, task in remaining.items() if task[0] == b"counter.elf"}, {min(counters)})
    expect_equal(after_close, (totals[0] + 1, totals[1]))
    stop_process(console, min(counters))
    qmp.until_pixel(image_path, 201, 78, accent)
    wait_process_names(console, b"editor.elf")


def verify_file_window(console, qmp, image_path):
    cursor = bytes.fromhex("152843")
    accent = bytes.fromhex("135a56")
    width, height = qmp.until_pixel(image_path, 0, 0, bytes.fromhex("142941"))
    qmp.pointer = width // 2, height // 2
    qmp.move_to(38, 582)
    qmp.until_pixel(image_path, 38, 582, cursor)
    qmp.click()
    qmp.until_pixel(image_path, 10, 349, bytes.fromhex("ffffff"))
    qmp.move_to(36, 367)
    qmp.until_pixel(image_path, 36, 367, cursor)
    qmp.click()
    qmp.until_pixel(image_path, 130, 51, accent)
    # ELFもファイル一覧に載るので、シリアルの一覧でcopy.txtの行を調べる。
    names = console.command(b"ls\r").splitlines()[1:]
    qmp.keys(*("down",) * names.index(b"copy.txt"), "ret")
    qmp.until_pixel(image_path, 225, 107, accent)
    expect_text(qmp, image_path, 238, 238, "dlang", 2, bytes.fromhex("ffffff"))
    running, _ = wait_process_names(console, b"files.elf", b"editor.elf")

    # 開き直しても同じEditorプロセスのウィンドウが前面に戻る。
    qmp.keys("f5")
    qmp.until_pixel(image_path, 130, 51, accent)
    qmp.keys("ret")
    qmp.until_pixel(image_path, 225, 107, accent)
    reopened, _ = wait_process_names(console, b"files.elf", b"editor.elf")
    expect_equal(set(reopened), set(running))


def verify_new_apps(console, qmp, image_path):
    ink = bytes.fromhex("152843")
    accent = bytes.fromhex("135a56")
    paper = bytes.fromhex("ffffff")
    warning = bytes.fromhex("8e381b")
    toolbar = bytes.fromhex("e9eef4")
    divider = bytes.fromhex("c9d6e3")

    def click(x, y):
        qmp.move_to(x, y)
        qmp.until_pixel(image_path, x, y, ink)
        qmp.click()

    def preview(app):
        prefix = os.environ.get("DLANG_APP_PREVIEW")
        if prefix:
            qmp.capture(Path(f"{prefix}-{app}.ppm").resolve())

    # 先行テストのEditorを閉じて、キーボードのAppsメニューからCalcを起動する。
    qmp.keys("f10", "f1", "down", "down", "down", "ret")
    qmp.until_pixel(image_path, 187, 66, accent)
    qmp.keys("7", "dot", "5")
    click(426, 187)
    qmp.keys("2")
    click(388, 339)
    expect_text(qmp, image_path, 382, 131, "3.75", 2, paper)
    preview("calc")
    wait_process_names(console, b"calc.elf")

    qmp.keys("c", "1", "dot", "5")
    click(426, 225)
    qmp.keys("2", "ret")
    expect_text(qmp, image_path, 430, 131, "3", 2, paper)
    qmp.keys("c", "8", "minus", "5", "ret")
    expect_text(qmp, image_path, 430, 131, "3", 2, paper)
    qmp.keys("c", "1")
    click(426, 301)
    qmp.keys("2", "ret")
    expect_text(qmp, image_path, 430, 131, "3", 2, paper)

    qmp.keys("c", "7")
    click(426, 187)
    qmp.keys("0", "ret")
    expect_text(qmp, image_path, 334, 131, "Divide by zero", 1, paper, warning)
    qmp.keys("c", "9", "9", "9", "9", "9", "9")
    click(426, 301)
    qmp.keys("1", "ret")
    expect_text(qmp, image_path, 350, 131, "Out of range", 1, paper, warning)
    qmp.keys("f10")

    # スネークを起動し、最初の餌を食べて1点になった後、矢印で上へ曲がる。
    click(160, 126)
    qmp.until_pixel(image_path, 209, 96, accent)
    qmp.keys("ret")
    expect_text(qmp, image_path, 384, 138, "1", 1, toolbar)
    qmp.keys("up")
    qmp.until_region_color(image_path, 224, 240, 300, 13, bytes.fromhex("aeebce"))
    preview("game")
    wait_process_names(console, b"game.elf")

    # 別アプリが前面になるとゲームが止まり、Monitorの表はユーザープロセスの増減に追従する。
    click(160, 203)
    qmp.until_pixel(image_path, 340, 74, accent)
    qmp.until_pixel(image_path, 275, 242, ink)
    wait_process_names(console, b"game.elf", b"monitor.elf")
    qmp.until_pixel(image_path, 536, 158, accent)
    qmp.until_pixel(image_path, 549, 158, divider)
    running = spawn_process(console, b"spin")
    qmp.until_pixel(image_path, 549, 158, accent)
    qmp.until_pixel(image_path, 350, 207, bytes.fromhex("d9ece8"))
    preview("monitor")
    stop_process(console, running)
    qmp.until_pixel(image_path, 549, 158, divider)
    qmp.keys("f10")
    wait_process_names(console, b"game.elf")
    qmp.keys("f10")
    wait_process_names(console)


def old_record(sequence, name, contents):
    # DLANGFS1ではメタデータと478バイトの本文領域が同じセクタにある。
    raw = struct.pack("<IIH24s478s", sequence, 0, len(contents), name, contents)
    checksum = 2166136261
    for byte in raw[:4] + raw[8:]:
        checksum = ((checksum ^ byte) * 16777619) & 0xffffffff
    return raw[:4] + struct.pack("<I", checksum) + raw[8:]


def old_disk_image():
    image = bytearray(1024 * 1024)
    image[:8] = b"DLANGFS1"
    records = (
        old_record(1, b"notes.txt", b"first draft\n"),
        old_record(2, b"notes.txt", b"latest draft\nsecond line\n"),
        old_record(1, b"removed.txt", b"old content"),
        old_record(2, b"", b""),
        old_record(1, b"full-v1.txt", b"x" * 478),
    )
    for sector, record in enumerate(records, start=1):
        image[sector * 512 : (sector + 1) * 512] = record
    return image


def begin_upload(console, name, size):
    command = b"put " + name + b" " + str(size).encode()
    console.send(command + b"\r\n")
    expect_equal(console.read_until(UPLOAD_READY, timeout=15), command + b"\r\n")


def put_file(console, name, contents):
    begin_upload(console, name, len(contents))
    hex_lines = [contents[offset : offset + 32].hex().encode()
                 for offset in range(0, len(contents), 32)]
    console.send(b"\r\n".join([*hex_lines, b".", b""]))
    expect_equal(console.read_until(PROMPT, timeout=20), b"Saved.\r\n")


def expect_file_bytes(console, name, expected):
    console.send(b"get " + name + b"\r")
    output = console.read_until(PROMPT, timeout=20).splitlines()
    expect_equal(output[0:2], [b"get " + name, b"HEX " + str(len(expected)).encode()])
    received = bytes.fromhex(b"".join(output[2:]).decode("ascii"))
    if received != expected:
        raise AssertionError(
            f"{name!r}: expected {len(expected)} bytes ({sha256(expected).hexdigest()}), "
            f"got {len(received)} bytes ({sha256(received).hexdigest()})"
        )


def run_hello(console):
    expect_command(console, b"run hello.elf", b"Hello from a D ELF on disk!\r\n")


def verify_disk_elf(console):
    baseline_memory = free_memory(console)
    hello = (APP_DIRECTORY / "hello.elf").read_bytes()
    before, totals = process_list(console)
    expect_command(console, b"run missing.elf", b"File not found.\r\n")
    put_file(console, b"hello.elf", hello[:64])
    expect_command(console, b"run hello.elf", b"Unsupported or invalid ELF executable.\r\n")
    expect_equal(process_list(console), (before, totals))

    # PT_LOADを配置した後で入口の検証に失敗しても、割り当てを回収する。
    invalid_entry = bytearray(hello)
    invalid_entry[24:32] = bytes(8)
    put_file(console, b"hello.elf", invalid_entry)
    for _ in range(8):
        expect_command(console, b"run hello.elf", b"Unsupported or invalid ELF executable.\r\n")
    expect_equal(free_memory(console), baseline_memory)

    put_file(console, b"hello.elf", hello)
    run_hello(console)
    run_hello(console)  # 前回書いたBSSが再利用時に残らない。
    expect_equal(process_list(console), (before, (totals[0] + 2, totals[1])))
    expect_equal(free_memory(console), baseline_memory)


def assert_quiescent(console, pid):
    deadline = time.monotonic() + 2
    previous = process_list(console)[0][pid]
    while time.monotonic() < deadline:
        time.sleep(0.1)
        current = process_list(console)[0][pid]
        if current == previous:
            time.sleep(0.2)
            expect_equal(process_list(console)[0][pid], current)
            return
        previous = current
    raise AssertionError(f"PID {pid} kept running while waiting")


def verify_sleep(console):
    baseline = free_memory(console)
    put_file(console, b"sleep.elf", (APP_DIRECTORY / "sleep.elf").read_bytes())
    response = console.command(b"run sleep.elf &\r")
    match = re.fullmatch(rb"run sleep.elf &\r\nStarted PID ([0-9]+)\r\n", response)
    if match is None:
        raise AssertionError(response)
    pid = int(match[1])
    spin = spawn_process(console, b"spin")
    before = process_list(console)[0]
    expect_equal(before[pid][1], 1)
    assert_quiescent(console, pid)
    after = process_list(console)[0]
    if after[spin][2] <= before[spin][2]:
        raise AssertionError("sleep blocked other runnable processes")
    deadline = time.monotonic() + 5
    while process_list(console)[0][pid][1] != 2:
        if time.monotonic() >= deadline:
            raise AssertionError("sleep did not resume at its deadline")
        time.sleep(0.05)
    assert_quiescent(console, pid)
    # Ring 3実行中にもUART IRQが入り、バースト転送を欠落させない。
    burst = bytes(range(256)) * 64
    put_file(console, b"burst.bin", burst)
    expect_file_bytes(console, b"burst.bin", burst)
    expect_command(console, b"rm burst.bin", b"Deleted.\r\n")
    stop_process(console, pid)
    stop_process(console, spin)
    expect_equal(free_memory(console), baseline)


def verify_virtual_memory(console):
    baseline = free_memory(console)
    before, totals = process_list(console)
    put_file(console, b"vm.elf", (APP_DIRECTORY / "vm.elf").read_bytes())
    for _ in range(2):
        console.send(b"run vm.elf\r")
        expect_equal(console.read_until(PROMPT, timeout=30),
                     b"run vm.elf\r\nVM: large BSS, stack, heap growth, shrink and OOM rollback passed.\r\n")
        expect_equal(free_memory(console), baseline)
    expect_equal(process_list(console), (before, (totals[0] + 2, totals[1])))


def verify_d_initialization(console):
    name = b"d_init.elf"
    put_file(console, name, (APP_DIRECTORY / name.decode("ascii")).read_bytes())
    before, totals = process_list(console)
    for _ in range(2):
        expect_command(console, b"run " + name, b"D shared static constructors ran before main.\r\n")
    expect_equal(process_list(console), (before, (totals[0] + 2, totals[1])))


def verify_d_heap(console):
    put_file(console, b"d_heap.elf", (APP_DIRECTORY / "d_heap.elf").read_bytes())
    before, totals = process_list(console)
    # 同じスロットを再利用しても、BSSの管理情報とヒープの初期値は毎回ゼロから始まる。
    for _ in range(2):
        expect_command(console, b"run d_heap.elf",
                       b"D heap: new and array append passed.\r\nD application heap exhausted.\r\n")
    expect_equal(process_list(console), (before, (totals[0] + 2, totals[1])))


def verify_d_exceptions(console):
    put_file(console, b"d_exception.elf", (APP_DIRECTORY / "d_exception.elf").read_bytes())
    before, totals = process_list(console)
    for _ in range(2):
        expect_command(console, b"run d_exception.elf",
                       b"D exceptions: catches and cleanups passed.\r\nUncaught D throwable: unhandled\r\n")
    expect_equal(process_list(console), (before, (totals[0] + 2, totals[1])))


def verify_d_arrays(console):
    put_file(console, b"d_array.elf", (APP_DIRECTORY / "d_array.elf").read_bytes())
    before, totals = process_list(console)
    # 成功例の後、端数の残るキャストでアプリだけがフォルトする。
    expect_command(console, b"run d_array.elf", b"D arrays: casts and concatenation passed.\r\n")
    expect_equal(process_list(console), (before, (totals[0], totals[1] + 1)))


def verify_phobos(console):
    vectors = (
        (b"d_base64.elf", b"Zm9vYmFy\r\nZm8=\r\nZg==\r\n"),
        (b"d_crc.elf", b"CBF43926\r\n414FA339\r\n"),
        (b"d_sha.elf", b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\r\n"
                       b"cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1\r\n"),
    )
    before, totals = process_list(console)
    for name, expected in vectors:
        put_file(console, name, (APP_DIRECTORY / name.decode("ascii")).read_bytes())
        expect_command(console, b"run " + name, expected)
    expect_equal(process_list(console), (before, (totals[0] + len(vectors), totals[1])))


def install_desktop_apps(qemu_command, disk):
    command = [sys.executable, str(PROJECT / "tools" / "install-apps.py"), "--disk", str(disk)]
    for name in DESKTOP_ELFS:
        command += ["--app", str(APP_DIRECTORY / name)]
    subprocess.run([*command, "--", *qemu_command], check=True, timeout=90)


def verify_desktop_without_apps(console, qmp, screen):
    for key, name in (("f8", b"editor.elf"), ("f9", b"counter.elf")):
        qmp.keys(key)
        expect_text(qmp, screen, 16, 541, "File not found.", 1,
                    bytes.fromhex("152843"), bytes.fromhex("ffffff"))
        expect_equal(process_list(console)[0], {})
        expect_command(console, b"cat " + name, b"File not found.\r\n")


def verify_desktop_reads_disk(console, qmp, screen):
    kernel = (PROJECT / "build" / "uefi-esp" / "kernel.elf").read_bytes()
    for name in DESKTOP_ELFS:
        elf = (APP_DIRECTORY / name).read_bytes()
        expect_file_bytes(console, name.encode(), elf)
        if elf in kernel:
            raise AssertionError(f"{name} is embedded in the kernel")

    put_file(console, b"editor.elf", b"invalid ELF")
    qmp.keys("f8")
    expect_text(qmp, screen, 16, 541, "Unsupported or invalid ELF executable.", 1,
                bytes.fromhex("152843"), bytes.fromhex("ffffff"))
    expect_equal(process_list(console)[0], {})
    expect_file_bytes(console, b"editor.elf", b"invalid ELF")
    put_file(console, b"editor.elf", (APP_DIRECTORY / "editor.elf").read_bytes())


def verify_counter_reads_disk(console, qmp, screen):
    binary = (APP_DIRECTORY / "counter.elf").read_bytes()
    expect_file_bytes(console, b"counter.elf", binary)
    put_file(console, b"counter.elf", b"invalid ELF")
    qmp.keys("f9")
    expect_text(qmp, screen, 16, 541, "Unsupported or invalid ELF executable.", 1,
                bytes.fromhex("152843"), bytes.fromhex("ffffff"))
    expect_equal(process_list(console)[0], {})
    expect_file_bytes(console, b"counter.elf", b"invalid ELF")
    put_file(console, b"counter.elf", binary)


def verify_migration_and_large_files(qemu_command, root):
    disk = root / "legacy-data.img"
    legacy = old_disk_image()
    # 移行途中に停止して新領域だけ書かれた状態。完了マーカーはまだ空。
    legacy[34 * 512 : 34 * 512 + 4] = b"part"
    disk.write_bytes(legacy)
    source_end = 33 * 512
    old_text = b"latest draft\nsecond line\n"
    large_text = (b"0123456789abcdef\n" * 400)[:6145]
    edited_text = large_text + b"z"
    binary = bytes(range(256)) * 64

    with boot(qemu_command, disk, with_qmp=True) as (console, qmp):
        expect_file_bytes(console, b"notes.txt", old_text)
        expect_file_bytes(console, b"full-v1.txt", b"x" * 478)
        expect_command(console, b"cat removed.txt", b"File not found.\r\n")
        put_file(console, b"large.txt", large_text)
        put_file(console, b"full.bin", binary)
        expect_command(console, b"cat full.bin", b"Binary file. Use get NAME.\r\n")
        expect_command(console, b"put oversized.bin 16385", b"Specify a byte count from 0 to 16384.\r\n")
        begin_upload(console, b"large.txt", len(large_text))
        console.send(b"4142\r\n.\r\n")
        expect_equal(console.read_until(PROMPT), b"Invalid hex data or byte count. File was not changed.\r\n")
        expect_file_bytes(console, b"large.txt", large_text)

        # 移行済みディスクにもELFを配置し、Filesから6 KiB超の文書を開いて追記・保存する。
        for name in ("files.elf", "editor.elf"):
            put_file(console, name.encode(), (APP_DIRECTORY / name).read_bytes())
        qmp.keys("f5", "down", "ret")
        screen = root / "large-editor.ppm"
        qmp.until_pixel(screen, 225, 107, bytes.fromhex("135a56"))
        qmp.keys("z", "f3")
        expect_text(qmp, screen, 238, 183, "Saved", 1,
                    bytes.fromhex("ffffff"), bytes.fromhex("135a56"))
        expect_file_bytes(console, b"large.txt", edited_text)

    migrated = disk.read_bytes()
    expect_equal(migrated[:source_end], legacy[:source_end])
    expect_equal(migrated[source_end : source_end + 8], b"DLANGFS2")
    with boot(qemu_command, disk) as (console, _):
        expect_file_bytes(console, b"notes.txt", old_text)
        expect_file_bytes(console, b"large.txt", edited_text)
        expect_file_bytes(console, b"full.bin", binary)
    expect_equal(disk.read_bytes(), migrated)

    # 有効な旧世代が残っていない破損ファイルは、消失扱いで移行しない。
    corrupt = root / "legacy-corrupt.img"
    bad_data = old_disk_image()
    bad_data[5 * 512 + 40] ^= 1
    corrupt.write_bytes(bad_data)
    with boot(qemu_command, corrupt, disk_ready=False) as (console, _):
        expect_command(console, b"write notes.txt ignored", b"Data disk unavailable.\r\n")
    expect_equal(corrupt.read_bytes(), bad_data)


def format_disk(path, *options):
    subprocess.run([sys.executable, str(PROJECT / "tools/format-disk.py"), str(path), *options], check=True)


def verify_volume_layout(qemu_command, root):
    disk = root / "custom-layout.img"
    format_disk(disk, "--slots", "3", "--file-bytes", "5000", "--records-lba", "9", "--copy-sectors", "13")
    initial = bytearray(disk.read_bytes())
    overwrite = subprocess.run([sys.executable, str(PROJECT / "tools/format-disk.py"), str(disk)],
                               capture_output=True)
    if overwrite.returncode == 0:
        raise AssertionError("Formatter overwrote an existing image")
    expect_equal(disk.read_bytes(), initial)
    expect_equal(struct.unpack_from("<8I", initial, 8), (3, 512, 3, 5000, 9, 13, 34, 24))
    # 配置の隙間はファイル領域ではない。保存や再起動後も変えてはならない。
    gaps = [(512, 9 * 512)] + [((9 + copy * 13 + 11) * 512, (9 + (copy + 1) * 13) * 512)
                               for copy in range(6)]
    for begin, end in gaps:
        initial[begin:end] = b"P" * (end - begin)
    disk.write_bytes(initial)
    payload = bytes(i % 251 for i in range(5000))
    with boot(qemu_command, disk) as (console, _):
        expect_command(console, b"fsinfo", b"Files: 3  File bytes: 5000\r\n")
        expect_command(console, b"write a.txt first", b"Saved.\r\n")
        put_file(console, b"b.bin", payload)
        expect_command(console, b"write c.txt last", b"Saved.\r\n")
        expect_command(console, b"write d.txt overflow", b"Data disk is full.\r\n")
        begin_upload(console, b"b.bin", 5001)
        console.send((payload + b"!").hex().encode() + b"\n.\n")
        expect_equal(console.read_until(PROMPT, timeout=20),
                     b"File exceeds the volume or application size limit.\r\n")
        expect_file_bytes(console, b"b.bin", payload)
        expect_command(console, b"write a.txt second", b"Saved.\r\n")
    saved = disk.read_bytes()
    expect_equal(saved[:512], initial[:512])
    for begin, end in gaps:
        expect_equal(saved[begin:end], initial[begin:end])
    # slot 1の第2世代はLBA48、本文は49から始まる。
    expect_equal(saved[48 * 512 + 10:48 * 512 + 15], b"b.bin")
    expect_equal(saved[49 * 512:49 * 512 + len(payload)], payload)
    with boot(qemu_command, disk) as (console, _):
        expect_file_bytes(console, b"b.bin", payload)
        expect_command(console, b"cat a.txt", b"second\r\n")
    damaged = bytearray(disk.read_bytes())
    damaged[10 * 512] ^= 1  # slot 0の新しい第1世代の本文だけを破損する。
    disk.write_bytes(damaged)
    with boot(qemu_command, disk) as (console, _):
        expect_command(console, b"cat a.txt", b"first\r\n")

    def fix_header_checksum(image):
        checksum = 2166136261
        for value in image[:40] + image[44:512]:
            checksum = ((checksum ^ value) * 16777619) & 0xFFFFFFFF
        struct.pack_into("<I", image, 40, checksum)

    # 構造の不正と単なるチェックサム不一致を別々に検査する。
    invalid_layouts = [(8, 4), (16, 0), (16, 17), (20, 16385), (24, 0),
                       (24, 0x0fffffff), (28, 1), (32, 99), (44, 1)]
    for index, (offset, value) in enumerate(invalid_layouts + [(40, 0)]):
        image = bytearray(initial)
        struct.pack_into("<I", image, offset, value)
        if offset != 40:
            fix_header_checksum(image)
        invalid = root / f"invalid-layout-{index}.img"
        invalid.write_bytes(image)
        with boot(qemu_command, invalid, disk_ready=False) as (console, _):
            expect_command(console, b"write a.txt forbidden", b"Data disk unavailable.\r\n")
        expect_equal(invalid.read_bytes(), image)


def verify_desktop_clock(qemu_command, root):
    disk = root / "rtc.img"
    format_disk(disk)
    command = [*qemu_command, "-rtc", "base=2024-02-29T12:34:00,clock=vm"]
    with boot(command, disk, with_qmp=True) as (console, qmp):
        screen = root / "rtc.ppm"
        background, foreground = bytes.fromhex("152843"), bytes.fromhex("ffffff")
        expect_text(qmp, screen, 660, 567, "2024-02-29", 1, background, foreground)
        expect_text(qmp, screen, 660, 583, "12:34:", 1, background, foreground)
        expect_text(qmp, screen, 724, 583, "    ", 1, background, foreground)
        # 入力なしのアイドル状態でも秒の表示が変わる。
        def seconds_pixels(width, data):
            return b"".join(data[((583 + row) * width + 708) * 3:
                                 ((583 + row) * width + 724) * 3] for row in range(14))
        before = qmp.capture(screen).split(b"\n", 3)
        width = int(before[1].split()[0])
        old = seconds_pixels(width, before[3])
        qmp.wait_screen(screen, "clock advances while idle",
                        lambda width, height, data: seconds_pixels(width, data) != old)
        expect_command(console, b"echo clock", b"clock\r\n")


def verify_close_deadline(qemu_command, root):
    disk = root / "close-deadline.img"
    format_disk(disk)
    with boot(qemu_command, disk, with_qmp=True) as (console, qmp):
        baseline = free_memory(console)
        put_file(console, b"gui_close.elf", (APP_DIRECTORY / "gui_close.elf").read_bytes())
        console.command(b"run gui_close.elf &\r")
        running, _ = wait_process_names(console, b"gui_close.elf")
        pid = next(iter(running))

        def wait_value(value):
            deadline = time.monotonic() + 6
            while time.monotonic() < deadline:
                tasks, _ = process_list(console)
                if pid not in tasks:
                    raise AssertionError(f"GUI was killed before publishing {value}")
                if tasks[pid][1] == value:
                    return
                time.sleep(0.02)
            raise AssertionError(f"GUI did not publish {value}: {tasks}")

        wait_value(1)
        qmp.keys("f10")
        wait_value(3)  # ゲスト内で1500 ms待ち、1000 msの期限を越えたことを確認する。
        qmp.keys("ret")
        wait_value(4)
        qmp.keys("f10")
        deadline = time.monotonic() + 6
        while True:
            tasks, _ = process_list(console)
            if pid not in tasks:
                break
            if tasks[pid][1] == 5:
                raise AssertionError("Clean unresponsive GUI survived its close deadline")
            if time.monotonic() >= deadline:
                raise AssertionError("Clean unresponsive GUI was not reaped")
            time.sleep(0.02)
        expect_equal(free_memory(console), baseline)


def verify_app_catalog(qemu_command, root):
    disk = root / "catalog.img"
    format_disk(disk)
    binary = (APP_DIRECTORY / "counter.elf").read_bytes().replace(b"Counter", b"Example")
    row = b"Clock|example.elf|generic|80|60|300|180|1|F8|-\n"
    writer = b"Writer|writer.elf|editor|220|90|468|340|2|F9|document\n"
    catalog = b"DLANGAPPS1\n" + row + writer
    with boot(qemu_command, disk) as (console, _):
        put_file(console, b"example.elf", binary)
        put_file(console, b"writer.elf", (APP_DIRECTORY / "editor.elf").read_bytes())
        put_file(console, b"desktop.apps", catalog)
    with boot(qemu_command, disk, with_qmp=True) as (console, qmp):
        screen = root / "catalog.ppm"
        qmp.keys("f8")  # 通常はEditorのキーだが、設定に従って未登録ELFを起動する。
        expect_text(qmp, screen, 90, 65, "Example", 1,
                    bytes.fromhex("135a56"), bytes.fromhex("ffffff"))
        qmp.until_pixel(screen, 379, 239, bytes.fromhex("135a56"))
        running, _ = wait_process_names(console, b"example.elf")
        # 設定ファイルを書き換えても、起動時のスナップショットが有効なまま。
        put_file(console, b"desktop.apps", b"broken")
        qmp.keys("f8", "f8")
        expect_equal(set(wait_process_names(console, b"example.elf")[0]), set(running))
        qmp.keys("f2")  # 文書担当もファイル名や登録順ではなく設定から選ぶ。
        wait_process_names(console, b"example.elf", b"writer.elf")
        qmp.keys("esc", "f10")
        wait_process_names(console, b"example.elf")
        qmp.keys("f10")
        wait_process_names(console)

    malformed = [
        b"DLANGAPPS1\n",  # 空登録
        b"DLANGAPPS2\n" + row,
        b"DLANGAPPS1\n" + row + row,  # 実行ファイル・キー重複
        b"DLANGAPPS1\n" + row + row.replace(b"example.elf", b"other.elf"),
        b"DLANGAPPS1\n" + writer + writer.replace(b"writer.elf", b"other.elf").replace(b"F9", b"F8"),
        b"DLANGAPPS1\n" + row.replace(b"300|180", b"99999999999999999|180"),
        b"DLANGAPPS1\n" + row.replace(b"300|180", b"0|180"),
        b"DLANGAPPS1\n" + row.replace(b"generic", b"unknown"),
        b"DLANGAPPS1\n" + row.replace(b"Clock", b"Cl\x00ck"),
        b"DLANGAPPS1\n" + row + b"incomplete",  # 有効な先頭行も適用しない。
        b"#" * 4097,
        b"DLANGAPPS1\n" + b"".join(
            row.replace(b"example.elf", f"app{i}.elf".encode()).replace(b"F8", b"-")
            for i in range(13)),
    ]
    # 直前のbrokenを起点に、拒否された設定でもシェルから次の設定を保存できる。
    for index in range(len(malformed) + 1):
        with boot(qemu_command, disk, with_qmp=True) as (console, qmp):
            screen = root / "invalid-catalog.ppm"
            error = "Cannot read desktop.apps; using default apps." if index and len(malformed[index - 1]) > 4096 else "Invalid desktop.apps; using default apps."
            expect_text(qmp, screen, 16, 541, error, 1,
                        bytes.fromhex("152843"), bytes.fromhex("ffffff"))
            qmp.keys("f8")
            expect_text(qmp, screen, 16, 541, "File not found.", 1,
                        bytes.fromhex("152843"), bytes.fromhex("ffffff"))
            expect_equal(process_list(console)[0], {})
            if index < len(malformed):
                put_file(console, b"desktop.apps", malformed[index])
            else:
                # 上限12件を受理し、CRLF・コメント・最終改行なしも扱う。
                full = b"# custom launcher\r\nDLANGAPPS1\r\n" + b"".join(
                    row.replace(b"example.elf", f"app{i}.elf".encode()).replace(b"F8", b"-")
                    for i in range(11)) + row.replace(b"80|60", b"-2048|2048").rstrip(b"\n")
                put_file(console, b"desktop.apps", full)
    with boot(qemu_command, disk, with_qmp=True) as (console, qmp):
        qmp.keys("f2")
        expect_text(qmp, root / "no-document-app.ppm", 16, 541,
                    "No document application is registered.", 1,
                    bytes.fromhex("152843"), bytes.fromhex("ffffff"))
        expect_equal(process_list(console)[0], {})
        qmp.keys("f1", "up", "ret")  # 12番目の登録へ折り返す。
        expect_text(qmp, root / "clamped-catalog.ppm", 22, 377, "Example", 1,
                    bytes.fromhex("135a56"), bytes.fromhex("ffffff"))
        wait_process_names(console, b"example.elf")
        qmp.keys("f10")
        wait_process_names(console)


def verify_external_gui(qemu_command, root):
    disk = root / "external-gui.img"
    format_disk(disk)
    # 未登録の別名・別タイトルでも、共通guiCreateで窓を作れる。
    binary = (APP_DIRECTORY / "counter.elf").read_bytes()
    expect_equal(binary.count(b"Counter"), 1)
    binary = binary.replace(b"Counter", b"Example")
    with boot(qemu_command, disk, with_qmp=True) as (console, qmp):
        put_file(console, b"example.elf", binary)
        screen = root / "external-gui.ppm"
        baseline = qmp.capture(screen).split(b"\n", 3)
        width = int(baseline[1].split()[0])
        offset = (115 * width + 510) * 3
        background = baseline[3][offset:offset + 3]
        response = console.command(b"run example.elf &\r")
        if re.fullmatch(rb"run example.elf &\r\nStarted PID [0-9]+\r\n", response) is None:
            raise AssertionError(response)
        expect_text(qmp, screen, 518, 118, "Example", 1,
                    bytes.fromhex("135a56"), bytes.fromhex("ffffff"))
        running, totals = wait_process_names(console, b"example.elf")
        pid = next(iter(running))
        qmp.keys("ret")
        expect_text(qmp, screen, 522, 172, "Paused", 2, bytes.fromhex("ffffff"))
        assert_quiescent(console, pid)
        qmp.keys("f10")
        _, after = wait_process_names(console)
        expect_equal(after, (totals[0] + 1, totals[1]))
        # 閉じた後に窓が残らず、背景へ戻ることを確認する。
        qmp.until_pixel(screen, 510, 115, background)


def verify_storage_discovery(qemu_command, root):
    unrelated = root / "unrelated.img"
    untouched = b"OTHERIMG" + bytes(1024 * 1024 - 8)
    unrelated.write_bytes(untouched)
    # primary slave、secondary master/slaveでも同じファイル操作が成立する。
    for index in (1, 2, 3):
        disk = root / f"ide-position-{index}.img"
        format_disk(disk)
        options = dict(drive_index=index, extra_drives=((0, unrelated),))
        with boot(qemu_command, disk, **options) as (console, _):
            expect_command(console, b"write location.txt discovered", b"Saved.\r\n")
        with boot(qemu_command, disk, **options) as (console, _):
            expect_command(console, b"cat location.txt", b"discovered\r\n")
        expect_equal(unrelated.read_bytes(), untouched)

    # 候補が複数あればv1の移行も始めず、どちらのディスクにも書かない。
    first = root / "ambiguous-v1.img"
    second = root / "ambiguous-v3.img"
    first.write_bytes(old_disk_image())
    format_disk(second)
    originals = (first.read_bytes(), second.read_bytes())
    with boot(qemu_command, first, disk_ready=False, extra_drives=((1, second),)) as (console, _):
        expect_command(console, b"write forbidden.txt no", b"Data disk unavailable.\r\n")
    expect_equal((first.read_bytes(), second.read_bytes()), originals)

    # 正しいヘッダでも、IDENTIFYの実容量を越えるレイアウトは拒否する。
    small = root / "truncated-volume.img"
    format_disk(small)
    small.write_bytes(small.read_bytes()[:512])
    before = small.read_bytes()
    with boot(qemu_command, small, disk_ready=False) as (console, _):
        expect_command(console, b"write forbidden.txt no", b"Data disk unavailable.\r\n")
    expect_equal(small.read_bytes(), before)


def main(qemu_command):
    with tempfile.TemporaryDirectory(prefix="dlang-") as directory:
        root = Path(directory)
        disk = root / "data.img"
        format_disk(disk)
        with boot(qemu_command, disk, with_qmp=True) as (console, qmp):
            verify_shell(console)
            verify_files(console)
            verify_processes(console)
            verify_desktop_without_apps(console, qmp, root / "screen.ppm")
        install_desktop_apps(qemu_command, disk)
        with boot(qemu_command, disk, with_qmp=True) as (console, qmp):
            verify_desktop_reads_disk(console, qmp, root / "screen.ppm")
            qmp.keys("esc")  # ファイルの起動エラー表示を閉じて、初期画面を確認する。
            verify_desktop(console, qmp, root / "screen.ppm")
            verify_windows(console, qmp, root / "screen.ppm")
            verify_new_apps(console, qmp, root / "screen.ppm")
            verify_disk_elf(console)

        # 実験用ELFとデスクトップ用ELFで、16ファイルの枠を取り合わないようにする。
        experiments = root / "experiments.img"
        experiments.write_bytes(b"DLANGFS2" + bytes(1024 * 1024 - 8))
        with boot(qemu_command, experiments) as (console, _):
            baseline_memory = free_memory(console)
            verify_sleep(console)
            verify_virtual_memory(console)
            verify_d_initialization(console)
            verify_d_heap(console)
            verify_d_exceptions(console)
            verify_d_arrays(console)
            verify_phobos(console)
            expect_equal(free_memory(console), baseline_memory)

        # ディスクを差し直し、GUIの保存とシェルの削除が残ることを確認する。
        with boot(qemu_command, disk, with_qmp=True) as (console, qmp):
            expect_command(console, b"cat copy.txt", b"hello\r\ndlang\r\nold\r\n")
            expect_command(console, b"cat mouse.txt", b"hello\r\ndlang\r\noldxy\r\n")
            expect_command(console, b"cat removed.txt", b"File not found.\r\n")
            expect_command(console, b"cat history.txt", b"second version\r\n")
            run_hello(console)
            verify_counter_reads_disk(console, qmp, root / "screen.ppm")
            verify_file_window(console, qmp, root / "screen.ppm")
            verify_halt(console)

        # 新版の本文だけを破損させ、再マウントで旧版に戻ることを検証する。
        content = disk.read_bytes()
        damaged = content.index(b"second version")
        with disk.open("r+b") as image:
            image.seek(damaged)
            image.write(b"!")
        with boot(qemu_command, disk) as (console, _):
            expect_command(console, b"cat history.txt", b"first version\r\n")

        unknown_disk = root / "unknown.img"
        unknown_data = b"OTHERIMG" + bytes(1024 * 1024 - 8)
        unknown_disk.write_bytes(unknown_data)
        with boot(qemu_command, unknown_disk, disk_ready=False) as (console, _):
            expect_command(console, b"write notes.txt hello", b"Data disk unavailable.\r\n")
        expect_equal(unknown_disk.read_bytes(), unknown_data)
        verify_migration_and_large_files(qemu_command, root)
        verify_volume_layout(qemu_command, root)
        verify_storage_discovery(qemu_command, root)
        verify_external_gui(qemu_command, root)
        verify_app_catalog(qemu_command, root)
        verify_close_deadline(qemu_command, root)
        verify_desktop_clock(qemu_command, root)

    print("PASS: QEMU Ring 3 desktop apps, disk ELF, D initialization, heap, arrays, exceptions, Phobos vectors, Counter events, v1 migration, persistence, and disk recovery")


if __name__ == "__main__":
    main(sys.argv[1:])
