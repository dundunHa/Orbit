#!/usr/bin/env python3
"""Serve Orbit's browser debug UI from the first available local port."""

from __future__ import annotations

import argparse
import contextlib
import http.server
import socket
from functools import partial
from pathlib import Path


CHROMIUM_UNSAFE_PORTS = {
    1,
    7,
    9,
    11,
    13,
    15,
    17,
    19,
    20,
    21,
    22,
    23,
    25,
    37,
    42,
    43,
    53,
    69,
    77,
    79,
    87,
    95,
    101,
    102,
    103,
    104,
    109,
    110,
    111,
    113,
    115,
    117,
    119,
    123,
    135,
    137,
    139,
    143,
    161,
    179,
    389,
    427,
    465,
    512,
    513,
    514,
    515,
    526,
    530,
    531,
    532,
    540,
    548,
    554,
    556,
    563,
    587,
    601,
    636,
    989,
    990,
    993,
    995,
    1719,
    1720,
    1723,
    2049,
    3659,
    4045,
    5060,
    5061,
    6000,
    6566,
    6665,
    6666,
    6667,
    6668,
    6669,
    6697,
    10080,
}


class DebugUiHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path in ("", "/"):
            self.send_response(302)
            self.send_header("Location", "/debug.html")
            self.end_headers()
            return

        if self.path == "/healthz":
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        super().do_GET()

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        super().end_headers()


def port_is_available(host: str, port: int) -> bool:
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((host, port))
        except OSError:
            return False
    return True


def first_available_port(host: str, start_port: int, max_tries: int) -> int:
    for port in range(start_port, start_port + max_tries):
        if port in CHROMIUM_UNSAFE_PORTS:
            print(f"Skipping browser-blocked port {port}", flush=True)
            continue
        if port_is_available(host, port):
            return port
    raise SystemExit(
        f"No available local port in range {start_port}-{start_port + max_tries - 1}",
    )


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    src_dir = repo_root / "src"

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6666)
    parser.add_argument("--max-tries", type=int, default=50)
    args = parser.parse_args()

    port = first_available_port(args.host, args.port, args.max_tries)
    handler = partial(DebugUiHandler, directory=str(src_dir))
    server = http.server.ThreadingHTTPServer((args.host, port), handler)

    print(f"Open http://{args.host}:{port}/debug.html", flush=True)
    print(f"Serving Orbit debug UI from {src_dir}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Orbit debug UI server", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
