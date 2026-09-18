#!/usr/bin/env python3
"""Forward TCP 127.0.0.1:2375 to the host dockerd unix socket."""
import os
import socket
import sys
import threading

LISTEN = ("127.0.0.1", int(os.environ.get("T9_DOCKER_PROXY_PORT", "2375")))
SOCK = os.environ.get("T9_DOCKER_SOCK", "/var/run/docker.sock")
if not os.path.exists(SOCK):
    SOCK = "/run/docker.sock"


def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        try:
            a.shutdown(socket.SHUT_RD)
        except OSError:
            pass
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client):
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        upstream.connect(SOCK)
    except OSError as exc:
        sys.stderr.write("docker proxy connect %s: %s\n" % (SOCK, exc))
        client.close()
        return
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    pipe(upstream, client)
    client.close()
    upstream.close()


def main():
    if not os.path.exists(SOCK):
        sys.stderr.write("docker proxy: %s missing\n" % SOCK)
        return 0
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN)
    srv.listen(64)
    sys.stderr.write("docker proxy listen %s:%s -> %s\n" % (LISTEN[0], LISTEN[1], SOCK))
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main() or 0)
