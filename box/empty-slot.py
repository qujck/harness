#!/usr/bin/env python3
"""An empty Delivery slot: shows "empty slot" in the middle of the pane instead of a shell prompt.

Started by restore-claude.sh and delivery-sync.py in every Delivery gap. It starts no child process, so
delivery-sync.py still sees the pane as an idle gap it may remove. Press Enter in it to get a shell.
"""
import os
import select
import shutil
import signal
import sys
import termios
import tty

LABEL = "empty slot"


def draw(*_):
    cols, rows = shutil.get_terminal_size()
    pad = " " * max(0, (cols - len(LABEL)) // 2)
    sys.stdout.write("\033[2J\033[H\033[?25l" +"\n" * max(0, (rows - 1) // 2) + f"{pad}\033[2m{LABEL}\033[0m")
    sys.stdout.flush()


def main():
    signal.signal(signal.SIGWINCH, draw)
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setcbreak(fd)
    draw()
    try:
        while True:
            try:
                ready, _, _ = select.select([fd], [], [])
            except InterruptedError:
                continue
            if ready and os.read(fd, 1) in (b"\r", b"\n"):
                break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\033[2J\033[H\033[?25h")
        sys.stdout.flush()
    os.chdir(os.path.expanduser("~"))
    os.execvp("bash", ["bash"])


if __name__ == "__main__":
    main()
