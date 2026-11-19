#!/usr/bin/env python3
"""Build the single-file installer.

install.sh is what users download (curl | bash), so it stays ONE file. Its source of truth is split into real files:

    installer/install.sh.in      the installer skeleton (steps, config); big blocks are placeholders
    panel/app.py                 panel backend (Python)
    panel/index.html             panel UI markup + CSS (the script is a placeholder)
    panel/ui.js                  panel UI logic (JavaScript)
    scripts/*                    helper scripts installed to /usr/local/bin
    systemd/*.service            systemd units

A placeholder is a whole line:   @@INCLUDE relative/path@@   (replaced by that file's content, recursively).

usage:  python3 tools/build.py            write install.sh
        python3 tools/build.py --check    exit 1 if install.sh is not up to date (use before committing)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "installer", "install.sh.in")
OUT = os.path.join(ROOT, "install.sh")
INC = re.compile(r"^@@INCLUDE (\S+)@@$")


def expand(text, trail=()):
    out = []
    for line in text.split("\n"):
        m = INC.match(line)
        if not m:
            out.append(line)
            continue
        rel = m.group(1)
        if rel in trail:
            raise SystemExit("include loop: " + " -> ".join(trail + (rel,)))
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            body = f.read()
        if body.endswith("\n"):
            body = body[:-1]
        out.append(expand(body, trail + (rel,)))
    return "\n".join(out)


def build():
    with open(SRC, encoding="utf-8") as f:
        return expand(f.read())


if __name__ == "__main__":
    result = build()
    if "--check" in sys.argv:
        with open(OUT, encoding="utf-8") as f:
            current = f.read()
        if current != result:
            sys.stderr.write("install.sh is out of date: run ./build.sh and commit the result\n")
            sys.exit(1)
        print("install.sh is up to date")
    else:
        with open(OUT, "w", encoding="utf-8", newline="\n") as f:
            f.write(result)
        print("wrote install.sh (%d lines)" % (result.count("\n") + 1))
