package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	ruleengine "proxy_implementation/1_rule_engine"
	dispatch "proxy_implementation/2_handler_dispatch"
	cainjector "proxy_implementation/3_ca_injector"
	rerouter "proxy_implementation/6_transparent_rerouter"
	"proxy_implementation/shared_types"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:8080", "Listen address")
	rules := flag.String("rules", "./rules.yaml", "Path to rules.yaml")
	caDir := flag.String("ca-dir", "./ca/", "Directory for CA cert/key")
	inject := flag.Bool("inject-ca", false, "Run CA injection on startup")
	envScript := flag.String("env-script", "./proxy_env.sh", "Path to write env script")
	timeout := flag.Int("timeout", 5, "Handler timeout in seconds")
	transparent := flag.Bool("transparent", false, "Enable transparent proxy redirection mode")
	bypassUID := flag.Int("bypass-uid", 0, "Bypass UID for transparent rerouting (default: current process UID)")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	caCert, err := EnsureCA(*caDir)
	if err != nil {
		logger.Error("Failed to ensure Root CA", "error", err)
		os.Exit(1)
	}
	logger.Info("Root CA ready", "caDir", *caDir)

	var ruleEngine types.RuleEngine = ruleengine.NewEngine(*rules, logger)
	var dispatcher types.HandlerDispatcher = dispatch.NewDispatcher(dispatch.DispatcherConfig{
		Timeout: time.Duration(*timeout) * time.Second,
		Logger:  logger,
	})
	var caInjector types.CAInjector = cainjector.NewCAInjector(cainjector.InjectorConfig{
		Logger: logger,
	})

	if *inject {
		certPath := filepath.Join(*caDir, "ca-cert.pem")
		logger.Info("Injecting CA into system trust store", "certPath", certPath)
		if err := caInjector.InjectSystemCA(certPath); err != nil {
			logger.Error("Failed to inject CA", "error", err)
		} else {
			logger.Info("CA injected successfully")
		}

		if err := caInjector.GenerateEnvScript(certPath, *envScript); err != nil {
			logger.Error("Failed to generate env script", "error", err)
		} else {
			logger.Info("Env script generated", "path", *envScript)
		}
	}

	proxyServer := NewProxyServer(ruleEngine, dispatcher, caInjector, *listen, caCert, logger)

	if *transparent {
		_, portStr, err := net.SplitHostPort(*listen)
		if err != nil {
			logger.Error("Failed to parse listen port for transparent mode", "error", err)
			os.Exit(1)
		}
		proxyPort, err := strconv.Atoi(portStr)
		if err != nil {
			logger.Error("Invalid listen port", "port", portStr, "error", err)
			os.Exit(1)
		}
		uid := *bypassUID
		if uid <= 0 {
			uid = os.Geteuid()
		}
		rerouterInst := rerouter.NewRerouter(rerouter.RerouterConfig{
			ProxyPort: proxyPort,
			BypassUID: uid,
			Logger:    logger,
		})
		proxyServer.SetRerouter(rerouterInst)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigCh
		logger.Info("Shutdown signal received", "signal", sig.String())
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := proxyServer.Shutdown(shutdownCtx); err != nil {
			logger.Error("Error during shutdown", "error", err)
		}
	}()

	logger.Info("Starting proxy core orchestrator", "listen", *listen, "transparent", *transparent)
	if err := proxyServer.Start(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("Proxy server failed", "error", err)
		os.Exit(1)
	}
	logger.Info("Proxy server stopped")
}
