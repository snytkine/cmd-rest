#!/usr/bin/env bash
#
# hook1.sh — success test hook.
#
# The application invokes script hooks with each parameter as its own argv
# element in "key=value" form (see hooks-feature.md). This script writes every
# received parameter, one "key=value" per line, to hook1params.txt (in the
# current working directory), prints a confirmation to stdout, and exits 0.
#
# Notes:
#   - Arguments are always quoted ("$arg") so spaces / special characters in a
#     value are preserved and never re-interpreted by the shell.
#   - Arguments are never passed to eval.

set -euo pipefail

OUT_FILE="hook1params.txt"

# Truncate (or create) the output file so each run starts fresh.
: >"$OUT_FILE"

# Persist every argument verbatim, one per line.
for arg in "$@"; do
  printf '%s\n' "$arg" >>"$OUT_FILE"
done

echo "Test Hook executed"

exit 0
