package cainjector

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRuntimeVarsCoversAWSAndNode(t *testing.T) {
	vars := RuntimeVars("/leaf.pem", "/bundle.crt")
	got := map[string]string{}
	for _, kv := range vars {
		got[kv[0]] = kv[1]
	}
	if got["AWS_CA_BUNDLE"] != "/bundle.crt" {
		t.Fatalf("AWS_CA_BUNDLE=%q", got["AWS_CA_BUNDLE"])
	}
	if got["PIP_CERT"] != "/bundle.crt" {
		t.Fatalf("PIP_CERT=%q", got["PIP_CERT"])
	}
	if got["NODE_EXTRA_CA_CERTS"] != "/leaf.pem" {
		t.Fatalf("NODE_EXTRA_CA_CERTS=%q", got["NODE_EXTRA_CA_CERTS"])
	}
	if got["SSL_CERT_FILE"] != "/bundle.crt" {
		t.Fatalf("SSL_CERT_FILE=%q", got["SSL_CERT_FILE"])
	}
}

func TestUpsertEnvironmentMergesNodeOptions(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "environment")
	if err := os.WriteFile(path, []byte("PATH=/usr/bin\nNODE_OPTIONS=--max-old-space-size=64\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := upsertEnvironmentFile(path, "/leaf.pem", "/bundle.crt"); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	body := string(raw)
	if !strings.Contains(body, "PATH=/usr/bin") {
		t.Fatalf("lost PATH:\n%s", body)
	}
	if !strings.Contains(body, "AWS_CA_BUNDLE=/bundle.crt") {
		t.Fatalf("missing AWS_CA_BUNDLE:\n%s", body)
	}
	if !strings.Contains(body, "NODE_OPTIONS=--max-old-space-size=64 --use-openssl-ca") {
		t.Fatalf("NODE_OPTIONS merge failed:\n%s", body)
	}
	if strings.Count(body, "AWS_CA_BUNDLE=") != 1 {
		t.Fatalf("duplicate keys:\n%s", body)
	}
	if err := upsertEnvironmentFile(path, "/leaf.pem", "/bundle.crt"); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(path)
	if strings.Count(string(raw), "AWS_CA_BUNDLE=") != 1 {
		t.Fatalf("second upsert duplicated keys:\n%s", raw)
	}
}

func TestGenerateEnvScriptIncludesAWS(t *testing.T) {
	dir := t.TempDir()
	cert := filepath.Join(dir, "ca.pem")
	out := filepath.Join(dir, "proxy_env.sh")
	if err := os.WriteFile(cert, []byte("dummy"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := generateEnvScript(cert, out, nil); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	body := string(raw)
	for _, want := range []string{"AWS_CA_BUNDLE", "PIP_CERT", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE"} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing %s in\n%s", want, body)
		}
	}
}

func TestInstallSkipSystemWritesFiles(t *testing.T) {
	dir := t.TempDir()
	cert := filepath.Join(dir, "ca.pem")
	if err := os.WriteFile(cert, []byte("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"), 0644); err != nil {
		t.Fatal(err)
	}
	envFile := filepath.Join(dir, "environment")
	profile := filepath.Join(dir, "profile.sh")
	inj := NewCAInjector(InjectorConfig{})
	err := inj.Install(cert, InstallOptions{
		SkipSystem:      true,
		EnvironmentFile: envFile,
		ProfileScript:   profile,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{envFile, profile} {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(b), "AWS_CA_BUNDLE") {
			t.Fatalf("%s missing AWS_CA_BUNDLE:\n%s", p, b)
		}
	}
}
