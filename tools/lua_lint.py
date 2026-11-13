#!/usr/bin/env python3
"""Small, dependency-free Lua linter for ReaScripts.

Catches the classes of mistake that a syntax check and a mocked test run miss:

  * undefined globals  — reading a name that is never declared. This is the bug
                         class that made `lfs` a landmine and it also catches
                         simple typos in variable names.
  * unused locals      — declared, never referenced again.
  * deprecated API     — REAPER functions documented as superseded, plus known
                         non-existent API names.

Design: a real tokenizer (comments/strings/numbers handled) plus a scope walker
that pushes/pops on `function`/`do`/`if`/`repeat` … `end`/`until`, declares
`local`, `for` and parameter names, and ignores member access (`a.b`, `a:b`),
table keys (`k = v`) and labels. Conservative by construction: findings are
things that are certainly wrong.

Usage:
    python3 tools/lua_lint.py FILE.lua [FILE.lua ...]
Exit status: 0 = clean, 1 = findings.
"""
from __future__ import annotations

import re
import sys

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
}

BUILTINS = {
    "_G", "_VERSION", "assert", "collectgarbage", "dofile", "error", "getmetatable",
    "ipairs", "load", "loadfile", "next", "pairs", "pcall", "print", "rawequal",
    "rawget", "rawlen", "rawset", "require", "select", "setmetatable", "tonumber",
    "tostring", "type", "xpcall", "coroutine", "debug", "io", "math", "os",
    "package", "string", "table", "utf8", "arg", "self",
}

# Provided by the host at runtime (REAPER / ReaImGui / gfx).
HOST_GLOBALS = {"reaper", "gfx", "ImGui"}

DEPRECATED = {
    "AddTempoTimeSigMarker": "supplanted by SetTempoTimeSigMarker (ptidx = -1)",
    "MediaItemTake_GetPeaks": "does not exist — the API function is GetMediaItemTake_Peaks",
    "GetTempPath": "does not exist in the REAPER API",
}

TOKEN_RE = re.compile(r"""
      (?P<ws>\s+)
    | (?P<number>0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)
    | (?P<name>[A-Za-z_]\w*)
    | (?P<op>\.\.\.|\.\.|==|~=|<=|>=|//|<<|>>|::)
    | (?P<char>.)
""", re.VERBOSE)


def blank_noise(src: str) -> str:
    """Replace comments and strings with spaces, keeping newlines (for lines)."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                end = src.find(close, i + len(m.group(0)))
                end = n if end == -1 else end + len(close)
            else:
                end = src.find("\n", i)
                end = n if end == -1 else end
            out.append(re.sub(r"[^\n]", " ", src[i:end]))
            i = end
        elif c == "[" and re.match(r"\[(=*)\[", src[i:]):
            m = re.match(r"\[(=*)\[", src[i:])
            close = "]" + m.group(1) + "]"
            end = src.find(close, i + len(m.group(0)))
            end = n if end == -1 else end + len(close)
            out.append(re.sub(r"[^\n]", " ", src[i:end]))
            i = end
        elif c in "\"'":
            q, j = c, i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == q or src[j] == "\n":
                    break
                j += 1
            out.append(" " * (min(j + 1, n) - i))
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def tokenize(code: str):
    toks = []
    for m in TOKEN_RE.finditer(code):
        kind = m.lastgroup
        if kind == "ws":
            continue
        value = m.group(0)
        line = code.count("\n", 0, m.start()) + 1
        toks.append((kind, value, line))
    return toks


def lint(path: str, src: str) -> list[str]:
    code = blank_noise(src)
    toks = tokenize(code)
    problems: list[str] = []

    scopes: list[set[str]] = [set()]
    declared_sites: dict[str, int] = {}

    def declare(name: str):
        scopes[-1].add(name)
        declared_sites[name] = declared_sites.get(name, 0) + 1

    def is_declared(name: str) -> bool:
        return any(name in s for s in scopes)

    def tok(i: int):
        return toks[i] if 0 <= i < len(toks) else (None, None, 0)

    # ── scope walk ───────────────────────────────────────────────────────────
    i = 0
    while i < len(toks):
        kind, value, line = toks[i]

        if kind == "name" and value in KEYWORDS:
            if value == "local":
                j = i + 1
                if tok(j)[1] == "function":
                    # Declare the name, then let the `function` branch below
                    # push the scope and declare the parameters.
                    if tok(j + 1)[0] == "name":
                        declare(tok(j + 1)[1])
                    i = j
                    continue
                else:
                    while tok(j)[0] == "name":
                        declare(tok(j)[1])
                        j += 1
                        if tok(j)[1] == ",":
                            j += 1
                            continue
                        break
                i = j
                continue

            if value == "for":
                j = i + 1
                while tok(j)[0] == "name":
                    declare(tok(j)[1])
                    j += 1
                    if tok(j)[1] == ",":
                        j += 1
                        continue
                    break
                i = j
                continue

            if value == "function":
                # Find the parameter list, declare the params in a new scope.
                j = i + 1
                while j < len(toks) and tok(j)[1] != "(":
                    j += 1
                if tok(j)[1] == "(":
                    scopes.append(set())
                    j += 1
                    while tok(j)[0] == "name":
                        declare(tok(j)[1])
                        j += 1
                        if tok(j)[1] == ",":
                            j += 1
                            continue
                        break
                i = j
                continue

            if value in ("do", "if", "repeat"):
                scopes.append(set())
                i += 1
                continue

            if value in ("end", "until"):
                if len(scopes) > 1:
                    scopes.pop()
                i += 1
                continue

            if value == "goto":
                i += 2      # skip the label name
                continue

            i += 1
            continue

        if kind == "name":
            prev_kind, prev_val, _ = tok(i - 1)
            next_kind, next_val, _ = tok(i + 1)
            # member access / method call
            if prev_val in (".", ":"):
                i += 1
                continue
            # label  ::name::
            if prev_val == "::" or next_val == "::":
                i += 1
                continue
            # table key or assignment target
            if next_val == "=":
                i += 1
                continue
            if not is_declared(value) and value not in BUILTINS and value not in HOST_GLOBALS:
                snippet = code.splitlines()[line - 1].strip()[:80] if line - 1 < len(code.splitlines()) else ""
                problems.append(f"{path}:{line}: undefined global '{value}'   [{snippet}]")
            i += 1
            continue

        i += 1

    # ── unused locals (file level; shadowed names skipped) ───────────────────
    counts: dict[str, int] = {}
    for kind, value, _ in toks:
        if kind == "name":
            counts[value] = counts.get(value, 0) + 1
    for name, sites in declared_sites.items():
        if name.startswith("_") or sites > 1:
            continue
        if counts.get(name, 0) <= sites:
            problems.append(f"{path}: local '{name}' is declared but never used")

    # ── deprecated / non-existent API ────────────────────────────────────────
    for idx, (kind, value, line) in enumerate(toks):
        if value == "reaper" and idx + 2 < len(toks) and toks[idx + 1][1] == ".":
            api = toks[idx + 2][1]
            if api in DEPRECATED:
                problems.append(f"{path}:{line}: '{api}' — {DEPRECATED[api]}")

    return problems


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    findings: list[str] = []
    for path in argv[1:]:
        with open(path, encoding="utf-8") as fh:
            findings.extend(lint(path, fh.read()))
    for f in findings:
        print(f)
    if findings:
        print(f"\n{len(findings)} lint finding(s)")
        return 1
    print(f"lint OK ({len(argv) - 1} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
