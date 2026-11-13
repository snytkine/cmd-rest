#!/usr/bin/env bash
#
# hook2.sh — failure test hook.
#
# The application invokes script hooks with each parameter as its own argv
# element in "key=value" form (see hooks-feature.md). This script echoes every
# received parameter back to stdout, one "key=value" per line, also saves them
# to hook2params.txt (in the current working directory), writes a failure
# message to stderr, and exits with a non-zero status (1) so the hook is treated
# as failed.
#
# Notes:
#   - Arguments are always quoted ("$arg") so spaces / special characters in a
#     value are preserved and never re-interpreted by the shell.
#   - Arguments are never passed to eval.

set -uo pipefail

OUT_FILE="hook2params.txt"

# Truncate (or create) the output file so each run starts fresh.
: >"$OUT_FILE"

# Echo every argument verbatim, one "key=value" per line, to stdout and persist
# it to the output file.
for arg in "$@"; do
  printf '%s\n' "$arg"
  printf '%s\n' "$arg" >>"$OUT_FILE"
done

echo "Hook Failed" >&2

exit 1
