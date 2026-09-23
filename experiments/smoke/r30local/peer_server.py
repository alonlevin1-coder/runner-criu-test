#!/usr/bin/env python3
"""TCP peer in an isolated netns for R30 local smoke (Porter F09 pattern)."""
import socket
import sys
import time
from pathlib import Path


def main() -> None:
    status_file = Path(sys.argv[1])
    action_file = Path(sys.argv[2])
    reply_file = Path(sys.argv[3])

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("10.200.0.1", 19876))
    sock.listen(1)
    print("[PEER] Listening on 10.200.0.1:19876", flush=True)

    conn, peer_addr = sock.accept()
    print(f"[PEER] Accepted connection from {peer_addr}", flush=True)
    conn.settimeout(120.0)

    data = conn.recv(1024)
    if data != b"HELLO\n":
        print(f"[PEER] Unexpected initial data: {data!r}", flush=True)
        sys.exit(1)
    conn.sendall(b"ACK\n")
    status_file.write_text(f"CONNECTED {peer_addr[0]} {peer_addr[1]}\n", encoding="utf-8")
    print(f"[PEER] Handshake complete with {peer_addr}", flush=True)

    print("[PEER] Awaiting action trigger...", flush=True)
    while not action_file.exists():
        time.sleep(0.05)

    action = action_file.read_text(encoding="utf-8").strip()
    print(f"[PEER] Executing action: {action}", flush=True)

    if action == "PING":
        conn.sendall(b"PING\n")
        reply = conn.recv(1024)
        reply_file.write_text(reply.decode("utf-8", errors="replace"), encoding="utf-8")
        print(f"[PEER] Post-restore reply: {reply!r}", flush=True)
    else:
        print(f"[PEER] Unknown action: {action}", flush=True)
        sys.exit(2)

    conn.close()
    sock.close()


if __name__ == "__main__":
    main()
