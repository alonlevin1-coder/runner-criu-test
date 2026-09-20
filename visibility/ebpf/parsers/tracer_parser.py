import ctypes
import time
import socket
import struct
from datetime import datetime, timezone

def ip_to_str(ip_int: int) -> str:
    """Converts a 32-bit unsigned integer IP address to dotted-decimal string."""
    try:
        return socket.inet_ntoa(struct.pack("=I", ip_int))
    except Exception:
        return "0.0.0.0"

def port_to_int(port_nbo: int) -> int:
    """Converts network byte order port to host byte order integer."""
    return socket.ntohs(port_nbo & 0xFFFF) if port_nbo else 0

def calculate_wall_time(ktime_ns: int) -> str:
    """Converts kernel boot timestamp (ns) to ISO 8601 UTC string."""
    now_wall = time.time()
    now_boot = time.clock_gettime(time.CLOCK_BOOTTIME)
    boot_offset = now_wall - now_boot
    evt_wall_sec = boot_offset + (ktime_ns / 1e9)
    dt = datetime.fromtimestamp(evt_wall_sec, tz=timezone.utc)
    return dt.isoformat()

def parse_connection_event(bpf, cpu, data, size) -> dict:
    """Parses raw eBPF struct payload into a structured JSON-compatible dictionary."""
    event = bpf["events"].event(data)

    event_type_str = "CONNECTION_OPEN" if event.event_type == 1 else "CONNECTION_CLOSE"
    timestamp_utc = calculate_wall_time(event.timestamp_ns)

    orig_dst_ip = ip_to_str(event.orig_dst_ip)
    redirect_dst_ip = ip_to_str(event.redirect_dst_ip)
    src_ip = ip_to_str(event.src_ip)
    src_port = port_to_int(event.src_port)

    comm = event.comm.decode("utf-8", errors="replace").strip("\x00")

    payload = {
        "event_type": event_type_str,
        "timestamp_utc": timestamp_utc,
        "timestamp_ns": event.timestamp_ns,
        "pid": event.pid,
        "start_time_ns": event.start_time,
        "tgid": event.tgid,
        "uid": event.uid,
        "gid": event.gid,
        "comm": comm,
        "src_ip": src_ip,
        "src_port": src_port,
        "orig_dst_ip": orig_dst_ip,
        "orig_dst_port": port_to_int(event.orig_dst_port),
        "redirect_dst_ip": redirect_dst_ip,
        "redirect_dst_port": port_to_int(event.redirect_dst_port),
        "redirected": bool(event.redirected)
    }
    
    return payload
