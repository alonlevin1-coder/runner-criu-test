package cainjector

import (
	"bufio"
	"os"
	"strings"
)

// Distro family constants.
const (
	DistroDebian  = "debian"
	DistroRHEL    = "rhel"
	DistroAlpine  = "alpine"
	DistroUnknown = "unknown"
)

type distroTarget struct {
	family      string
	destPath    string
	commandName string
	commandArgs []string
}

var knownDistroTargets = map[string]distroTarget{
	DistroDebian: {
		family:      DistroDebian,
		destPath:    "/usr/local/share/ca-certificates/proxy-ca.crt",
		commandName: "update-ca-certificates",
		commandArgs: nil,
	},
	DistroRHEL: {
		family:      DistroRHEL,
		destPath:    "/etc/pki/ca-trust/source/anchors/proxy-ca.pem",
		commandName: "update-ca-trust",
		commandArgs: []string{"extract"},
	},
	DistroAlpine: {
		family:      DistroAlpine,
		destPath:    "/usr/local/share/ca-certificates/proxy-ca.crt",
		commandName: "update-ca-certificates",
		commandArgs: nil,
	},
}

// detectDistro reads an os-release file and returns the distro family.
// osReleasePath allows tests to pass a mock file.
func detectDistro(osReleasePath string) (string, error) {
	file, err := os.Open(osReleasePath)
	if err != nil {
		return DistroUnknown, err
	}
	defer file.Close()

	var idVal, idLikeVal string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		key, val, found := strings.Cut(line, "=")
		if !found {
			continue
		}

		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)
		val = strings.Trim(val, `"'`)

		switch key {
		case "ID":
			idVal = strings.ToLower(val)
		case "ID_LIKE":
			idLikeVal = strings.ToLower(val)
		}
	}

	if err := scanner.Err(); err != nil {
		return DistroUnknown, err
	}

	// Detection logic:
	// If ID or ID_LIKE contains debian or ubuntu -> "debian"
	if strings.Contains(idVal, "debian") || strings.Contains(idVal, "ubuntu") ||
		strings.Contains(idLikeVal, "debian") || strings.Contains(idLikeVal, "ubuntu") {
		return DistroDebian, nil
	}

	// If ID or ID_LIKE contains rhel, centos, or fedora -> "rhel"
	if strings.Contains(idVal, "rhel") || strings.Contains(idVal, "centos") || strings.Contains(idVal, "fedora") ||
		strings.Contains(idLikeVal, "rhel") || strings.Contains(idLikeVal, "centos") || strings.Contains(idLikeVal, "fedora") {
		return DistroRHEL, nil
	}

	// If ID contains alpine -> "alpine"
	if strings.Contains(idVal, "alpine") || strings.Contains(idLikeVal, "alpine") {
		return DistroAlpine, nil
	}

	return DistroUnknown, nil
}
