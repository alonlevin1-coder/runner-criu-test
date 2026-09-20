package rerouter

import (
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"syscall"
	"unsafe"

	"proxy_implementation/shared_types"
)

// Ensure Rerouter implements types.TransparentRerouter at compile time.
var _ types.TransparentRerouter = (*Rerouter)(nil)

// RerouterConfig holds configuration for the Transparent Rerouter.
type RerouterConfig struct {
	ProxyPort  int
	BypassUID  int
	TargetPort int // Defaults to 443 if <= 0
	Logger     *slog.Logger
	ExecCmd    func(name string, args ...string) ([]byte, error)
}

// Rerouter manages OS-level firewall redirection using iptables.
type Rerouter struct {
	proxyPort  int
	bypassUID  int
	targetPort int
	logger     *slog.Logger
	execCmd    func(name string, args ...string) ([]byte, error)
	applied    bool
	mu         sync.Mutex
}

// NewRerouter creates a new Transparent Rerouter instance.
func NewRerouter(cfg RerouterConfig) *Rerouter {
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}

	targetPort := cfg.TargetPort
	if targetPort <= 0 {
		targetPort = 443
	}

	bypassUID := cfg.BypassUID
	if bypassUID <= 0 {
		bypassUID = os.Geteuid()
	}

	execCmd := cfg.ExecCmd
	if execCmd == nil {
		execCmd = func(name string, args ...string) ([]byte, error) {
			cmd := exec.Command(name, args...)
			return cmd.CombinedOutput()
		}
	}

	return &Rerouter{
		proxyPort:  cfg.ProxyPort,
		bypassUID:  bypassUID,
		targetPort: targetPort,
		logger:     logger,
		execCmd:    execCmd,
	}
}

// Setup applies iptables NAT REDIRECT rules.
func (r *Rerouter) Setup() error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.proxyPort <= 0 {
		return fmt.Errorf("invalid proxy port: %d", r.proxyPort)
	}

	if r.applied {
		r.logger.Info("Firewall rules already applied")
		return nil
	}

	r.logger.Info("Configuring firewall transparent redirect",
		"targetPort", r.targetPort,
		"proxyPort", r.proxyPort,
		"bypassUID", r.bypassUID,
	)

	// iptables -t nat -A OUTPUT -p tcp --dport <targetPort> -m owner ! --uid-owner <bypassUID> -j REDIRECT --to-ports <proxyPort>
	args := []string{
		"-t", "nat",
		"-A", "OUTPUT",
		"-p", "tcp",
		"--dport", strconv.Itoa(r.targetPort),
		"-m", "owner", "!", "--uid-owner", strconv.Itoa(r.bypassUID),
		"-j", "REDIRECT",
		"--to-ports", strconv.Itoa(r.proxyPort),
	}

	out, err := r.execCmd("iptables", args...)
	if err != nil {
		// Fallback to iptables-legacy if nftables is not supported in the kernel
		outLegacy, errLegacy := r.execCmd("iptables-legacy", args...)
		if errLegacy == nil {
			r.applied = true
			r.logger.Info("Firewall transparent redirect successfully configured using iptables-legacy")
			return nil
		}
		return fmt.Errorf("failed to apply iptables rule (output: %s, legacy: %s): %w", string(out), string(outLegacy), err)
	}

	r.applied = true
	r.logger.Info("Firewall transparent redirect successfully configured")
	return nil
}

// Cleanup removes the iptables NAT REDIRECT rules.
func (r *Rerouter) Cleanup() error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if !r.applied {
		return nil
	}

	r.logger.Info("Removing firewall transparent redirect",
		"targetPort", r.targetPort,
		"proxyPort", r.proxyPort,
		"bypassUID", r.bypassUID,
	)

	args := []string{
		"-t", "nat",
		"-D", "OUTPUT",
		"-p", "tcp",
		"--dport", strconv.Itoa(r.targetPort),
		"-m", "owner", "!", "--uid-owner", strconv.Itoa(r.bypassUID),
		"-j", "REDIRECT",
		"--to-ports", strconv.Itoa(r.proxyPort),
	}

	out, err := r.execCmd("iptables", args...)
	if err != nil {
		_, _ = r.execCmd("iptables-legacy", args...)
		r.logger.Warn("Failed to delete iptables rule during cleanup", "output", string(out), "error", err)
		r.applied = false
		return fmt.Errorf("failed to remove iptables rule (output: %s): %w", string(out), err)
	}

	r.applied = false
	r.logger.Info("Firewall transparent redirect successfully removed")
	return nil
}

// IsActive returns whether the firewall rules are currently applied.
func (r *Rerouter) IsActive() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.applied
}

// GetOriginalDst retrieves the original destination IP and port from a redirected TCP connection.
func GetOriginalDst(conn net.Conn) (*net.TCPAddr, error) {
	if conn == nil {
		return nil, errors.New("nil connection")
	}

	type syscallConn interface {
		SyscallConn() (syscall.RawConn, error)
	}

	sc, ok := conn.(syscallConn)
	if !ok {
		return nil, errors.New("connection does not implement SyscallConn")
	}

	rawConn, err := sc.SyscallConn()
	if err != nil {
		return nil, fmt.Errorf("failed to get raw syscall conn: %w", err)
	}

	var (
		origAddr *net.TCPAddr
		sockErr  error
	)

	controlErr := rawConn.Control(func(fd uintptr) {
		// 1. Try IPv4 SO_ORIGINAL_DST (SOL_IP = 0, SO_ORIGINAL_DST = 80)
		var raw syscall.RawSockaddrInet4
		var size uint32 = uint32(unsafe.Sizeof(raw))
		_, _, errno := syscall.RawSyscall6(
			syscall.SYS_GETSOCKOPT,
			fd,
			uintptr(syscall.SOL_IP),
			uintptr(80), // unix.SO_ORIGINAL_DST
			uintptr(unsafe.Pointer(&raw)),
			uintptr(unsafe.Pointer(&size)),
			0,
		)
		if errno == 0 {
			port := int(raw.Port>>8) | int(raw.Port&0xff)<<8
			ip := net.IPv4(raw.Addr[0], raw.Addr[1], raw.Addr[2], raw.Addr[3])
			origAddr = &net.TCPAddr{
				IP:   ip,
				Port: port,
			}
			return
		}

		// 2. Try IPv6 IP6T_SO_ORIGINAL_DST (SOL_IPV6 = 41, IP6T_SO_ORIGINAL_DST = 80)
		var raw6 syscall.RawSockaddrInet6
		var size6 uint32 = uint32(unsafe.Sizeof(raw6))
		_, _, errno6 := syscall.RawSyscall6(
			syscall.SYS_GETSOCKOPT,
			fd,
			uintptr(41), // unix.SOL_IPV6
			uintptr(80), // unix.IP6T_SO_ORIGINAL_DST
			uintptr(unsafe.Pointer(&raw6)),
			uintptr(unsafe.Pointer(&size6)),
			0,
		)
		if errno6 == 0 {
			port := int(raw6.Port>>8) | int(raw6.Port&0xff)<<8
			ip := make(net.IP, net.IPv6len)
			copy(ip, raw6.Addr[:])
			origAddr = &net.TCPAddr{
				IP:   ip,
				Port: port,
			}
			return
		}

		sockErr = fmt.Errorf("getsockopt SO_ORIGINAL_DST error (IPv4: %v, IPv6: %v)", errno, errno6)
	})

	if controlErr != nil {
		return nil, controlErr
	}
	if origAddr != nil {
		return origAddr, nil
	}
	return nil, sockErr
}
