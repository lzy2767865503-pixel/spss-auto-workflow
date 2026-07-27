#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv"
FRONTEND="$ROOT/frontend"
PYTHON="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "Python 3 was not found." >&2
  exit 1
fi

if ! "$PYTHON" -c 'import sys; raise SystemExit(sys.version_info < (3, 9))'; then
  echo "Python 3.9 or newer is required." >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm was not found. Install Node.js 20 or newer." >&2
  exit 1
fi

selected_python="$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [[ -x "$VENV/bin/python" ]]; then
  venv_python="$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  if [[ "$selected_python" != "$venv_python" ]]; then
    echo "Existing .venv uses Python $venv_python, but PYTHON_BIN selects $selected_python." >&2
    echo "Move or remove .venv, then run the verifier again to rebuild it." >&2
    exit 1
  fi
fi

if [[ ! -x "$VENV/bin/python" ]]; then
  "$PYTHON" -m venv "$VENV"
fi

"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install -r "$ROOT/requirements.lock.txt"
"$VENV/bin/python" -m unittest discover -s "$ROOT/tests" -v

(
  cd "$FRONTEND"
  npm ci
  npm run build
)

test -f "$FRONTEND/dist/index.html"
echo "Reproducibility verification passed."
