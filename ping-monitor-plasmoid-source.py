#!/usr/bin/env python3
"""Emit the current ping-monitor state file for the plasmoid."""

from __future__ import annotations

import os
from pathlib import Path
import sys


STATE_PATH = Path(f"/run/user/{os.getuid()}/ping-monitor-state")


def main() -> int:
    try:
        sys.stdout.write(STATE_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
