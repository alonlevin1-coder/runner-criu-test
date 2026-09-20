package cainjector

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"proxy_implementation/shared_types"
)

// Ensure Injector implements types.CAInjector at compile time.
var _ types.CAInjector = (*Injector)(nil)

// InjectorConfig holds configuration for the CA injector.
type InjectorConfig struct {
	Logger *slog.Logger
}

// Injector manages root CA installation, env script generation, and TLS verification.
type Injector struct {
	logger        *slog.Logger
	osReleasePath string
	geteuid       func() int
}

// NewCAInjector creates a new CAInjector instance.
func NewCAInjector(cfg InjectorConfig) *Injector {
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Injector{
		logger:        logger,
		osReleasePath: "/etc/os-release",
		geteuid:       os.Geteuid,
	}
}

// InjectSystemCA installs the CA cert into the Linux system trust store.
func (inj *Injector) InjectSystemCA(certPath string) error {
	// 1. Check if certPath exists and is readable
	certData, err := os.ReadFile(certPath)
	if err != nil {
		return fmt.Errorf("certificate file not found or unreadable: %w", err)
	}

	// 2. Check root privileges
	if inj.geteuid != nil && inj.geteuid() != 0 {
		return fmt.Errorf("must run as root (try sudo)")
	}

	// 3. Detect distro family
	family, _ := detectDistro(inj.osReleasePath)

	// Determine targets to try based on detected family
	var targets []distroTarget
	switch family {
	case DistroDebian:
		targets = append(targets, knownDistroTargets[DistroDebian], knownDistroTargets[DistroRHEL])
	case DistroRHEL:
		targets = append(targets, knownDistroTargets[DistroRHEL], knownDistroTargets[DistroDebian])
	case DistroAlpine:
		targets = append(targets, knownDistroTargets[DistroAlpine], knownDistroTargets[DistroRHEL])
	default:
		targets = append(targets, knownDistroTargets[DistroDebian], knownDistroTargets[DistroRHEL])
	}

	var lastErr error
	for _, target := range targets {
		destDir := filepath.Dir(target.destPath)
		if _, err := os.Stat(destDir); os.IsNotExist(err) {
			inj.logger.Warn("Trust store path not found, skipping", "path", destDir)
			continue
		}

		// Copy certificate to destination
		if err := os.WriteFile(target.destPath, certData, 0644); err != nil {
			lastErr = fmt.Errorf("failed to copy cert to %s: %w", target.destPath, err)
			continue
		}

		// Run update command (appliance PATH may lack /usr/sbin).
		cmdName := resolveTrustCommand(target.commandName)
		var cmd *exec.Cmd
		if len(target.commandArgs) > 0 {
			cmd = exec.Command(cmdName, target.commandArgs...)
		} else {
			cmd = exec.Command(cmdName)
		}

		out, err := cmd.CombinedOutput()
		if err != nil {
			inj.logger.Error("CA injection failed", "stderr", string(out), "error", err)
			lastErr = fmt.Errorf("failed running %s: %w (output: %s)", target.commandName, err, string(out))
			continue
		}

		inj.logger.Info("CA installed", "distro_family", target.family, "dest_path", target.destPath)
		return nil
	}

	if lastErr != nil {
		return lastErr
	}
	return fmt.Errorf("no supported trust store directory found")
}

func resolveTrustCommand(name string) string {
	if filepath.IsAbs(name) {
		return name
	}
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	for _, dir := range []string{"/usr/sbin", "/usr/bin", "/sbin", "/bin"} {
		p := filepath.Join(dir, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p
		}
	}
	return name
}

// GenerateEnvScript writes a sourceable shell script that sets runtime CA env vars.
func (inj *Injector) GenerateEnvScript(certPath, outputPath string) error {
	return generateEnvScript(certPath, outputPath, inj.logger)
}

// Verify tests if the CA certificate is trusted by the system trust store.
func (inj *Injector) Verify(certPath string) error {
	return inj.verifyWithPool(certPath, nil)
}

// verifyWithPool verifies CA trust using a custom or system root CA pool.
func (inj *Injector) verifyWithPool(certPath string, roots *x509.CertPool) error {
	caCert, caKey, err := loadCACertAndKey(certPath)
	if err != nil {
		return fmt.Errorf("failed to load CA cert/key from %s: %w", certPath, err)
	}

	// Generate leaf certificate signed by CA
	leafKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return fmt.Errorf("failed to generate leaf private key: %w", err)
	}

	serialNumberLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serialNumber, err := rand.Int(rand.Reader, serialNumberLimit)
	if err != nil {
		return fmt.Errorf("failed to generate leaf serial number: %w", err)
	}

	leafTemplate := x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName: "127.0.0.1",
		},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.IPv6loopback},
		DNSNames:    []string{"localhost"},
		NotBefore:   time.Now().Add(-1 * time.Hour),
		NotAfter:    time.Now().Add(24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}

	leafDER, err := x509.CreateCertificate(rand.Reader, &leafTemplate, caCert, &leafKey.PublicKey, caKey)
	if err != nil {
		return fmt.Errorf("failed to create leaf certificate: %w", err)
	}

	tlsCert := tls.Certificate{
		Certificate: [][]byte{leafDER, caCert.Raw},
		PrivateKey:  leafKey,
	}

	// Start local TLS server
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("failed to listen on local port: %w", err)
	}

	tlsLn := tls.NewListener(ln, &tls.Config{
		Certificates: []tls.Certificate{tlsCert},
	})

	server := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("ok"))
		}),
	}

	go func() {
		_ = server.Serve(tlsLn)
	}()
	defer server.Close()

	// Make HTTPS GET request to verify handshake
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				RootCAs: roots,
			},
		},
	}
	defer client.CloseIdleConnections()

	serverURL := fmt.Sprintf("https://127.0.0.1:%d", ln.Addr().(*net.TCPAddr).Port)
	resp, err := client.Get(serverURL)
	if err != nil {
		return fmt.Errorf("TLS handshake verification failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	return nil
}

// loadCACertAndKey loads the CA certificate and private key from certPath or companion files.
func loadCACertAndKey(certPath string) (*x509.Certificate, crypto.PrivateKey, error) {
	data, err := os.ReadFile(certPath)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to read cert file: %w", err)
	}

	var caCert *x509.Certificate
	var caKey crypto.PrivateKey

	rest := data
	for len(rest) > 0 {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}

		if block.Type == "CERTIFICATE" && caCert == nil {
			cert, err := x509.ParseCertificate(block.Bytes)
			if err == nil {
				caCert = cert
			}
		} else if isPrivateKeyType(block.Type) && caKey == nil {
			key, err := parsePrivateKey(block.Bytes)
			if err == nil {
				caKey = key
			}
		}
	}

	if caCert == nil {
		return nil, nil, fmt.Errorf("no certificate found in %s", certPath)
	}

	if caKey != nil {
		return caCert, caKey, nil
	}

	// Try companion key files
	candidates := []string{
		certPath + ".key",
		strings.TrimSuffix(certPath, filepath.Ext(certPath)) + ".key",
		filepath.Join(filepath.Dir(certPath), "ca.key"),
		filepath.Join(filepath.Dir(certPath), "proxy-ca.key"),
	}

	for _, keyPath := range candidates {
		keyData, err := os.ReadFile(keyPath)
		if err != nil {
			continue
		}
		keyRest := keyData
		for len(keyRest) > 0 {
			var block *pem.Block
			block, keyRest = pem.Decode(keyRest)
			if block == nil {
				break
			}
			if isPrivateKeyType(block.Type) {
				key, err := parsePrivateKey(block.Bytes)
				if err == nil {
					return caCert, key, nil
				}
			}
		}
	}

	return nil, nil, fmt.Errorf("private key not found for %s", certPath)
}

func isPrivateKeyType(pemType string) bool {
	switch pemType {
	case "RSA PRIVATE KEY", "PRIVATE KEY", "EC PRIVATE KEY":
		return true
	default:
		return false
	}
}

func parsePrivateKey(der []byte) (crypto.PrivateKey, error) {
	if key, err := x509.ParsePKCS1PrivateKey(der); err == nil {
		return key, nil
	}
	if key, err := x509.ParsePKCS8PrivateKey(der); err == nil {
		switch k := key.(type) {
		case *rsa.PrivateKey, *ecdsa.PrivateKey, ed25519.PrivateKey:
			return k, nil
		default:
			return nil, fmt.Errorf("unsupported PKCS8 private key type: %T", key)
		}
	}
	if key, err := x509.ParseECPrivateKey(der); err == nil {
		return key, nil
	}
	return nil, fmt.Errorf("failed to parse private key")
}
