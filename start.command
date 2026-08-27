#!/bin/zsh

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$APP_DIR/.venv"
FRONTEND_DIR="$APP_DIR/frontend"
if [[ -n "${PYTHON_BIN:-}" ]]; then
  PYTHON_CANDIDATE="$PYTHON_BIN"
elif [[ -x "$VENV_DIR/bin/python" ]]; then
  PYTHON_CANDIDATE="$VENV_DIR/bin/python"
else
  PYTHON_CANDIDATE="$(command -v python3 || true)"
fi
READY_FILE="$(mktemp)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$READY_FILE"
}
trap cleanup EXIT INT TERM

if [[ -z "$PYTHON_CANDIDATE" || ! -x "$PYTHON_CANDIDATE" ]]; then
  echo "Python 3 was not found. Install Python 3.10 or newer and run this file again."
  exit 1
fi

if ! "$PYTHON_CANDIDATE" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo "Python 3.10 or newer is required."
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm was not found. Install Node.js 20 or newer and run this file again."
  exit 1
fi

if ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) < 20 ? 1 : 0)'; then
  echo "Node.js 20 or newer is required."
  exit 1
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$PYTHON_CANDIDATE" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/python" -m pip install --upgrade pip
fi

"$VENV_DIR/bin/python" -m pip install --disable-pip-version-check -r "$APP_DIR/requirements.lock.txt"

(
  cd "$FRONTEND_DIR"
  npm ci
  npm run build
)

"$VENV_DIR/bin/python" "$APP_DIR/backend/server.py" --port 0 >"$READY_FILE" &
SERVER_PID=$!

for attempt in {1..140}; do
  if [[ -s "$READY_FILE" ]]; then
    break
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "The local service exited before it was ready."
    exit 1
  fi
  sleep 0.25
done

if [[ ! -s "$READY_FILE" ]]; then
  echo "The local service did not become ready within 35 seconds."
  exit 1
fi

APP_URL="$("$VENV_DIR/bin/python" -c 'import json, sys, urllib.parse; data=json.loads(open(sys.argv[1], encoding="utf-8").readline()); print(data["url"] + "#token=" + urllib.parse.quote(data["apiToken"]))' "$READY_FILE")"
open "$APP_URL"
wait "$SERVER_PID"
