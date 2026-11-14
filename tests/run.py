#!/usr/bin/env python3
"""Run the Lua test suite for sgm-suno-workflow."""

import subprocess
import sys
from pathlib import Path

def main():
    repo_root = Path(__file__).resolve().parent.parent
    cmd = ["lua5.4", "tests/run_tests.lua"]
    result = subprocess.run(cmd, cwd=repo_root)
    sys.exit(result.returncode)

if __name__ == "__main__":
    main()
