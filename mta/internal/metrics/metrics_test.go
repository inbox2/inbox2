package metrics

import (
	"io"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCountersAndExposition(t *testing.T) {
	Describe("test_total", "test counter")
	Inc("test_total")
	Inc("test_total", "reason", "rbl")
	Inc("test_total", "reason", "rbl")
	Add("test_total", 5, "reason", "grey")
	Set("test_inflight", 3)

	srv := httptest.NewServer(Handler())
	defer srv.Close()
	resp, err := srv.Client().Get(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	out := string(body)

	for _, want := range []string{
		"# HELP test_total test counter",
		"# TYPE test_total counter",
		"test_total 1",
		`test_total{reason="rbl"} 2`,
		`test_total{reason="grey"} 5`,
		"# TYPE test_inflight gauge",
		"test_inflight 3",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("exposition missing %q\n---\n%s", want, out)
		}
	}
}
