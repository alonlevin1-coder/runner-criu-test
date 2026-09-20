package goproxy

import (
	"bytes"
	"io"
	"net/http"
	"strconv"
	"strings"
)

func transferEncodingChunked(resp *http.Response) bool {
	if resp == nil {
		return false
	}
	for _, enc := range resp.TransferEncoding {
		if strings.EqualFold(enc, "chunked") {
			return true
		}
	}
	return strings.Contains(strings.ToLower(resp.Header.Get("Transfer-Encoding")), "chunked")
}

// originUsedContentLength reports whether the upstream response used a known
// Content-Length (as opposed to chunked / unknown-length streaming).
func originUsedContentLength(resp *http.Response) bool {
	if resp == nil {
		return false
	}
	if transferEncodingChunked(resp) {
		return false
	}
	if resp.Header.Get("Content-Length") != "" {
		return true
	}
	return resp.ContentLength >= 0
}

func statusHasNoBody(status int) bool {
	return status == http.StatusNoContent || status == http.StatusNotModified ||
		(status >= 100 && status < 200)
}

// preserveOriginFraming keeps the origin's body framing after a handler rewrite.
// Content-Length origins: buffer the new body and set Content-Length to its size.
// Chunked / unknown-length origins: keep chunked (do not invent a length).
func preserveOriginFraming(resp *http.Response, usedContentLength bool, bodyChanged bool) {
	if resp == nil || !bodyChanged {
		return
	}
	if statusHasNoBody(resp.StatusCode) || resp.Body == nil || resp.Body == http.NoBody {
		if usedContentLength {
			if resp.ContentLength < 0 {
				resp.ContentLength = 0
			}
			resp.Header.Set("Content-Length", strconv.FormatInt(resp.ContentLength, 10))
			resp.Header.Del("Transfer-Encoding")
			resp.TransferEncoding = nil
		} else {
			resp.ContentLength = -1
			resp.Header.Del("Content-Length")
			resp.TransferEncoding = []string{"chunked"}
			resp.Header.Set("Transfer-Encoding", "chunked")
		}
		return
	}

	if usedContentLength {
		body, err := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if err != nil {
			body = nil
		}
		resp.Body = io.NopCloser(bytes.NewReader(body))
		n := int64(len(body))
		resp.ContentLength = n
		if resp.Header == nil {
			resp.Header = make(http.Header)
		}
		resp.Header.Set("Content-Length", strconv.FormatInt(n, 10))
		resp.Header.Del("Transfer-Encoding")
		resp.TransferEncoding = nil
		return
	}

	resp.ContentLength = -1
	if resp.Header == nil {
		resp.Header = make(http.Header)
	}
	resp.Header.Del("Content-Length")
	resp.TransferEncoding = []string{"chunked"}
	resp.Header.Set("Transfer-Encoding", "chunked")
}
