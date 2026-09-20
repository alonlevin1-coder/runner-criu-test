package main

import (
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"proxy_implementation/shared_types"
)

// applyRequestModifications applies non-nil modification fields to an HTTP request.
func applyRequestModifications(req *http.Request, mod *types.RequestModification) {
	if req == nil || mod == nil {
		return
	}

	if mod.Method != nil {
		req.Method = *mod.Method
	}

	if mod.Path != nil {
		if req.URL != nil {
			req.URL.Path = *mod.Path
		}
	}

	if mod.Headers != nil {
		if req.Header == nil {
			req.Header = make(http.Header)
		}
		for k, v := range mod.Headers {
			req.Header.Set(k, v)
		}
	}

	if mod.Body != nil {
		bodyBytes := []byte(*mod.Body)
		req.Body = io.NopCloser(strings.NewReader(*mod.Body))
		req.ContentLength = int64(len(bodyBytes))
		if req.Header == nil {
			req.Header = make(http.Header)
		}
		req.Header.Set("Content-Length", strconv.Itoa(len(bodyBytes)))
	}
}

// applyResponseModifications applies non-nil modification fields to an HTTP response.
func applyResponseModifications(resp *http.Response, mod *types.ResponseModification) {
	if resp == nil || mod == nil {
		return
	}

	if mod.Status != nil {
		resp.StatusCode = *mod.Status
		resp.Status = fmt.Sprintf("%d %s", *mod.Status, http.StatusText(*mod.Status))
	}

	if mod.Headers != nil {
		if resp.Header == nil {
			resp.Header = make(http.Header)
		}
		for k, v := range mod.Headers {
			resp.Header.Set(k, v)
		}
	}

	if mod.Body != nil {
		bodyBytes := []byte(*mod.Body)
		resp.Body = io.NopCloser(strings.NewReader(*mod.Body))
		resp.ContentLength = int64(len(bodyBytes))
		if resp.Header == nil {
			resp.Header = make(http.Header)
		}
		resp.Header.Set("Content-Length", strconv.Itoa(len(bodyBytes)))
		resp.Header.Del("Transfer-Encoding")
		resp.TransferEncoding = nil
	}
}
