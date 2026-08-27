from __future__ import annotations

import argparse
import json
import logging
import os
import secrets
import threading
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Callable

from waitress.server import create_server

from app import create_app, default_data_root


def configure_logging(data_root: Path) -> None:
    log_root = data_root / "logs"
    log_root.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(
        log_root / "statflow-backend.log",
        maxBytes=2 * 1024 * 1024,
        backupCount=3,
        encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    logging.getLogger().setLevel(logging.INFO)
    logging.getLogger().addHandler(handler)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Survey Data Workbench local service")
    parser.add_argument("--port", type=int, default=0, help="Loopback port; 0 chooses a random free port")
    parser.add_argument("--data-dir", type=Path, default=None, help="Private application data directory")
    parser.add_argument(
        "--parent-pid",
        type=int,
        default=None,
        help="Desktop parent process to monitor; the service exits if this process ends",
    )
    return parser.parse_args()


def parent_is_alive(parent_pid: int) -> bool:
    if parent_pid <= 0:
        return False
    if os.name == "nt":
        import ctypes

        synchronize = 0x00100000
        wait_timeout = 0x00000102
        error_access_denied = 5
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_bool, ctypes.c_uint32]
        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        kernel32.WaitForSingleObject.restype = ctypes.c_uint32
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel32.CloseHandle.restype = ctypes.c_bool
        handle = kernel32.OpenProcess(synchronize, False, parent_pid)
        if not handle:
            return ctypes.get_last_error() == error_access_denied
        try:
            return kernel32.WaitForSingleObject(handle, 0) == wait_timeout
        finally:
            kernel32.CloseHandle(handle)

    try:
        os.kill(parent_pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def watch_parent(
    parent_pid: int,
    stop_event: threading.Event,
    close_server: Callable[[], None],
    *,
    interval_seconds: float = 1.0,
) -> None:
    while not stop_event.wait(interval_seconds):
        if not parent_is_alive(parent_pid):
            logging.getLogger(__name__).warning("Desktop parent process %s exited; stopping sidecar", parent_pid)
            close_server()
            return


def main() -> None:
    args = parse_args()
    if not 0 <= args.port <= 65535:
        raise SystemExit("--port must be between 0 and 65535")
    if args.parent_pid is not None and args.parent_pid <= 0:
        raise SystemExit("--parent-pid must be a positive process identifier")
    data_root = (args.data_dir or default_data_root()).expanduser().resolve()
    data_root.mkdir(parents=True, exist_ok=True)
    configure_logging(data_root)
    token = secrets.token_urlsafe(32)
    application = create_app(
        {
            "API_TOKEN": token,
            "DATA_ROOT": data_root,
            "JOBS_ROOT": data_root / "jobs",
        }
    )
    server = create_server(
        application,
        host="127.0.0.1",
        port=args.port,
        threads=max(4, min(12, (os.cpu_count() or 2) * 2)),
        clear_untrusted_proxy_headers=True,
        ident="Survey Data Workbench",
    )
    print(
        json.dumps(
            {
                "event": "ready",
                "url": f"http://127.0.0.1:{server.effective_port}/",
                "apiToken": token,
                "pid": os.getpid(),
            }
        ),
        flush=True,
    )
    parent_watch_stop = threading.Event()
    parent_watch = None
    if args.parent_pid is not None:
        parent_watch = threading.Thread(
            target=watch_parent,
            args=(args.parent_pid, parent_watch_stop, server.close),
            name="desktop-parent-watchdog",
            daemon=True,
        )
        parent_watch.start()
    try:
        server.run()
    finally:
        parent_watch_stop.set()
        server.close()
        server.task_dispatcher.shutdown(cancel_pending=True, timeout=5)
        if parent_watch is not None:
            parent_watch.join(timeout=2)


if __name__ == "__main__":
    main()
