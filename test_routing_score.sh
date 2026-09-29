#!/usr/bin/env bash
# Complete guideline audit for this AS102 lab. See --help for modes.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$script_dir/guideline_audit.py" "$@"
