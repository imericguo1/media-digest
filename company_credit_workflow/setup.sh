#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="/Users/Eric/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"

if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="python3"
fi

"$PYTHON_BIN" -m pip install --user --upgrade playwright
"$PYTHON_BIN" -m playwright install chromium

echo "安装完成。"
