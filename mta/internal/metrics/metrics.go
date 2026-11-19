// Package metrics is a minimal Prometheus text-exposition registry for the MX
// and SMTP daemons (TODO 46.12).
//
// ponytail: counters + gauges only, hand-rolled (~100 lines) instead of
// prometheus/client_golang — upgrade to the real client when histograms or
// push gateways are needed. The exposition format for counters is plain text
// and stable (https://prometheus.io/docs/instrumenting/exposition_formats/).
package metrics

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
)

type registry struct {
	mu     sync.Mutex
	series map[string]*int64  // full series key (name + label set) → value
	help   map[string]string  // metric name → HELP line
	names  map[string][]string // metric name → series keys, for grouped output
}

var reg = &registry{
	series: make(map[string]*int64),
	help:   make(map[string]string),
	names:  make(map[string][]string),
}

// Describe registers a HELP string for a metric name (optional but polite).
func Describe(name, help string) {
	reg.mu.Lock()
	reg.help[name] = help
	reg.mu.Unlock()
}

// Inc adds 1 to a counter. Labels are alternating key, value pairs:
// Inc("mx_rejects_total", "reason", "rbl").
func Inc(name string, labels ...string) {
	Add(name, 1, labels...)
}

// Add adds delta to a counter/gauge series.
func Add(name string, delta int64, labels ...string) {
	atomic.AddInt64(counter(name, labels...), delta)
}

// Set overwrites a gauge series.
func Set(name string, value int64, labels ...string) {
	atomic.StoreInt64(counter(name, labels...), value)
}

func counter(name string, labels ...string) *int64 {
	key := seriesKey(name, labels...)
	reg.mu.Lock()
	defer reg.mu.Unlock()
	if c, ok := reg.series[key]; ok {
		return c
	}
	c := new(int64)
	reg.series[key] = c
	reg.names[name] = append(reg.names[name], key)
	return c
}

func seriesKey(name string, labels ...string) string {
	if len(labels) == 0 {
		return name
	}
	pairs := make([]string, 0, len(labels)/2)
	for i := 0; i+1 < len(labels); i += 2 {
		pairs = append(pairs, fmt.Sprintf("%s=%q", labels[i], labels[i+1]))
	}
	sort.Strings(pairs)
	return name + "{" + strings.Join(pairs, ",") + "}"
}

// Handler serves the registry in Prometheus text exposition format.
func Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		reg.mu.Lock()
		names := make([]string, 0, len(reg.names))
		for n := range reg.names {
			names = append(names, n)
		}
		sort.Strings(names)
		var b strings.Builder
		for _, n := range names {
			if h := reg.help[n]; h != "" {
				fmt.Fprintf(&b, "# HELP %s %s\n", n, h)
			}
			typ := "counter"
			if strings.HasSuffix(n, "_inflight") || strings.HasSuffix(n, "_gauge") {
				typ = "gauge"
			}
			fmt.Fprintf(&b, "# TYPE %s %s\n", n, typ)
			keys := append([]string(nil), reg.names[n]...)
			sort.Strings(keys)
			for _, k := range keys {
				fmt.Fprintf(&b, "%s %d\n", k, atomic.LoadInt64(reg.series[k]))
			}
		}
		reg.mu.Unlock()
		w.Write([]byte(b.String()))
	})
}

// Serve exposes /metrics on addr in a background goroutine. Empty addr = off.
// The error path is log-only via the callback (a broken metrics port must not
// take the mail path down).
func Serve(addr string, logErr func(error)) {
	if addr == "" {
		return
	}
	mux := http.NewServeMux()
	mux.Handle("/metrics", Handler())
	go func() {
		if err := http.ListenAndServe(addr, mux); err != nil && logErr != nil {
			logErr(err)
		}
	}()
}
