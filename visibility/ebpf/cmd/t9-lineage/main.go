package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/perf"
	"github.com/cilium/ebpf/rlimit"
	"golang.org/x/sys/unix"
)

type execveEvent struct {
	EventType  uint32
	Pid        uint32
	Ppid       uint32
	StartTime  uint64
	PStartTime uint64
	Comm       [16]byte
	Exe        [128]byte
	Argv       [10][64]byte
}

type forkEvent struct {
	EventType       uint32
	ParentPid       uint32
	ChildPid        uint32
	ParentStartTime uint64
	ChildStartTime  uint64
	ParentComm      [16]byte
	ChildComm       [16]byte
}

type exitEvent struct {
	EventType uint32
	Pid       uint32
	StartTime uint64
}

type connEvent struct {
	EventType       uint32
	SrcIP           uint32
	SrcPort         uint16
	OrigDstIP       uint32
	OrigDstPort     uint16
	RedirectDstIP   uint32
	RedirectDstPort uint16
	Pid             uint32
	StartTime       uint64
	Tgid            uint32
	Uid             uint32
	Gid             uint32
	TimestampNs     uint64
	Redirected      uint32
	Comm            [16]byte
}

func cstr(b []byte) string {
	n := bytes.IndexByte(b, 0)
	if n < 0 {
		n = len(b)
	}
	return string(b[:n])
}

func ip4(n uint32) string {
	ip := make(net.IP, 4)
	binary.LittleEndian.PutUint32(ip, n)
	return ip.String()
}

func ntohs(p uint16) int {
	return int((p>>8)&0xff | (p<<8)&0xff00)
}

func bootOffset() float64 {
	var ts unix.Timespec
	if err := unix.ClockGettime(unix.CLOCK_BOOTTIME, &ts); err != nil {
		return 0
	}
	boot := float64(ts.Sec) + float64(ts.Nsec)/1e9
	return float64(time.Now().UnixNano())/1e9 - boot
}

func main() {
	monitorObj := flag.String("monitor", "", "prebuilt monitor.bpf.o")
	tracerObj := flag.String("tracer", "", "prebuilt tracer.bpf.o")
	cgroup := flag.String("cgroup", "/sys/fs/cgroup", "cgroup2 path for connect4/sock_ops")
	logFile := flag.String("log-file", "", "JSONL output")
	stateFile := flag.String("state-file", "", "append lineage=yes after load")
	flag.Parse()
	if *monitorObj == "" || *tracerObj == "" || *logFile == "" {
		fmt.Fprintln(os.Stderr, "t9-lineage: --monitor --tracer --log-file are required")
		os.Exit(2)
	}

	if err := rlimit.RemoveMemlock(); err != nil {
		fmt.Fprintf(os.Stderr, "t9-lineage: memlock: %v\n", err)
	}

	out, err := os.OpenFile(*logFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0666)
	if err != nil {
		fmt.Fprintf(os.Stderr, "t9-lineage: open log: %v\n", err)
		os.Exit(1)
	}
	defer out.Close()
	var mu sync.Mutex
	emit := func(v any) {
		b, err := json.Marshal(v)
		if err != nil {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		_, _ = out.Write(append(b, '\n'))
	}

	var links []link.Link
	attachKprobe := func(sym string, p *ebpf.Program) {
		if p == nil {
			fmt.Fprintf(os.Stderr, "t9-lineage: missing kprobe program for %s\n", sym)
			os.Exit(1)
		}
		l, err := link.Kprobe(sym, p, nil)
		if err != nil {
			fmt.Fprintf(os.Stderr, "t9-lineage: attach kprobe %s: %v\n", sym, err)
			os.Exit(1)
		}
		links = append(links, l)
	}

	monSpec, err := ebpf.LoadCollectionSpec(*monitorObj)
	if err != nil {
		fmt.Fprintf(os.Stderr, "t9-lineage: monitor spec: %v\n", err)
		os.Exit(1)
	}
	mon, err := ebpf.NewCollection(monSpec)
	if err != nil {
		fmt.Fprintf(os.Stderr, "t9-lineage: monitor load: %v\n", err)
		os.Exit(1)
	}
	defer mon.Close()

	attachKprobe("__x64_sys_execve", mon.Programs["kprobe_execve"])
	attachKprobe("__x64_sys_execveat", mon.Programs["kprobe_execveat"])
	attachKprobe("wake_up_new_task", mon.Programs["kprobe_wake_up_new_task"])
	attachKprobe("do_exit", mon.Programs["kprobe_do_exit"])

	trSpec, err := ebpf.LoadCollectionSpec(*tracerObj)
	if err != nil {
		fmt.Fprintf(os.Stderr, "t9-lineage: tracer spec: %v\n", err)
		os.Exit(1)
	}
	tr, err := ebpf.NewCollection(trSpec)
	if err != nil {
		fmt.Fprintf(os.Stderr, "t9-lineage: tracer load: %v\n", err)
		os.Exit(1)
	}
	defer tr.Close()

	if cfg, ok := tr.Maps["config_map"]; ok {
		var zero uint32
		for i := uint32(0); i < 4; i++ {
			_ = cfg.Put(i, zero)
		}
	}
	if _, err := os.Stat(*cgroup); err == nil {
		if tr.Programs["trace_connect4"] != nil {
			l, err := link.AttachCgroup(link.CgroupOptions{
				Path:    *cgroup,
				Attach:  ebpf.AttachCGroupInet4Connect,
				Program: tr.Programs["trace_connect4"],
			})
			if err != nil {
				fmt.Fprintf(os.Stderr, "t9-lineage: attach connect4: %v\n", err)
			} else {
				links = append(links, l)
			}
		}
		if tr.Programs["trace_sock_ops"] != nil {
			l, err := link.AttachCgroup(link.CgroupOptions{
				Path:    *cgroup,
				Attach:  ebpf.AttachCGroupSockOps,
				Program: tr.Programs["trace_sock_ops"],
			})
			if err != nil {
				fmt.Fprintf(os.Stderr, "t9-lineage: attach sock_ops: %v\n", err)
			} else {
				links = append(links, l)
			}
		}
	} else {
		fmt.Fprintf(os.Stderr, "t9-lineage: cgroup %s missing; socket tracing disabled\n", *cgroup)
	}

	monRd, err := perf.NewReader(mon.Maps["events"], os.Getpagesize()*8)
	if err != nil {
		fmt.Fprintf(os.Stderr, "t9-lineage: monitor perf: %v\n", err)
		os.Exit(1)
	}
	defer monRd.Close()
	trRd, err := perf.NewReader(tr.Maps["events"], os.Getpagesize()*8)
	if err != nil {
		fmt.Fprintf(os.Stderr, "t9-lineage: tracer perf: %v\n", err)
		os.Exit(1)
	}
	defer trRd.Close()

	fmt.Fprintln(os.Stderr, "Unified Agent started successfully. Polling multiple ring buffers...")
	if *stateFile != "" {
		f, err := os.OpenFile(*stateFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
		if err == nil {
			_, _ = f.WriteString("lineage=yes\n")
			_ = f.Close()
		}
	}

	offset := bootOffset()
	go readMonitor(monRd, emit)
	go readTracer(trRd, emit, offset)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	for _, l := range links {
		_ = l.Close()
	}
}

func readMonitor(rd *perf.Reader, emit func(any)) {
	for {
		rec, err := rd.Read()
		if err != nil {
			return
		}
		if rec.LostSamples > 0 {
			continue
		}
		data := rec.RawSample
		if len(data) < 4 {
			continue
		}
		var kind uint32
		_ = binary.Read(bytes.NewReader(data[:4]), binary.LittleEndian, &kind)
		now := time.Now().UTC().Format(time.RFC3339Nano)
		switch kind {
		case 1:
			var e execveEvent
			if err := binary.Read(bytes.NewReader(data), binary.LittleEndian, &e); err != nil {
				continue
			}
			args := make([]string, 0, 10)
			for i := 0; i < 10; i++ {
				a := cstr(e.Argv[i][:])
				if a == "" && i > 0 {
					break
				}
				if a != "" {
					args = append(args, a)
				}
			}
			emit(map[string]any{
				"event_type":      "PROCESS_EXECVE",
				"timestamp_utc":   now,
				"pid":             e.Pid,
				"ppid":            e.Ppid,
				"start_time_ns":   e.StartTime,
				"p_start_time_ns": e.PStartTime,
				"comm":            cstr(e.Comm[:]),
				"exe":             cstr(e.Exe[:]),
				"cmdline":         args,
			})
		case 2:
			var e forkEvent
			if err := binary.Read(bytes.NewReader(data), binary.LittleEndian, &e); err != nil {
				continue
			}
			emit(map[string]any{
				"event_type":           "PROCESS_FORK",
				"timestamp_utc":        now,
				"parent_pid":           e.ParentPid,
				"child_pid":            e.ChildPid,
				"parent_start_time_ns": e.ParentStartTime,
				"child_start_time_ns":  e.ChildStartTime,
				"parent_comm":          cstr(e.ParentComm[:]),
				"child_comm":           cstr(e.ChildComm[:]),
			})
		case 3:
			var e exitEvent
			if err := binary.Read(bytes.NewReader(data), binary.LittleEndian, &e); err != nil {
				continue
			}
			emit(map[string]any{
				"event_type":    "PROCESS_EXIT",
				"timestamp_utc": now,
				"pid":           e.Pid,
				"start_time_ns": e.StartTime,
			})
		}
	}
}

func readTracer(rd *perf.Reader, emit func(any), bootOff float64) {
	for {
		rec, err := rd.Read()
		if err != nil {
			return
		}
		if rec.LostSamples > 0 {
			continue
		}
		var e connEvent
		if err := binary.Read(bytes.NewReader(rec.RawSample), binary.LittleEndian, &e); err != nil {
			continue
		}
		kind := "CONNECTION_OPEN"
		if e.EventType != 1 {
			kind = "CONNECTION_CLOSE"
		}
		wall := time.Unix(0, int64((bootOff+float64(e.TimestampNs)/1e9)*1e9)).UTC().Format(time.RFC3339Nano)
		emit(map[string]any{
			"event_type":        kind,
			"timestamp_utc":     wall,
			"timestamp_ns":      e.TimestampNs,
			"pid":               e.Pid,
			"start_time_ns":     e.StartTime,
			"tgid":              e.Tgid,
			"uid":               e.Uid,
			"gid":               e.Gid,
			"comm":              cstr(e.Comm[:]),
			"src_ip":            ip4(e.SrcIP),
			"src_port":          ntohs(e.SrcPort),
			"orig_dst_ip":       ip4(e.OrigDstIP),
			"orig_dst_port":     ntohs(e.OrigDstPort),
			"redirect_dst_ip":   ip4(e.RedirectDstIP),
			"redirect_dst_port": ntohs(e.RedirectDstPort),
			"redirected":        e.Redirected != 0,
		})
	}
}
