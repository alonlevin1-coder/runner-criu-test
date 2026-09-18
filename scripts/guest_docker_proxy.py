#!/usr/bin/env python3
"""Guest: UNIX /run/docker.sock -> TCP 10.0.2.2:2375 (QEMU guestfwd to host dockerd)."""
import os
import socket
import sys
import threading

UPSTREAM = (os.environ.get("T9_DOCKER_GW", "10.0.2.2"), int(os.environ.get("T9_DOCKER_PROXY_PORT", "2375")))
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
    upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        upstream.settimeout(10)
        upstream.connect(UPSTREAM)
        upstream.settimeout(None)
    except OSError as exc:
        sys.stderr.write("guest docker proxy connect %s: %s\n" % (UPSTREAM, exc))
        client.close()
        return
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    pipe(upstream, client)
    client.close()
    upstream.close()


def main():
    try:
        os.remove(SOCK)
    except OSError:
        pass
    os.makedirs("/run", exist_ok=True)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    os.chmod(SOCK, 0o666)
    try:
        os.makedirs("/var/run", exist_ok=True)
        if not os.path.exists("/var/run/docker.sock"):
            os.symlink(SOCK, "/var/run/docker.sock")
    except OSError:
        pass
    srv.listen(64)
    sys.stderr.write("guest docker proxy %s -> %s:%s\n" % (SOCK, UPSTREAM[0], UPSTREAM[1]))
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main() or 0)
