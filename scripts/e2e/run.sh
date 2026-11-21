#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
umask 077
python="$HOME/tools/novnc-venv/bin/python"
[[ -x "$python" ]] || python=python3
exec "$python" -B "$script_dir/run.py" "$@"
