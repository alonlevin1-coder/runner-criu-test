#!/usr/bin/env python3
"""Join host http.log TCP client 4-tuples onto guest CONNECTION_OPEN + PID lineage."""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any


def parse_addr(addr: str) -> tuple[str, int] | None:
    if not addr or not isinstance(addr, str):
        return None
    s = addr.strip()
    host = ""
    port_s = ""
    if s.startswith("["):
        end = s.find("]")
        if end < 0:
            return None
        host = s[1:end]
        if len(s) > end + 1 and s[end + 1] == ":":
            port_s = s[end + 2 :]
    else:
        if s.count(":") == 1:
            host, port_s = s.split(":", 1)
        elif s.rsplit(":", 1)[-1].isdigit():
            host, port_s = s.rsplit(":", 1)
        else:
            return None
    if host.lower().startswith("::ffff:"):
        host = host[7:]
    try:
        port = int(port_s)
    except ValueError:
        return None
    if not host or port <= 0:
        return None
    return host, port


def load_jsonl(path: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not os.path.isfile(path):
        return rows
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict):
                rows.append(obj)
    return rows


def chain_builder(events: list[dict[str, Any]]):
    forks_by_child: dict[int, dict[str, Any]] = {}
    exec_by_pid: dict[int, dict[str, Any]] = {}
    for ev in events:
        kind = ev.get("event_type")
        if kind == "PROCESS_FORK":
            child = int(ev.get("child_pid") or 0)
            if child:
                forks_by_child[child] = ev
        elif kind == "PROCESS_EXECVE":
            pid = int(ev.get("pid") or 0)
            if pid:
                exec_by_pid[pid] = ev

    def chain_for(pid: int, comm: str) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        seen: set[int] = set()
        cur = pid
        first_comm = comm
        while cur and cur not in seen:
            seen.add(cur)
            ex = exec_by_pid.get(cur)
            node = {
                "pid": cur,
                "comm": (ex.get("comm") if ex else first_comm) or "",
                "exe": (ex.get("exe") if ex else "") or "",
                "cmdline": (ex.get("cmdline") if ex else []) or [],
            }
            if not node["comm"] and first_comm:
                node["comm"] = first_comm
            out.append(node)
            first_comm = ""
            fk = forks_by_child.get(cur)
            if not fk:
                if ex:
                    ppid = int(ex.get("ppid") or 0)
                    if ppid and ppid not in seen:
                        cur = ppid
                        continue
                break
            cur = int(fk.get("parent_pid") or 0)
        return out

    return chain_for


def correlate(http_rows: list[dict[str, Any]], lineage_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    opens: list[dict[str, Any]] = [
        ev for ev in lineage_rows if ev.get("event_type") == "CONNECTION_OPEN"
    ]
    chain_for = chain_builder(lineage_rows)

    by_src: dict[tuple[str, int], list[dict[str, Any]]] = {}
    for ev in opens:
        ip = str(ev.get("src_ip") or "")
        try:
            port = int(ev.get("src_port") or 0)
        except (TypeError, ValueError):
            port = 0
        if not ip or port <= 0:
            continue
        by_src.setdefault((ip, port), []).append(ev)

    out: list[dict[str, Any]] = []
    for http in http_rows:
        if http.get("event_type") != "HTTP_TRANSACTION":
            continue
        parsed = parse_addr(str(http.get("client_addr") or ""))
        match = None
        if parsed and parsed in by_src:
            match = by_src[parsed][-1]
        pid = int((match or {}).get("pid") or (match or {}).get("tgid") or 0)
        comm = str((match or {}).get("comm") or "")
        lineage = chain_for(pid, comm) if pid else []
        rec = {
            "event_type": "HTTP_WITH_LINEAGE",
            "timestamp_utc": http.get("timestamp_utc", ""),
            "request_id": http.get("request_id", ""),
            "method": http.get("method", ""),
            "host": http.get("host", ""),
            "path": http.get("path", ""),
            "status": http.get("status"),
            "client_addr": http.get("client_addr", ""),
            "server_addr": http.get("server_addr", ""),
            "matched": bool(match),
            "pid": pid or None,
            "comm": comm,
            "src_ip": (match or {}).get("src_ip", ""),
            "src_port": (match or {}).get("src_port"),
            "orig_dst_ip": (match or {}).get("orig_dst_ip", ""),
            "orig_dst_port": (match or {}).get("orig_dst_port"),
            "lineage": lineage,
        }
        out.append(rec)
    return out


def format_lineage(chain: list[dict[str, Any]]) -> str:
    parts = []
    for node in reversed(chain):
        label = node.get("comm") or str(node.get("pid"))
        parts.append(f"{label}({node.get('pid')})")
    return " -> ".join(parts)


def run_self_test() -> int:
    http_rows = [
        {
            "event_type": "HTTP_TRANSACTION",
            "host": "example.com",
            "path": "/",
            "method": "GET",
            "status": 200,
            "client_addr": "192.168.100.2:54321",
            "server_addr": "example.com:443",
        }
    ]
    lineage_rows = [
        {
            "event_type": "PROCESS_FORK",
            "parent_pid": 1,
            "child_pid": 100,
            "parent_comm": "systemd",
            "child_comm": "bash",
        },
        {
            "event_type": "PROCESS_EXECVE",
            "pid": 100,
            "ppid": 1,
            "comm": "curl",
            "exe": "/usr/bin/curl",
            "cmdline": ["curl", "https://example.com"],
        },
        {
            "event_type": "CONNECTION_OPEN",
            "pid": 100,
            "tgid": 100,
            "comm": "curl",
            "src_ip": "192.168.100.2",
            "src_port": 54321,
            "orig_dst_ip": "93.184.216.34",
            "orig_dst_port": 443,
        },
    ]
    recs = correlate(http_rows, lineage_rows)
    if len(recs) != 1 or not recs[0]["matched"] or recs[0]["pid"] != 100:
        print("self-test failed", recs, file=sys.stderr)
        return 1
    if recs[0]["lineage"][0]["comm"] != "curl":
        print("self-test lineage failed", recs[0]["lineage"], file=sys.stderr)
        return 1
    print("self-test ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Correlate http.log with lineage.log")
    parser.add_argument("--http", default="/mnt/checkpoint/http.log")
    parser.add_argument("--lineage", default="/mnt/checkpoint/lineage.log")
    parser.add_argument("--out", default="/mnt/checkpoint/http_lineage.log")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return run_self_test()

    recs = correlate(load_jsonl(args.http), load_jsonl(args.lineage))
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        for rec in recs:
            fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
            chain = format_lineage(rec.get("lineage") or [])
            print(
                f"{rec.get('method')} {rec.get('host')}{rec.get('path')} "
                f"status={rec.get('status')} client={rec.get('client_addr')} "
                f"pid={rec.get('pid')} comm={rec.get('comm')} lineage={chain or '-'}",
                flush=True,
            )
    matched = sum(1 for r in recs if r.get("matched"))
    print(f"correlated {matched}/{len(recs)} HTTP transactions -> {args.out}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
