package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	cainjector "proxy_implementation/3_ca_injector"
)

func main() {
	cert := flag.String("cert", "", "Path to the proxy CA certificate (PEM)")
	skipSystem := flag.Bool("no-system", false, "Do not install into the distro trust store")
	environment := flag.String("environment", cainjector.DefaultEnvironmentFile, "PAM environment file (empty to skip)")
	profile := flag.String("profile", cainjector.DefaultProfileScript, "profile.d script (empty to skip)")
	envScript := flag.String("env-script", "", "Optional sourceable bash env script")
	logPath := flag.String("log", "", "Optional log file (default stderr)")
	flag.Parse()

	if *cert == "" {
		fmt.Fprintln(os.Stderr, "t9-ca-inject: --cert is required")
		os.Exit(2)
	}

	var w io.Writer = os.Stderr
	if *logPath != "" {
		f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		if err != nil {
			fmt.Fprintf(os.Stderr, "t9-ca-inject: open log: %v\n", err)
			os.Exit(1)
		}
		defer f.Close()
		w = io.MultiWriter(os.Stderr, f)
	}

	inj := cainjector.NewCAInjector(cainjector.InjectorConfig{
		Logger: cainjector.LoggerToWriter(w),
	})
	err := inj.Install(*cert, cainjector.InstallOptions{
		EnvironmentFile: *environment,
		ProfileScript:   *profile,
		EnvScript:       *envScript,
		SkipSystem:      *skipSystem,
		Logger:          cainjector.LoggerToWriter(w),
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "t9-ca-inject: %v\n", err)
		os.Exit(1)
	}
}
