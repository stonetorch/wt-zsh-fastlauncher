"""
esc_reader2.py - CPR-aware child for reproducing psmux issue #380.

Runs inside a psmux pane. Enables ENABLE_VIRTUAL_TERMINAL_INPUT (like Neovim /
Claude Code / pwsh do). Logs every byte received from stdin with a timestamp.

Control protocol (bytes injected as keystrokes by the driver):
  'p'  -> child writes ESC[6n (a cursor-position / DSR probe) to stdout.
          psmux's server answers with ESC[row;colR written into the PTY pipe.
          Per issue #380 this reply corrupts ConPTY's WIN32_INPUT_MODE input
          parser and swallows the NEXT keystroke (notably a bare <Esc>).
  0x1b -> a bare <Esc> we want delivered.
  'q'  -> quit.

A bare <Esc> shows up in the log as a line exactly "RX 1b".
A CPR reply shows up as a multi-byte line "RX 1b 5b ... 52".
"""
import os
import sys
import time
import ctypes
from ctypes import wintypes

logpath = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TEMP", "."), "esc_reader2.log")

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
STD_INPUT_HANDLE = -10
ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200

hIn = k32.GetStdHandle(STD_INPUT_HANDLE)
old = wintypes.DWORD()
k32.GetConsoleMode(hIn, ctypes.byref(old))
ok = k32.SetConsoleMode(hIn, ENABLE_VIRTUAL_TERMINAL_INPUT)

t0 = time.time()
def logline(s):
    with open(logpath, "a") as f:
        f.write("[%08.3f] %s\n" % (time.time() - t0, s))
        f.flush()

with open(logpath, "w") as f:
    f.write("READER_START old_mode=0x%04x set_ok=%s new_mode=0x0200\n" % (old.value, bool(ok)))
    f.flush()

while True:
    try:
        data = os.read(0, 64)
    except OSError as e:
        logline("READ_ERR %s" % e)
        break
    if not data:
        continue
    logline("RX " + " ".join("%02x" % b for b in data))
    if b"p" in data:
        # Emit a DSR / cursor-position-report probe, like a TUI app does after launch.
        sys.stdout.write("\x1b[6n")
        sys.stdout.flush()
        logline("SENT_CPR ESC[6n")
    if b"q" in data:
        logline("READER_QUIT")
        break
