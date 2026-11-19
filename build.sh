#!/usr/bin/env bash
# Rebuild the single-file installer (install.sh) from the real source files.  ./build.sh [--check]
cd "$(dirname "$0")" && exec python3 tools/build.py "$@"
