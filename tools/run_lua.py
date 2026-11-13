#!/usr/bin/env python3
"""Run tests/run_tests.lua with an embedded Lua 5.4 interpreter.

Lets the suite run in environments that have no `lua` binary (pip install lupa).
"""
import sys, os
try:
    from lupa import lua54
except ImportError:
    sys.exit("lupa is not installed (pip install lupa), or run: lua5.4 tests/run_tests.lua")

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)

L = lua54.LuaRuntime(unpack_returned_tuples=True)
L.globals()["EMBEDDED"] = True
L.globals()["arg"] = "tests/run_tests.lua"
ok = L.execute(open(os.path.join(root, "tests", "run_tests.lua")).read())
sys.exit(0 if ok else 1)
