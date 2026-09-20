package main

import (
	"context"
	"net/http"

	"proxy_implementation/shared_types"
)

// defaultRuleEngine provides a fallback stub implementation of types.RuleEngine.
type defaultRuleEngine struct{}

func (e *defaultRuleEngine) Match(req *http.Request) []types.Rule {
	return nil
}

func (e *defaultRuleEngine) Start(ctx context.Context) error {
	return nil
}

func (e *defaultRuleEngine) Stop() {}

// defaultDispatcher provides a fallback stub implementation of types.HandlerDispatcher.
type defaultDispatcher struct{}

func (d *defaultDispatcher) Dispatch(ctx context.Context, rule types.Rule, meta types.HandlerMetadata, req types.RequestData, resp *types.ResponseData) (*types.HandlerResult, error) {
	return nil, nil
}

// defaultCAInjector provides a fallback stub implementation of types.CAInjector.
type defaultCAInjector struct{}

func (c *defaultCAInjector) InjectSystemCA(certPath string) error {
	return nil
}

func (c *defaultCAInjector) GenerateEnvScript(certPath string, outputPath string) error {
	return nil
}

func (c *defaultCAInjector) Verify(certPath string) error {
	return nil
}
