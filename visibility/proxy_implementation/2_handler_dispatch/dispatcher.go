package dispatch

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"proxy_implementation/shared_types"
)

// DispatcherConfig holds configuration for the Dispatcher.
type DispatcherConfig struct {
	Timeout time.Duration // Default: 5s
	Logger  *slog.Logger
}

// Dispatcher implements the types.HandlerDispatcher interface.
type Dispatcher struct {
	client  *http.Client
	timeout time.Duration
	logger  *slog.Logger
}

// NewDispatcher creates a new Dispatcher with the provided configuration.
func NewDispatcher(cfg DispatcherConfig) *Dispatcher {
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}

	tr := &http.Transport{
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 20,
		IdleConnTimeout:     90 * time.Second,
	}

	client := &http.Client{
		Transport: tr,
	}

	return &Dispatcher{
		client:  client,
		timeout: timeout,
		logger:  logger,
	}
}

// Dispatch constructs the JSON payload per the rule's PayloadConfig,
// POSTs it to the handler_endpoint, and parses the response.
// Returns (nil, nil) on timeout, connection error, non-2xx status, or malformed JSON.
func (d *Dispatcher) Dispatch(ctx context.Context, rule types.Rule, meta types.HandlerMetadata, req types.RequestData, resp *types.ResponseData) (*types.HandlerResult, error) {
	pCfg := rule.Intercept.Payload

	// Build RequestData
	reqData := types.RequestData{
		Method: req.Method,
		Path:   req.Path,
	}
	if pCfg.IncludeRequestHeaders {
		reqData.Headers = req.Headers
	}
	if pCfg.IncludeRequestBody {
		reqData.Body = req.Body
	}

	payload := types.HandlerPayload{
		RuleName: rule.Name,
		Meta:     meta,
		Request:  &reqData,
	}

	// Build ResponseData if in RESPONSE phase
	if resp != nil {
		respData := types.ResponseData{
			Status: resp.Status,
		}
		if pCfg.IncludeResponseHeaders {
			respData.Headers = resp.Headers
		}
		if pCfg.IncludeResponseBody {
			respData.Body = resp.Body
		}
		payload.Response = &respData
	}

	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal handler payload: %w", err)
	}

	ctxWithTimeout, cancel := context.WithTimeout(ctx, d.timeout)
	defer cancel()

	httpReq, err := http.NewRequestWithContext(ctxWithTimeout, http.MethodPost, rule.Intercept.HandlerEndpoint, bytes.NewReader(payloadBytes))
	if err != nil {
		d.logger.Error("Handler error",
			slog.String("rule_name", rule.Name),
			slog.String("endpoint", rule.Intercept.HandlerEndpoint),
			slog.Any("error", err),
			slog.Int("status_code", 0),
		)
		return nil, nil
	}
	httpReq.Header.Set("Content-Type", "application/json")

	startTime := time.Now()
	httpResp, err := d.client.Do(httpReq)
	if err != nil {
		if errors.Is(ctxWithTimeout.Err(), context.DeadlineExceeded) {
			d.logger.Warn("Handler timeout",
				slog.String("rule_name", rule.Name),
				slog.String("endpoint", rule.Intercept.HandlerEndpoint),
				slog.Int64("timeout_ms", d.timeout.Milliseconds()),
			)
			return nil, nil
		}
		if errors.Is(ctx.Err(), context.Canceled) || errors.Is(ctxWithTimeout.Err(), context.Canceled) {
			d.logger.Warn("Handler context canceled",
				slog.String("rule_name", rule.Name),
				slog.String("endpoint", rule.Intercept.HandlerEndpoint),
			)
			return nil, nil
		}
		d.logger.Error("Handler error",
			slog.String("rule_name", rule.Name),
			slog.String("endpoint", rule.Intercept.HandlerEndpoint),
			slog.Any("error", err),
			slog.Int("status_code", 0),
		)
		return nil, nil
	}
	defer httpResp.Body.Close()

	if httpResp.StatusCode < 200 || httpResp.StatusCode >= 300 {
		d.logger.Error("Handler error",
			slog.String("rule_name", rule.Name),
			slog.String("endpoint", rule.Intercept.HandlerEndpoint),
			slog.String("error", fmt.Sprintf("non-2xx status code: %d", httpResp.StatusCode)),
			slog.Int("status_code", httpResp.StatusCode),
		)
		return nil, nil
	}

	bodyBytes, err := io.ReadAll(httpResp.Body)
	if err != nil {
		if errors.Is(ctxWithTimeout.Err(), context.DeadlineExceeded) {
			d.logger.Warn("Handler timeout",
				slog.String("rule_name", rule.Name),
				slog.String("endpoint", rule.Intercept.HandlerEndpoint),
				slog.Int64("timeout_ms", d.timeout.Milliseconds()),
			)
			return nil, nil
		}
		d.logger.Error("Handler error",
			slog.String("rule_name", rule.Name),
			slog.String("endpoint", rule.Intercept.HandlerEndpoint),
			slog.Any("error", err),
			slog.Int("status_code", httpResp.StatusCode),
		)
		return nil, nil
	}

	var result types.HandlerResult
	if err := json.Unmarshal(bodyBytes, &result); err != nil {
		d.logger.Error("Handler error",
			slog.String("rule_name", rule.Name),
			slog.String("endpoint", rule.Intercept.HandlerEndpoint),
			slog.Any("error", err),
			slog.Int("status_code", httpResp.StatusCode),
		)
		return nil, nil
	}

	durationMs := time.Since(startTime).Milliseconds()
	d.logger.Info("Handler dispatched",
		slog.String("rule_name", rule.Name),
		slog.String("endpoint", rule.Intercept.HandlerEndpoint),
		slog.Int64("duration_ms", durationMs),
	)

	return &result, nil
}
