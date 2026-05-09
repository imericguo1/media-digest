#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="/Users/Eric/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"

if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="python3"
fi

if [ "$#" -lt 1 ]; then
  echo "用法: $0 公司名单.xlsx|公司名单.csv"
  exit 1
fi

"$PYTHON_BIN" "$ROOT_DIR/gsxt_workflow.py" "$@"
