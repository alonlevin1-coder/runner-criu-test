// Package types defines the shared data structures and interfaces used
// across all proxy components. This is the ONLY coupling point between
// the Rule Engine, Handler Dispatch, CA Injector, and Proxy Core.
//
// Each component depends on this package but NOT on each other.
package types

import (
	"context"
	"net/http"
)

// --- Rule Definition (mirrors YAML schema) ---

// Rule represents a single interception rule loaded from rules.yaml.
type Rule struct {
	Name      string       `yaml:"name"`
	Match     MatchCriteria `yaml:"match"`
	Intercept InterceptConfig `yaml:"intercept"`
}

// MatchCriteria defines what request properties to match against.
type MatchCriteria struct {
	Method    string            `yaml:"method"`
	PathRegex string            `yaml:"path_regex"`
	Headers   map[string]string `yaml:"headers"`
}

// InterceptConfig defines what to intercept and where to send it.
type InterceptConfig struct {
	Phase           string        `yaml:"phase"` // "REQUEST" or "RESPONSE"
	HandlerEndpoint string        `yaml:"handler_endpoint"`
	Payload         PayloadConfig `yaml:"payload"`
}

// PayloadConfig controls which parts of the request/response are sent to the handler.
type PayloadConfig struct {
	IncludeRequestHeaders  bool `yaml:"include_request_headers"`
	IncludeRequestBody     bool `yaml:"include_request_body"`
	IncludeResponseHeaders bool `yaml:"include_response_headers"`
	IncludeResponseBody    bool `yaml:"include_response_body"`
}

// --- Handler Protocol (JSON over HTTP) ---

// HandlerMetadata contains proxy-generated metadata about the HTTP transaction.
type HandlerMetadata struct {
	RequestID    string `json:"request_id"`
	ClientAddr   string `json:"client_addr"`
	ServerAddr   string `json:"server_addr"`
	TimestampUTC string `json:"timestamp_utc"`
}

// HandlerPayload is the JSON body POSTed to external handler endpoints.
type HandlerPayload struct {
	RuleName string            `json:"rule_name"`
	Meta     HandlerMetadata   `json:"meta"`
	Request  *RequestData      `json:"request,omitempty"`
	Response *ResponseData     `json:"response,omitempty"`
}

// RequestData carries captured HTTP request information.
type RequestData struct {
	Method  string            `json:"method"`
	Path    string            `json:"path"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    *string           `json:"body"` // nil when not included per PayloadConfig
}

// ResponseData carries captured HTTP response information.
type ResponseData struct {
	Status  int               `json:"status"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    *string           `json:"body"` // nil when not included per PayloadConfig
}

// HandlerResult is the JSON response returned by an external handler.
// Only non-nil fields are applied as modifications.
type HandlerResult struct {
	Request  *RequestModification  `json:"request,omitempty"`
	Response *ResponseModification `json:"response,omitempty"`
}

// RequestModification describes changes to apply to the original request.
type RequestModification struct {
	Method  *string           `json:"method,omitempty"`
	Path    *string           `json:"path,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    *string           `json:"body,omitempty"`
}

// ResponseModification describes changes to apply to the original response.
type ResponseModification struct {
	Status  *int              `json:"status,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    *string           `json:"body,omitempty"`
}

// --- Component Interfaces ---

// RuleEngine evaluates HTTP requests against loaded rules.
// It owns YAML loading, parsing, regex compilation, and hot-reload.
type RuleEngine interface {
	// Match returns all rules that match the given HTTP request.
	// The caller (Proxy Core) uses this to decide whether to intercept.
	Match(req *http.Request) []Rule

	// Start begins watching rules.yaml for changes (hot-reload).
	Start(ctx context.Context) error

	// Stop halts the file watcher and cleans up.
	Stop()
}

// HandlerDispatcher sends intercepted data to external handler processes
// and returns their modification instructions.
type HandlerDispatcher interface {
	// Dispatch constructs the JSON payload per the rule's PayloadConfig,
	// POSTs it to the handler_endpoint, and parses the response.
	// Returns nil HandlerResult (no modifications) on timeout or handler error.
	Dispatch(ctx context.Context, rule Rule, meta HandlerMetadata, req RequestData, resp *ResponseData) (*HandlerResult, error)
}

// CAInjector installs the proxy's Root CA into system trust stores
// and generates environment variable scripts for runtime coverage.
type CAInjector interface {
	// InjectSystemCA detects the Linux distro and installs the CA cert.
	InjectSystemCA(certPath string) error

	// GenerateEnvScript writes a sourceable shell script that sets
	// runtime-specific CA environment variables.
	GenerateEnvScript(certPath string, outputPath string) error

	// Verify attempts a test TLS handshake to confirm injection worked.
	Verify(certPath string) error
}

// TransparentRerouter manages OS-level firewall redirection for transparent proxying.
type TransparentRerouter interface {
	// Setup applies firewall redirection rules.
	Setup() error

	// Cleanup removes applied firewall rules.
	Cleanup() error

	// IsActive returns whether firewall rules are currently applied.
	IsActive() bool
}
