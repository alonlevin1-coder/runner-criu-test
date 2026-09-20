package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/elazarl/goproxy"
	rerouter "proxy_implementation/6_transparent_rerouter"
	"proxy_implementation/shared_types"
)

// ProxyServer is the orchestrator tying together goproxy, RuleEngine,
// HandlerDispatcher, CAInjector, and TransparentRerouter.
type ProxyServer struct {
	ruleEngine types.RuleEngine
	dispatcher types.HandlerDispatcher
	caInjector types.CAInjector
	rerouter   types.TransparentRerouter
	listenAddr string
	logger     *slog.Logger
	server     *http.Server
	proxy      *goproxy.ProxyHttpServer
	caCert     tls.Certificate
	certCache  *rerouter.CertCache
}

type responseContextData struct {
	rules   []types.Rule
	meta    types.HandlerMetadata
	reqData types.RequestData
}

func generateUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func extractServerAddr(req *http.Request) string {
	if req == nil {
		return ""
	}
	host := ""
	if req.URL != nil && req.URL.Host != "" {
		host = req.URL.Host
	} else if req.Host != "" {
		host = req.Host
	}

	if host == "" {
		return ""
	}

	if _, _, err := net.SplitHostPort(host); err != nil {
		scheme := "http"
		if req.TLS != nil || (req.URL != nil && strings.EqualFold(req.URL.Scheme, "https")) {
			scheme = "https"
		}
		port := "80"
		if scheme == "https" {
			port = "443"
		}
		cleanHost := strings.TrimPrefix(host, "[")
		cleanHost = strings.TrimSuffix(cleanHost, "]")
		return net.JoinHostPort(cleanHost, port)
	}
	return host
}

// NewProxyServer creates and configures a ProxyServer using the provided interfaces.
func NewProxyServer(
	ruleEngine types.RuleEngine,
	dispatcher types.HandlerDispatcher,
	caInjector types.CAInjector,
	listenAddr string,
	caCert tls.Certificate,
	logger *slog.Logger,
) *ProxyServer {
	if logger == nil {
		logger = slog.Default()
	}

	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = false

	var certCache *rerouter.CertCache
	if len(caCert.Certificate) > 0 {
		goproxy.GoproxyCa = caCert
		proxy.OnRequest().HandleConnect(goproxy.AlwaysMitm)
		logger.Info("CA loaded for MITM proxy")
		var err error
		certCache, err = rerouter.NewCertCache(caCert)
		if err != nil {
			logger.Warn("Failed to initialize CertCache", "error", err)
		}
	}

	if proxy.Tr == nil {
		proxy.Tr = &http.Transport{}
	}
	if proxy.Tr.TLSClientConfig == nil {
		proxy.Tr.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	} else {
		proxy.Tr.TLSClientConfig.InsecureSkipVerify = true
	}

	_, listenPort, _ := net.SplitHostPort(listenAddr)

	proxy.NonproxyHandler = http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		host := req.Host
		if host == "" {
			host = req.URL.Host
		}
		cleanHost := strings.TrimPrefix(host, "[")
		cleanHost = strings.TrimSuffix(cleanHost, "]")

		isSelf := cleanHost == listenAddr ||
			(listenPort != "" && (cleanHost == "127.0.0.1:"+listenPort ||
				cleanHost == "localhost:"+listenPort ||
				cleanHost == "proxy:"+listenPort ||
				cleanHost == "0.0.0.0:"+listenPort))

		if isSelf && (req.URL.Path == "/" || req.URL.Path == "/health") {
			w.Header().Set("Content-Type", "text/plain")
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("Proxy is running\n"))
			return
		}

		if isSelf {
			http.Error(w, "This is a proxy server. Does not respond to non-proxy requests.", http.StatusBadRequest)
			return
		}

		if req.URL.Host == "" {
			req.URL.Host = req.Host
		}
		if req.URL.Scheme == "" {
			if req.TLS != nil {
				req.URL.Scheme = "https"
			} else {
				req.URL.Scheme = "http"
			}
		}
		proxy.ServeHTTP(w, req)
	})

	ps := &ProxyServer{
		ruleEngine: ruleEngine,
		dispatcher: dispatcher,
		caInjector: caInjector,
		listenAddr: listenAddr,
		logger:     logger,
		proxy:      proxy,
		caCert:     caCert,
		certCache:  certCache,
	}

	ps.server = &http.Server{
		Addr:    listenAddr,
		Handler: proxy,
	}

	// OnRequest Hook
	proxy.OnRequest().DoFunc(func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
		meta := types.HandlerMetadata{
			RequestID:    generateUUID(),
			ClientAddr:   req.RemoteAddr,
			ServerAddr:   extractServerAddr(req),
			TimestampUTC: time.Now().UTC().Format(time.RFC3339Nano),
		}

		if ps.ruleEngine == nil {
			ctx.UserData = &responseContextData{
				meta: meta,
			}
			return req, nil
		}

		rules := ps.ruleEngine.Match(req)
		var requestPhaseRules []types.Rule
		var responsePhaseRules []types.Rule

		for _, r := range rules {
			if r.Intercept.Phase == "REQUEST" {
				requestPhaseRules = append(requestPhaseRules, r)
			} else if r.Intercept.Phase == "RESPONSE" {
				responsePhaseRules = append(responsePhaseRules, r)
			}
		}

		var reqData types.RequestData
		if len(rules) > 0 {
			reqData = extractRequestData(req)
		}

		for _, rule := range requestPhaseRules {
			ps.logger.Info("Rule matched (REQUEST phase)",
				"rule", rule.Name,
				"method", req.Method,
				"path", req.URL.Path,
			)

			if ps.dispatcher == nil {
				continue
			}

			start := time.Now()
			result, err := ps.dispatcher.Dispatch(req.Context(), rule, meta, reqData, nil)
			duration := time.Since(start)

			if err != nil {
				ps.logger.Error("Handler dispatch failed",
					"rule", rule.Name,
					"error", err,
				)
				continue
			}

			if result == nil || (result.Request == nil && result.Response == nil) {
				ps.logger.Warn("Handler returned no modifications",
					"rule", rule.Name,
				)
				continue
			}

			if result.Request != nil {
				applyRequestModifications(req, result.Request)
				reqData = extractRequestData(req)
				ps.logger.Info("Handler response applied",
					"rule", rule.Name,
					"duration", duration,
				)
			}
		}

		ctx.UserData = &responseContextData{
			rules:   responsePhaseRules,
			meta:    meta,
			reqData: reqData,
		}
		return req, nil
	})

	// OnResponse Hook
	proxy.OnResponse().DoFunc(func(resp *http.Response, ctx *goproxy.ProxyCtx) *http.Response {
		if resp == nil {
			return resp
		}

		rcData, ok := ctx.UserData.(*responseContextData)
		if !ok || rcData == nil || len(rcData.rules) == 0 {
			return resp
		}

		if ps.dispatcher == nil {
			return resp
		}

		meta := rcData.meta
		reqData := rcData.reqData

		for _, rule := range rcData.rules {
			ps.logger.Info("Rule matched (RESPONSE phase)",
				"rule", rule.Name,
				"method", reqData.Method,
				"path", reqData.Path,
				"status", resp.StatusCode,
			)

			respData := extractResponseData(resp)
			start := time.Now()
			ctxReqContext := context.Background()
			if ctx.Req != nil && ctx.Req.Context() != nil {
				ctxReqContext = ctx.Req.Context()
			}

			result, err := ps.dispatcher.Dispatch(ctxReqContext, rule, meta, reqData, &respData)
			duration := time.Since(start)

			if err != nil {
				ps.logger.Error("Handler dispatch failed",
					"rule", rule.Name,
					"error", err,
				)
				continue
			}

			if result == nil || (result.Request == nil && result.Response == nil) {
				ps.logger.Warn("Handler returned no modifications",
					"rule", rule.Name,
				)
				continue
			}

			if result.Response != nil {
				applyResponseModifications(resp, result.Response)
				ps.logger.Info("Handler response applied",
					"rule", rule.Name,
					"duration", duration,
				)
			}
		}

		return resp
	})

	return ps
}

// SetRerouter configures a transparent rerouter for OS-level redirection.
func (ps *ProxyServer) SetRerouter(r types.TransparentRerouter) {
	ps.rerouter = r
}

// Start starts listening and serving HTTP traffic.
func (ps *ProxyServer) Start() error {
	if ps.ruleEngine != nil {
		if err := ps.ruleEngine.Start(context.Background()); err != nil {
			return fmt.Errorf("failed to start rule engine: %w", err)
		}
	}
	if ps.rerouter != nil {
		if err := ps.rerouter.Setup(); err != nil {
			ps.logger.Warn("Transparent rerouter setup failed", "error", err)
		}
	}
	l, err := net.Listen("tcp", ps.listenAddr)
	if err != nil {
		return fmt.Errorf("failed to listen on %s: %w", ps.listenAddr, err)
	}
	ps.logger.Info("Proxy started", "listenAddr", ps.listenAddr)
	return ps.Serve(l)
}

// Serve accepts incoming HTTP connections on the given listener.
func (ps *ProxyServer) Serve(l net.Listener) error {
	if ps.ruleEngine != nil {
		if err := ps.ruleEngine.Start(context.Background()); err != nil {
			return fmt.Errorf("failed to start rule engine: %w", err)
		}
	}
	var wrappedListener net.Listener = l
	if ps.certCache != nil {
		wrappedListener = &transparentListener{
			Listener:  l,
			certCache: ps.certCache,
			logger:    ps.logger,
		}
	}
	ps.logger.Info("Proxy serving", "listenAddr", l.Addr().String())
	return ps.server.Serve(wrappedListener)
}

// Shutdown gracefully stops the proxy server, rerouter, and rule engine.
func (ps *ProxyServer) Shutdown(ctx context.Context) error {
	if ps.rerouter != nil {
		if err := ps.rerouter.Cleanup(); err != nil {
			ps.logger.Warn("Transparent rerouter cleanup failed", "error", err)
		}
	}
	if ps.ruleEngine != nil {
		ps.ruleEngine.Stop()
	}
	if ps.server != nil {
		return ps.server.Shutdown(ctx)
	}
	return nil
}

type transparentListener struct {
	net.Listener
	certCache *rerouter.CertCache
	logger    *slog.Logger
}

func (tl *transparentListener) Accept() (net.Conn, error) {
	for {
		conn, err := tl.Listener.Accept()
		if err != nil {
			return nil, err
		}

		buf := make([]byte, 1)
		n, err := conn.Read(buf)
		if err != nil {
			conn.Close()
			continue
		}

		origDst, _ := rerouter.GetOriginalDst(conn)

		pConn := &origDstConn{
			Conn:    conn,
			prefix:  buf[:n],
			origDst: origDst,
		}

		if buf[0] == 0x16 && tl.certCache != nil {
			tlsConfig := &tls.Config{
				GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
					if hello.ServerName != "" {
						return tl.certCache.GetCertificateForHost(hello.ServerName)
					}
					if origDst != nil {
						return tl.certCache.GetCertificateForHost(origDst.IP.String())
					}
					return tl.certCache.GetCertificateForHost("127.0.0.1")
				},
			}
			tConn := tls.Server(pConn, tlsConfig)
			return tConn, nil
		}

		return pConn, nil
	}
}

type origDstConn struct {
	net.Conn
	prefix  []byte
	origDst *net.TCPAddr
}

func (o *origDstConn) Read(b []byte) (int, error) {
	if len(o.prefix) > 0 {
		n := copy(b, o.prefix)
		o.prefix = o.prefix[n:]
		return n, nil
	}
	return o.Conn.Read(b)
}

func (o *origDstConn) GetOriginalDst() *net.TCPAddr {
	return o.origDst
}

func extractRequestData(req *http.Request) types.RequestData {
	var reqData types.RequestData
	if req == nil {
		return reqData
	}

	reqData.Method = req.Method
	if req.URL != nil {
		reqData.Path = req.URL.Path
	}

	headers := make(map[string]string)
	if req.Host != "" {
		headers["Host"] = req.Host
	}
	for k, v := range req.Header {
		if len(v) > 0 {
			headers[k] = v[0]
		}
	}
	reqData.Headers = headers

	if req.Body != nil {
		bodyBytes, err := io.ReadAll(req.Body)
		if err == nil {
			req.Body.Close()
			req.Body = io.NopCloser(bytes.NewReader(bodyBytes))
			bodyStr := string(bodyBytes)
			reqData.Body = &bodyStr
		}
	}

	return reqData
}

func extractResponseData(resp *http.Response) types.ResponseData {
	var respData types.ResponseData
	if resp == nil {
		return respData
	}

	respData.Status = resp.StatusCode
	headers := make(map[string]string)
	for k, v := range resp.Header {
		if len(v) > 0 {
			headers[k] = v[0]
		}
	}
	respData.Headers = headers

	if resp.Body != nil {
		bodyBytes, err := io.ReadAll(resp.Body)
		if err == nil {
			resp.Body.Close()
			resp.Body = io.NopCloser(bytes.NewReader(bodyBytes))
			bodyStr := string(bodyBytes)
			respData.Body = &bodyStr
		}
	}

	return respData
}
