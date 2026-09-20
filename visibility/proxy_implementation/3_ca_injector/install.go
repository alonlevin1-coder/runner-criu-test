package cainjector

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
)

// InstallOptions controls guest/host CA installation after InjectSystemCA.
type InstallOptions struct {
	// EnvironmentFile is PAM /etc/environment style (KEY=VAL). Empty skips.
	EnvironmentFile string
	// ProfileScript is a sourceable /etc/profile.d script. Empty skips.
	ProfileScript string
	// EnvScript is the historical bash source file (proxy_env.sh). Empty skips.
	EnvScript string
	// SkipSystem skips distro trust-store installation (tests / already injected).
	SkipSystem bool
	Logger     *slog.Logger
}

// Install copies the proxy CA into the system trust store and writes runtime
// env files so AWS SDK, Python, Node, curl, and git trust MITM intercept.
func (inj *Injector) Install(certPath string, opt InstallOptions) error {
	logger := opt.Logger
	if logger == nil {
		logger = inj.logger
	}
	if logger == nil {
		logger = slog.Default()
	}

	absCert, err := filepath.Abs(certPath)
	if err != nil {
		return fmt.Errorf("resolve cert path: %w", err)
	}

	leaf := absCert
	if !opt.SkipSystem {
		if err := inj.InjectSystemCA(absCert); err != nil {
			return err
		}
		leaf, err = materializeGuestLeaf(absCert)
		if err != nil {
			return err
		}
	}
	bundle := ResolveBundle(leaf)

	if opt.EnvironmentFile != "" {
		if err := upsertEnvironmentFile(opt.EnvironmentFile, leaf, bundle); err != nil {
			return fmt.Errorf("environment file: %w", err)
		}
		logger.Info("wrote PAM environment", "path", opt.EnvironmentFile)
	}
	if opt.ProfileScript != "" {
		if err := writeProfileScript(opt.ProfileScript, leaf, bundle); err != nil {
			return fmt.Errorf("profile script: %w", err)
		}
		logger.Info("wrote profile.d script", "path", opt.ProfileScript)
	}
	if opt.EnvScript != "" {
		if err := generateEnvScript(leaf, opt.EnvScript, logger); err != nil {
			return fmt.Errorf("env script: %w", err)
		}
	}

	logger.Info("proxy CA installed", "leaf", leaf, "bundle", bundle)
	return nil
}

func materializeGuestLeaf(src string) (string, error) {
	data, err := os.ReadFile(src)
	if err != nil {
		return "", fmt.Errorf("read cert: %w", err)
	}

	dests := []string{GuestLeafCertPath, GuestLeafPEMPath}
	// Prefer the file InjectSystemCA already wrote if it exists.
	for _, p := range []string{
		GuestLeafCertPath,
		"/usr/local/share/ca-certificates/proxy-ca.crt",
		"/etc/pki/ca-trust/source/anchors/proxy-ca.pem",
	} {
		if st, err := os.Stat(p); err == nil && st.Size() > 0 {
			src = p
			if raw, rerr := os.ReadFile(p); rerr == nil {
				data = raw
			}
			break
		}
	}

	var first string
	for _, dest := range dests {
		if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
			return "", err
		}
		if err := os.WriteFile(dest, data, 0644); err != nil {
			return "", fmt.Errorf("write %s: %w", dest, err)
		}
		if first == "" {
			first = dest
		}
	}
	return first, nil
}

func LoggerToWriter(w io.Writer) *slog.Logger {
	return slog.New(slog.NewTextHandler(w, nil))
}
