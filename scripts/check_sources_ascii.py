# -*- coding: utf-8 -*-
r"""
Fail if any of OUR C sources contains a non-ASCII byte.

    python scripts/check_sources_ascii.py

WHY THIS EXISTS
    clang on a Chinese Windows build machine decodes source files as GBK unless
    told otherwise, so a non-ASCII byte inside a comment or a string is a
    minefield: it may compile, it may warn, and it may silently mangle whatever
    it is next to.

    ⚠️ THIS IS NOT HYPOTHETICAL AND NOT A STYLE PREFERENCE. The author of this
    file put a warning emoji into launcher.c TWICE in one day -- once while
    editing an options-path comment and once while documenting a bug -- and both
    times the build SUCCEEDED, which is the dangerous part: nothing failed, the
    defect just sat in the source waiting for a different compiler or a different
    code page to misread it. A three-strikes rule is not a rule.

    Tools that place emoji in prose (markdown, chat) train exactly this mistake,
    so the check is cheaper than the discipline.

WHAT IS CHECKED
    Only this project's own C and C++ sources -- the files directly in
    entry/src/main/cpp and its include/ directory. The vendored SDL tree is not
    checked: it is upstream code, it is not edited here, and it is large.

    ArkTS and resources are NOT checked, and must not be: .ets files and
    resources/**/string.json are UTF-8 by definition and contain Chinese on
    purpose.

Exit code 0 when clean, 1 when a file has a non-ASCII byte, naming the line.
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CPP = os.path.join(ROOT, "entry", "src", "main", "cpp")

SUFFIXES = (".c", ".h", ".cpp", ".cc")


def our_sources():
    """Our own sources: cpp/ and cpp/include/, not the vendored SDL tree."""
    out = []
    for d in (CPP, os.path.join(CPP, "include")):
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            full = os.path.join(d, name)
            if os.path.isfile(full) and name.endswith(SUFFIXES):
                out.append(full)
    return out


def main():
    bad = 0
    checked = 0
    for path in our_sources():
        checked += 1
        with io.open(path, "rb") as f:
            data = f.read()
        offenders = [i for i, b in enumerate(data) if b > 127]
        if not offenders:
            continue
        bad += 1
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        # Group by line so one line with six emoji bytes reports once.
        lines = sorted(set(data[:i].count(b"\n") + 1 for i in offenders))
        print("  !! %s" % rel)
        for n in lines[:8]:
            text = data.split(b"\n")[n - 1]
            count = sum(1 for b in text if b > 127)
            print("       line %d: %d non-ASCII byte(s)" % (n, count))
        if len(lines) > 8:
            print("       ... and %d more line(s)" % (len(lines) - 8))

    if bad:
        print()
        print("FAIL -- %d of %d source(s) contain non-ASCII bytes." % (bad, checked))
        print("clang decodes these as GBK on a Chinese Windows machine. Replace the")
        print("byte with ASCII: 'WARNING:' instead of a warning sign, '->' instead of")
        print("an arrow, and so on. Emoji belong in the commit message, not in C.")
        return 1

    print("OK -- %d source(s) checked, all pure ASCII" % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
