package rerouter

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"fmt"
	"math/big"
	"net"
	"strings"
	"sync"
	"time"
)

// CertCache generates and caches TLS server certificates on-the-fly,
// signed by a given Root CA.
type CertCache struct {
	caTLSCert tls.Certificate
	caCert    *x509.Certificate
	caKey     *rsa.PrivateKey
	cache     sync.Map
}

// NewCertCache creates a new CertCache for signing certificates with the given Root CA.
func NewCertCache(caTLSCert tls.Certificate) (*CertCache, error) {
	if len(caTLSCert.Certificate) == 0 {
		return nil, errors.New("empty CA certificate")
	}

	caCert, err := x509.ParseCertificate(caTLSCert.Certificate[0])
	if err != nil {
		return nil, fmt.Errorf("failed to parse CA certificate: %w", err)
	}

	rsaKey, ok := caTLSCert.PrivateKey.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("CA private key is not an RSA private key")
	}

	return &CertCache{
		caTLSCert: caTLSCert,
		caCert:    caCert,
		caKey:     rsaKey,
	}, nil
}

// GetCertificate returns a TLS certificate for the requested SNI hostname or IP address.
func (c *CertCache) GetCertificate(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
	host := hello.ServerName
	if host == "" {
		host = "127.0.0.1"
	}
	return c.GetCertificateForHost(host)
}

// GetCertificateForHost returns a cached or newly minted TLS certificate for the given host.
func (c *CertCache) GetCertificateForHost(host string) (*tls.Certificate, error) {
	// Strip port if present
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.TrimPrefix(host, "[")
	host = strings.TrimSuffix(host, "]")
	host = strings.ToLower(host)

	if val, ok := c.cache.Load(host); ok {
		cert := val.(tls.Certificate)
		return &cert, nil
	}

	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, fmt.Errorf("failed to generate RSA private key for host cert: %w", err)
	}

	serialLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, serialLimit)
	if err != nil {
		return nil, fmt.Errorf("failed to generate serial number: %w", err)
	}

	tmpl := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   host,
			Organization: []string{"Proxy Core MITM"},
		},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}

	if ip := net.ParseIP(host); ip != nil {
		tmpl.IPAddresses = []net.IP{ip}
	} else {
		tmpl.DNSNames = []string{host}
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &tmpl, c.caCert, &priv.PublicKey, c.caKey)
	if err != nil {
		return nil, fmt.Errorf("failed to create host certificate: %w", err)
	}

	cert := tls.Certificate{
		Certificate: [][]byte{derBytes, c.caCert.Raw},
		PrivateKey:  priv,
	}

	c.cache.Store(host, cert)
	return &cert, nil
}
