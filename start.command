#!/bin/zsh

set -e

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$APP_DIR/.venv"
FRONTEND_DIR="$APP_DIR/frontend"
PYTHON_CANDIDATE="${PYTHON_BIN:-$(command -v python3)}"
PORT="${SPSS_AUTO_PORT:-8765}"
APP_URL="http://127.0.0.1:$PORT"

if curl --silent --fail "$APP_URL/api/health" >/dev/null 2>&1; then
  open "$APP_URL"
  exit 0
fi

if [[ -z "$PYTHON_CANDIDATE" || ! -x "$PYTHON_CANDIDATE" ]]; then
  echo "Python 3 was not found. Install Python 3.9 or newer and run this file again."
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm was not found. Install Node.js 20 or newer and run this file again."
  exit 1
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$PYTHON_CANDIDATE" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/python" -m pip install --upgrade pip
  "$VENV_DIR/bin/python" -m pip install -r "$APP_DIR/requirements.txt"
fi

if ! "$VENV_DIR/bin/python" -c "import flask, pandas, pyreadstat" >/dev/null 2>&1; then
  "$VENV_DIR/bin/python" -m pip install -r "$APP_DIR/requirements.txt"
fi

if [[ ! -f "$FRONTEND_DIR/dist/index.html" ]]; then
  cd "$FRONTEND_DIR"
  npm install
  npm run build
fi

cd "$APP_DIR"
"$VENV_DIR/bin/python" "$APP_DIR/backend/app.py" &
SERVER_PID=$!

for attempt in {1..40}; do
  if curl --silent --fail "$APP_URL/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

open "$APP_URL"
wait "$SERVER_PID"
