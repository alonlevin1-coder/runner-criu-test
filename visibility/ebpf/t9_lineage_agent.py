#!/usr/bin/env python3
"""Guest-only process/socket lineage agent (no Node JS tracer, no secret injection).

Compiles monitor.bpf.c + tracer.bpf.c with BCC against BCC_KERNEL_SOURCE
(the 6.17.0-40-generic headers matching appliance/bzImage).
"""
from __future__ import annotations

import argparse
import ctypes
import json
import logging
import os
import sys
import time

try:
    from bcc import BPF
except ImportError:
    BPF = None

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from parsers.monitor_parser import parse_event  # noqa: E402
from parsers.tracer_parser import parse_connection_event  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [t9-lineage] %(message)s",
)
logger = logging.getLogger("t9.lineage")


class LineageAgent:
    def __init__(self, monitor_bpf: str, tracer_bpf: str, cgroup: str, log_file: str):
        self.monitor_path = monitor_bpf
        self.tracer_path = tracer_bpf
        self.cgroup_path = cgroup
        self.log_file = log_file
        self.monitor_bpf = None
        self.tracer_bpf = None
        self.cgroup_fd = -1

    def _emit(self, payload: dict) -> None:
        line = json.dumps(payload, default=str)
        with open(self.log_file, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def start(self) -> None:
        if BPF is None:
            logger.error("python3-bpfcc / bcc is not installed")
            sys.exit(1)

        logger.info("Loading monitor %s (BCC_KERNEL_SOURCE=%s)", self.monitor_path, os.environ.get("BCC_KERNEL_SOURCE", ""))
        with open(self.monitor_path, "r", encoding="utf-8") as f:
            self.monitor_bpf = BPF(text=f.read())
        self.monitor_bpf["events"].open_perf_buffer(self._on_monitor)

        logger.info("Loading tracer %s", self.tracer_path)
        with open(self.tracer_path, "r", encoding="utf-8") as f:
            self.tracer_bpf = BPF(text=f.read())

        config_map = self.tracer_bpf.get_table("config_map")
        config_map[ctypes.c_uint32(0)] = ctypes.c_uint32(0)  # redirect off (host TAP intercept)
        config_map[ctypes.c_uint32(1)] = ctypes.c_uint32(0)
        config_map[ctypes.c_uint32(2)] = ctypes.c_uint32(0)
        config_map[ctypes.c_uint32(3)] = ctypes.c_uint32(0)

        if os.path.exists(self.cgroup_path):
            try:
                self.cgroup_fd = os.open(self.cgroup_path, os.O_RDONLY)
                fn_connect4 = self.tracer_bpf.load_func("trace_connect4", BPF.CGROUP_SOCK_ADDR, attach_type=10)
                self.tracer_bpf.attach_func(fn_connect4, self.cgroup_fd, 10)
                fn_sock_ops = self.tracer_bpf.load_func("trace_sock_ops", BPF.SOCK_OPS, attach_type=3)
                self.tracer_bpf.attach_func(fn_sock_ops, self.cgroup_fd, 3)
                logger.info("Attached connect4/sock_ops on %s", self.cgroup_path)
            except Exception as exc:
                logger.warning("cgroup attach failed: %s", exc)
        else:
            logger.warning("cgroup %s missing; socket tracing disabled", self.cgroup_path)

        self.tracer_bpf["events"].open_perf_buffer(self._on_tracer)
        logger.info("Unified Agent started successfully. Polling multiple ring buffers...")

    def _on_monitor(self, cpu, data, size):
        try:
            payload = parse_event(cpu, data, size)
            if payload:
                self._emit(payload)
        except Exception as exc:
            logger.error("monitor parse: %s", exc)

    def _on_tracer(self, cpu, data, size):
        try:
            payload = parse_connection_event(self.tracer_bpf, cpu, data, size)
            if payload:
                self._emit(payload)
        except Exception as exc:
            logger.error("tracer parse: %s", exc)

    def run_forever(self) -> None:
        self.start()
        while True:
            self.monitor_bpf.perf_buffer_poll(timeout=50)
            self.tracer_bpf.perf_buffer_poll(timeout=50)


def main() -> None:
    parser = argparse.ArgumentParser(description="T9 guest eBPF lineage agent")
    parser.add_argument("--monitor-bpf", default=os.path.join(HERE, "monitor.bpf.c"))
    parser.add_argument("--tracer-bpf", default=os.path.join(HERE, "tracer.bpf.c"))
    parser.add_argument("--cgroup", default="/sys/fs/cgroup")
    parser.add_argument("--log-file", required=True)
    args = parser.parse_args()
    LineageAgent(args.monitor_bpf, args.tracer_bpf, args.cgroup, args.log_file).run_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
