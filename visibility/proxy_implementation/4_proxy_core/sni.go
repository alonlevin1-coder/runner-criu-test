package main

import (
	"encoding/binary"
	"io"
	"net"
	"strings"
	"time"
)

func sniBypass(sni string) bool {
	h := strings.ToLower(strings.TrimSpace(sni))
	if h == "" {
		return false
	}
	if i := strings.IndexByte(h, ':'); i >= 0 {
		h = h[:i]
	}
	for _, suf := range []string{
		"docker.io",
		"docker.com",
		"ghcr.io",
		"gcr.io",
		"googleapis.com",
	} {
		if h == suf || strings.HasSuffix(h, "."+suf) {
			return true
		}
	}
	return false
}

func readTLSRecord(conn net.Conn, first []byte) ([]byte, error) {
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer conn.SetReadDeadline(time.Time{})
	hdr := make([]byte, 5)
	copy(hdr, first)
	if _, err := io.ReadFull(conn, hdr[len(first):]); err != nil {
		return nil, err
	}
	n := int(binary.BigEndian.Uint16(hdr[3:5]))
	if n <= 0 || n > 1<<16 {
		return hdr, nil
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(conn, payload); err != nil {
		return nil, err
	}
	out := make([]byte, 0, 5+n)
	out = append(out, hdr...)
	out = append(out, payload...)
	return out, nil
}

// parseClientHelloSNI extracts SNI from a TLS record containing a ClientHello.
func parseClientHelloSNI(rec []byte) string {
	if len(rec) < 5 || rec[0] != 0x16 {
		return ""
	}
	hs := rec[5:]
	if len(hs) < 4 || hs[0] != 0x01 {
		return ""
	}
	hsLen := int(hs[1])<<16 | int(hs[2])<<8 | int(hs[3])
	if 4+hsLen > len(hs) {
		hsLen = len(hs) - 4
	}
	p := hs[4 : 4+hsLen]
	// client_version(2) + random(32) + session_id
	if len(p) < 34 {
		return ""
	}
	p = p[34:]
	if len(p) < 1 {
		return ""
	}
	sidLen := int(p[0])
	p = p[1:]
	if len(p) < sidLen+2 {
		return ""
	}
	p = p[sidLen:]
	csLen := int(p[0])<<8 | int(p[1])
	p = p[2:]
	if len(p) < csLen+1 {
		return ""
	}
	p = p[csLen:]
	compLen := int(p[0])
	p = p[1:]
	if len(p) < compLen+2 {
		return ""
	}
	p = p[compLen:]
	extLen := int(p[0])<<8 | int(p[1])
	p = p[2:]
	if extLen > len(p) {
		extLen = len(p)
	}
	exts := p[:extLen]
	for len(exts) >= 4 {
		typ := int(exts[0])<<8 | int(exts[1])
		l := int(exts[2])<<8 | int(exts[3])
		exts = exts[4:]
		if l > len(exts) {
			break
		}
		data := exts[:l]
		exts = exts[l:]
		if typ != 0 || len(data) < 2 {
			continue
		}
		list := data[2:]
		if len(list) < 3 {
			continue
		}
		nameType := list[0]
		nl := int(list[1])<<8 | int(list[2])
		if nameType != 0 || 3+nl > len(list) {
			continue
		}
		return string(list[3 : 3+nl])
	}
	return ""
}

func spliceBypass(client net.Conn, peeked []byte, origDst *net.TCPAddr, sni string) {
	dest := ""
	if origDst != nil {
		dest = origDst.String()
	} else if sni != "" {
		dest = net.JoinHostPort(sni, "443")
	}
	if dest == "" {
		client.Close()
		return
	}
	up, err := net.DialTimeout("tcp", dest, 15*time.Second)
	if err != nil {
		client.Close()
		return
	}
	if _, err := up.Write(peeked); err != nil {
		up.Close()
		client.Close()
		return
	}
	go func() {
		_, _ = io.Copy(up, client)
		up.Close()
		client.Close()
	}()
	_, _ = io.Copy(client, up)
	up.Close()
	client.Close()
}
