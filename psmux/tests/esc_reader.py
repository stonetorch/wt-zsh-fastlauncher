"""
esc_reader.py - deterministic child for reproducing psmux issue #380.

Runs inside a psmux pane. Enables the SAME console input mode that real TUI
apps (Neovim, Claude Code) turn on a moment after launch:
    ENABLE_VIRTUAL_TERMINAL_INPUT (0x0200), with line/echo/processed input OFF.

Then it reads raw bytes from stdin and appends the hex of every byte to a log
file, flushing after each read. If a bare <Esc> (0x1b) reaches the child, the
log will contain "1b". If ConPTY's WIN32_INPUT_MODE parser swallows the piped
lone ESC, the log will NOT contain it.

Usage: python esc_reader.py <logfile>
Press 'q' to quit.
"""
import os
import sys
import ctypes
from ctypes import wintypes

logpath = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TEMP", "."), "esc_reader.log")

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
STD_INPUT_HANDLE = -10
ENABLE_PROCESSED_INPUT = 0x0001
ENABLE_LINE_INPUT = 0x0002
ENABLE_ECHO_INPUT = 0x0004
ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200

hIn = k32.GetStdHandle(STD_INPUT_HANDLE)
old = wintypes.DWORD()
k32.GetConsoleMode(hIn, ctypes.byref(old))

# Raw + VT input, exactly like a real TUI app.
new_mode = ENABLE_VIRTUAL_TERMINAL_INPUT
ok = k32.SetConsoleMode(hIn, new_mode)

with open(logpath, "w") as f:
    f.write("READER_START old_mode=0x%04x set_ok=%s new_mode=0x%04x\n" % (old.value, bool(ok), new_mode))
    f.flush()

# Read raw bytes and log hex of each.
while True:
    try:
        data = os.read(0, 64)
    except OSError as e:
        with open(logpath, "a") as f:
            f.write("READ_ERR %s\n" % e)
            f.flush()
        break
    if not data:
        continue
    hexbytes = " ".join("%02x" % b for b in data)
    with open(logpath, "a") as f:
        f.write("RX %s\n" % hexbytes)
        f.flush()
    if b"q" in data:
        with open(logpath, "a") as f:
            f.write("READER_QUIT\n")
            f.flush()
        break
