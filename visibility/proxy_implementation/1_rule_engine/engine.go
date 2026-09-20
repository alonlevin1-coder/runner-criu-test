package ruleengine

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"proxy_implementation/shared_types"

	"github.com/fsnotify/fsnotify"
	"gopkg.in/yaml.v3"
)

// rulesFile mirrors the top-level YAML structure of rules.yaml.
type rulesFile struct {
	Rules []types.Rule `yaml:"rules"`
}

// compiledRule pairs a shared types.Rule with its pre-compiled path regex pattern.
type compiledRule struct {
	rule        types.Rule
	pathPattern *regexp.Regexp
}

// Engine implements the types.RuleEngine interface.
type Engine struct {
	rulesPath     string
	absRulesPath  string
	logger        *slog.Logger
	mu            sync.RWMutex
	compiledRules []compiledRule
	rules         []types.Rule
	watcher       *fsnotify.Watcher
	done          chan struct{}
	wg            sync.WaitGroup
	stopOnce      sync.Once
}

// NewEngine creates a new Rule Engine instance.
func NewEngine(rulesPath string, logger *slog.Logger) *Engine {
	if logger == nil {
		logger = slog.Default()
	}
	absPath, err := filepath.Abs(rulesPath)
	if err != nil {
		absPath = filepath.Clean(rulesPath)
	}

	return &Engine{
		rulesPath:    rulesPath,
		absRulesPath: absPath,
		logger:       logger,
	}
}

// Start loads the rules from YAML, pre-compiles regex patterns,
// and starts the file watcher for hot-reloading.
func (e *Engine) Start(ctx context.Context) error {
	// Initial load: must succeed or return an error.
	if err := e.loadRulesInitial(); err != nil {
		return fmt.Errorf("failed to load initial rules from %s: %w", e.rulesPath, err)
	}

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("failed to initialize fsnotify watcher: %w", err)
	}
	e.watcher = watcher

	// Watch the parent directory of the rules file to reliably catch
	// modifications, atomic renames, and re-creations.
	watchDir := filepath.Dir(e.absRulesPath)
	if err := watcher.Add(watchDir); err != nil {
		_ = watcher.Close()
		return fmt.Errorf("failed to watch directory %s: %w", watchDir, err)
	}

	e.done = make(chan struct{})
	e.wg.Add(1)
	go e.watchLoop(ctx)

	return nil
}

// Stop closes the file watcher and cleans up all background goroutines.
func (e *Engine) Stop() {
	e.stopOnce.Do(func() {
		if e.done != nil {
			close(e.done)
		}
		if e.watcher != nil {
			_ = e.watcher.Close()
		}
		e.wg.Wait()
	})
}

// Match evaluates all loaded rules against the provided HTTP request.
// It is goroutine-safe and returns all matching rules as a non-nil slice.
func (e *Engine) Match(req *http.Request) []types.Rule {
	if req == nil {
		return []types.Rule{}
	}

	e.mu.RLock()
	defer e.mu.RUnlock()

	matched := make([]types.Rule, 0, len(e.compiledRules))
	reqPath := ""
	if req.URL != nil {
		reqPath = req.URL.Path
	}

	for _, cr := range e.compiledRules {
		if matchRule(cr, req, reqPath) {
			matched = append(matched, cr.rule)
		}
	}

	return matched
}

// matchRule checks if a single compiledRule satisfies all matching conditions for the request.
func matchRule(cr compiledRule, req *http.Request, reqPath string) bool {
	// 1. Method match (case-insensitive, empty matches any)
	if cr.rule.Match.Method != "" {
		if !strings.EqualFold(cr.rule.Match.Method, req.Method) {
			return false
		}
	}

	// 2. Path regex match (anchored full match, empty matches any)
	if cr.pathPattern != nil {
		if !cr.pathPattern.MatchString(reqPath) {
			return false
		}
	}

	// 3. Headers match (case-insensitive keys, exact value match, all required)
	if !matchHeaders(cr.rule.Match.Headers, req.Header) {
		return false
	}

	return true
}

// matchHeaders verifies that all key-value pairs in ruleHeaders exist in reqHeaders.
func matchHeaders(ruleHeaders map[string]string, reqHeaders http.Header) bool {
	if len(ruleHeaders) == 0 {
		return true
	}
	if len(reqHeaders) == 0 {
		return false
	}

	for rk, rv := range ruleHeaders {
		found := false
		for hk, hvals := range reqHeaders {
			if strings.EqualFold(hk, rk) {
				for _, hv := range hvals {
					if hv == rv {
						found = true
						break
					}
				}
				if found {
					break
				}
			}
		}
		if !found {
			return false
		}
	}

	return true
}

// loadRulesInitial performs the initial load and regex compilation.
func (e *Engine) loadRulesInitial() error {
	data, err := os.ReadFile(e.absRulesPath)
	if err != nil {
		return err
	}

	var rf rulesFile
	if err := yaml.Unmarshal(data, &rf); err != nil {
		return err
	}

	compiled, valid := e.compileRules(rf.Rules)

	e.mu.Lock()
	e.compiledRules = compiled
	e.rules = valid
	e.mu.Unlock()

	e.logger.Info("Rules loaded", slog.Int("count", len(valid)))
	return nil
}

// compileRules compiles regex patterns for a slice of rules.
// Broken regex patterns are skipped and logged as warnings.
func (e *Engine) compileRules(rawRules []types.Rule) ([]compiledRule, []types.Rule) {
	compiled := make([]compiledRule, 0, len(rawRules))
	valid := make([]types.Rule, 0, len(rawRules))

	for _, rule := range rawRules {
		var re *regexp.Regexp
		if rule.Match.PathRegex != "" {
			var err error
			re, err = regexp.Compile("^(?:" + rule.Match.PathRegex + ")$")
			if err != nil {
				e.logger.Warn("Rule skipped: invalid regex",
					slog.String("rule", rule.Name),
					slog.String("pattern", rule.Match.PathRegex),
					slog.Any("error", err),
				)
				continue
			}
		}

		compiled = append(compiled, compiledRule{
			rule:        rule,
			pathPattern: re,
		})
		valid = append(valid, rule)
	}

	return compiled, valid
}

// watchLoop listens for fsnotify file system events and triggers hot reload.
func (e *Engine) watchLoop(ctx context.Context) {
	defer e.wg.Done()

	var (
		debounceTimer *time.Timer
		timerCh       <-chan time.Time
	)

	for {
		select {
		case <-ctx.Done():
			if debounceTimer != nil {
				debounceTimer.Stop()
			}
			return
		case <-e.done:
			if debounceTimer != nil {
				debounceTimer.Stop()
			}
			return
		case event, ok := <-e.watcher.Events:
			if !ok {
				if debounceTimer != nil {
					debounceTimer.Stop()
				}
				return
			}

			eventAbs, err := filepath.Abs(event.Name)
			if err != nil {
				eventAbs = filepath.Clean(event.Name)
			}

			if eventAbs == e.absRulesPath || filepath.Clean(event.Name) == filepath.Clean(e.rulesPath) {
				if event.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Rename) != 0 {
					if debounceTimer != nil {
						debounceTimer.Stop()
					}
					debounceTimer = time.NewTimer(30 * time.Millisecond)
					timerCh = debounceTimer.C
				}
			}
		case <-timerCh:
			timerCh = nil
			debounceTimer = nil
			e.reload()
		case err, ok := <-e.watcher.Errors:
			if !ok {
				if debounceTimer != nil {
					debounceTimer.Stop()
				}
				return
			}
			e.logger.Error("Watcher error", slog.Any("error", err))
		}
	}
}

// reload re-parses and re-compiles the rules file, atomically swapping the ruleset on success.
func (e *Engine) reload() {
	data, err := os.ReadFile(e.absRulesPath)
	if err != nil {
		e.logger.Warn("Hot-reload: file not found or unreadable", slog.Any("error", err))
		return
	}

	if len(bytes.TrimSpace(data)) == 0 {
		time.Sleep(15 * time.Millisecond)
		data, err = os.ReadFile(e.absRulesPath)
		if err != nil || len(bytes.TrimSpace(data)) == 0 {
			e.logger.Warn("Hot-reload: file is empty or unreadable")
			return
		}
	}

	var rf rulesFile
	if err := yaml.Unmarshal(data, &rf); err != nil {
		e.logger.Error("Hot-reload failed", slog.Any("error", err))
		return
	}

	compiled, valid := e.compileRules(rf.Rules)

	e.mu.Lock()
	e.compiledRules = compiled
	e.rules = valid
	e.mu.Unlock()

	e.logger.Info("Rules reloaded", slog.Int("count", len(valid)))
}
