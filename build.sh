#!/bin/sh
# Compact build/test output: only diagnostics and the final verdict.
swift "${1:-build}" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g; s/\x1b\\]8;;[^\x1b]*\x1b\\\\//g' | grep -E "^/.*(error|warning):|Build complete|error: |Executed|failed|passed" | grep -v "GlanzowTests.*passed" | sort -u | head -60
