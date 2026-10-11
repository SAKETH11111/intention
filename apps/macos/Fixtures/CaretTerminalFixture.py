"""Synthetic raw-terminal editor. It accepts only fixture keys and saves counts."""

import json
import os
from pathlib import Path
import select
import sys
import termios
import time
import tty

root = Path(sys.argv[1])
length = position = keys = 0
original = termios.tcgetattr(sys.stdin)
(root / "terminal-process.json").write_text(json.dumps({"pid": os.getpid()}))


def paint():
    # Leave space above each line for the indicator. Cursor movement and the
    # blinking beam are rendered by Terminal.app itself, not by this fixture.
    out = "\033[2J\033[HSynthetic Intention terminal fixture"
    for start in range(0, length, 30):
        out += f"\033[{4 + start // 30};4H" + "i" * min(30, length - start)
    out += f"\033[{4 + position // 30};{4 + position % 30}H\033[5 q\033[?25h"
    sys.stdout.write(out)
    sys.stdout.flush()
    temporary = root / "terminal-receipt.tmp"
    temporary.write_text(json.dumps({"length": length, "caret": position, "keys": keys}))
    os.replace(temporary, root / "terminal-receipt.json")


try:
    tty.setraw(sys.stdin)
    paint()
    pending = b""
    deadline = time.monotonic() + 75
    while time.monotonic() < deadline and not (root / "terminal-stop").exists():
        if not select.select([sys.stdin], [], [], 0.1)[0]:
            continue
        pending += os.read(sys.stdin.fileno(), 64)
        while pending:
            if pending.startswith(b"\x1b") and len(pending) < 3:
                break
            if pending.startswith(b"\x1b[D"):
                position = max(0, position - 1)
                pending = pending[3:]
            elif pending.startswith(b"\x1b[C"):
                position = min(length, position + 1)
                pending = pending[3:]
            else:
                byte, pending = pending[0], pending[1:]
                if byte == ord("i"):
                    length += 1
                    position += 1
                    keys += 1
                elif byte in (8, 127) and position > 0:
                    length -= 1
                    position -= 1
                # No arbitrary input is retained or echoed, including Return.
            paint()
finally:
    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, original)
    (root / "terminal-stopped.json").write_text(json.dumps({"pid": os.getpid()}))
