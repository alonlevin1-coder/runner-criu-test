import ctypes
import time
from datetime import datetime, timezone

class EventHeader(ctypes.Structure):
    _fields_ = [
        ("event_type", ctypes.c_uint32),
    ]

class ExecveEvent(ctypes.Structure):
    _fields_ = [
        ("event_type", ctypes.c_uint32),
        ("pid", ctypes.c_uint32),
        ("ppid", ctypes.c_uint32),
        ("start_time", ctypes.c_uint64),
        ("p_start_time", ctypes.c_uint64),
        ("comm", ctypes.c_char * 16),
        ("exe", ctypes.c_char * 128),
        ("args", (ctypes.c_char * 64) * 10),
    ]

class ForkEvent(ctypes.Structure):
    _fields_ = [
        ("event_type", ctypes.c_uint32),
        ("parent_pid", ctypes.c_uint32),
        ("child_pid", ctypes.c_uint32),
        ("parent_start_time", ctypes.c_uint64),
        ("child_start_time", ctypes.c_uint64),
        ("parent_comm", ctypes.c_char * 16),
        ("child_comm", ctypes.c_char * 16),
    ]

class ExitEvent(ctypes.Structure):
    _fields_ = [
        ("event_type", ctypes.c_uint32),
        ("pid", ctypes.c_uint32),
        ("start_time", ctypes.c_uint64),
    ]

def parse_event(cpu, data, size) -> dict:
    """Parses raw eBPF struct payload into a structured JSON-compatible dictionary."""
    # First extract the event type
    header = ctypes.cast(data, ctypes.POINTER(EventHeader)).contents
    
    if header.event_type == 1: # EVENT_EXECVE
        event = ctypes.cast(data, ctypes.POINTER(ExecveEvent)).contents
        comm = event.comm.decode("utf-8", errors="replace").strip("\x00")
        exe = event.exe.decode("utf-8", errors="replace").strip("\x00")
        
        cmdline_args = []
        for i in range(10):
            arg = bytes(event.args[i]).decode("utf-8", errors="replace").strip("\x00")
            if not arg and i > 0:
                break
            if arg:
                cmdline_args.append(arg)

        return {
            "event_type": "PROCESS_EXECVE",
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "pid": event.pid,
            "ppid": event.ppid,
            "start_time_ns": event.start_time,
            "p_start_time_ns": event.p_start_time,
            "comm": comm,
            "exe": exe,
            "cmdline": cmdline_args
        }
        
    elif header.event_type == 2: # EVENT_FORK
        event = ctypes.cast(data, ctypes.POINTER(ForkEvent)).contents
        p_comm = event.parent_comm.decode("utf-8", errors="replace").strip("\x00")
        c_comm = event.child_comm.decode("utf-8", errors="replace").strip("\x00")
        return {
            "event_type": "PROCESS_FORK",
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "parent_pid": event.parent_pid,
            "child_pid": event.child_pid,
            "parent_start_time_ns": event.parent_start_time,
            "child_start_time_ns": event.child_start_time,
            "parent_comm": p_comm,
            "child_comm": c_comm
        }
        
    elif header.event_type == 3: # EVENT_EXIT
        event = ctypes.cast(data, ctypes.POINTER(ExitEvent)).contents
        return {
            "event_type": "PROCESS_EXIT",
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "pid": event.pid,
            "start_time_ns": event.start_time
        }
        
    return {}
