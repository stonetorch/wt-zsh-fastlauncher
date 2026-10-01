"""
Ink-style frame emitter for psmux issue #246 reproduction.

Emits "logical frames" that consist of:
  1. Cursor home + clear screen
  2. For each row in the visible area:
       ESC[row;1H  ESC[2K  (move + clear line)
       ESC[row;C1H "TEXT1"
       ESC[row;C2H "TEXT2"
       ...

A single frame intentionally exceeds 64 KB so that ConPTY/stdin splits it across
multiple reader.read() calls inside psmux. Each row is "logically full" (we write
many text spans across it) so the EXPECTED final state of every row is dense.

If psmux's snapshot grabs the parser mutex between two read() calls within a
single logical frame, a row will appear with only a SPARSE subset of its expected
characters, with the rest being blank (because ESC[2K cleared it first and only
some of the CUP+text spans have been processed).

Each frame has a unique 4-digit FRAME tag printed in column 1 of row 1, so the
hammer can correlate observed snapshots with the emitted frame number.
"""
import sys
import time

ESC = "\x1b"
ROWS = 30          # rows we paint
COLS = 200         # column span we paint into
SPANS_PER_ROW = 80 # number of CUP+text spans per row -> dense by end of frame
PAD_PER_FRAME = 70_000  # padding (DECSC/DECRC pairs) so each frame > 64 KB

# Pre-build a padding blob made of harmless cursor save/restore sequences.
# These do not change the visible grid but inflate the frame size so it is
# guaranteed to span multiple ConPTY read() calls.
PAD_UNIT = ESC + "7" + ESC + "8"  # save / restore cursor
PAD_BLOB = PAD_UNIT * (PAD_PER_FRAME // len(PAD_UNIT))


def build_frame(frame_no: int) -> str:
    parts = []
    a = parts.append
    # Clear screen + home
    a(f"{ESC}[H{ESC}[2J")
    # Frame tag at row 1
    a(f"{ESC}[1;1H[FRAME {frame_no:06d}]")

    for row in range(2, 2 + ROWS):
        # Clear line first (this is the dangerous step: if we are interrupted
        # right after this and before the spans land, the row appears empty).
        a(f"{ESC}[{row};1H{ESC}[2K")

        # Insert padding mid-row to inflate the frame past 64 KB.
        a(PAD_BLOB)

        # Now write SPANS_PER_ROW dense spans across the row.
        for i in range(SPANS_PER_ROW):
            col = 1 + (i * (COLS // SPANS_PER_ROW))
            a(f"{ESC}[{row};{col}H#{i:02d}")

    # Park cursor off-screen-ish at end so we don't see the prompt overwriting.
    a(f"{ESC}[{2 + ROWS};1H")
    return "".join(parts)


def main():
    n_frames = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    inter_frame_ms = int(sys.argv[2]) if len(sys.argv) > 2 else 30

    out = sys.stdout
    write = out.write
    flush = out.flush

    # Make stdout binary-ish: avoid line buffering.
    try:
        sys.stdout.reconfigure(line_buffering=False, write_through=True)
    except Exception:
        pass

    for n in range(n_frames):
        frame = build_frame(n)
        write(frame)
        flush()
        if inter_frame_ms > 0:
            time.sleep(inter_frame_ms / 1000.0)

    # Final marker so the test knows emission is done.
    write(f"\r\n[EMIT_DONE frames={n_frames}]\r\n")
    flush()


if __name__ == "__main__":
    main()
