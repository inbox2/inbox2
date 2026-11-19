// Command mxtest is a test harness for the MX inbound receiver (spec 17.2.3, 17.4.1).
//
// It injects email messages through TCP/SMTP to a running MX server, supporting:
//   - Single message injection from .eml files or inline
//   - Batch injection from the test corpus directory
//   - Concurrent load testing with configurable parallelism
//   - Throughput and latency measurement
//
// Usage:
//
//	# Inject a single .eml file
//	mxtest -addr localhost:4025 -file testdata/corpus/plain.eml -from sender@test.com -to support@acme.com
//
//	# Inject all corpus files
//	mxtest -addr localhost:4025 -corpus testdata/corpus/ -to support@acme.com
//
//	# Load test: 1000 messages, 50 concurrent connections
//	mxtest -addr localhost:4025 -load -count 1000 -concurrency 50 -to support@acme.com
//
//	# Quick smoke test
//	mxtest -addr localhost:4025 -smoke -to support@acme.com
package main

import (
	"flag"
	"fmt"
	"math"
	"net/smtp"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	addr := flag.String("addr", "localhost:4025", "MX server address")
	from := flag.String("from", "mxtest@example.com", "MAIL FROM address")
	to := flag.String("to", "support@acme.com", "RCPT TO address")
	file := flag.String("file", "", "Single .eml file to inject")
	corpus := flag.String("corpus", "", "Directory of .eml files to inject")
	load := flag.Bool("load", false, "Run load test")
	smoke := flag.Bool("smoke", false, "Quick smoke test (inline message)")
	count := flag.Int("count", 100, "Number of messages for load test")
	concurrency := flag.Int("concurrency", 10, "Concurrent connections for load test")
	flag.Parse()

	switch {
	case *smoke:
		runSmoke(*addr, *from, *to)
	case *file != "":
		runFile(*addr, *from, *to, *file)
	case *corpus != "":
		runCorpus(*addr, *from, *to, *corpus)
	case *load:
		runLoad(*addr, *from, *to, *count, *concurrency)
	default:
		fmt.Println("Usage: mxtest -addr host:port [-smoke | -file path.eml | -corpus dir/ | -load]")
		flag.PrintDefaults()
		os.Exit(1)
	}
}

func runSmoke(addr, from, to string) {
	fmt.Printf("Smoke test → %s\n", addr)

	msg := fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nSubject: MX Smoke Test\r\nMessage-ID: <smoke-%d@mxtest>\r\nDate: %s\r\n\r\nSmoke test message from mxtest harness.\r\n",
		from, to, time.Now().UnixNano(), time.Now().Format(time.RFC1123Z),
	)

	start := time.Now()
	err := smtp.SendMail(addr, nil, from, []string{to}, []byte(msg))
	elapsed := time.Since(start)

	if err != nil {
		fmt.Printf("FAIL: %v (%.1fms)\n", err, float64(elapsed.Microseconds())/1000)
		os.Exit(1)
	}
	fmt.Printf("OK: delivered in %.1fms\n", float64(elapsed.Microseconds())/1000)
}

func runFile(addr, from, to, path string) {
	fmt.Printf("Injecting %s → %s\n", path, addr)

	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Printf("FAIL: read %s: %v\n", path, err)
		os.Exit(1)
	}

	start := time.Now()
	err = smtp.SendMail(addr, nil, from, []string{to}, data)
	elapsed := time.Since(start)

	if err != nil {
		fmt.Printf("FAIL: %v (%.1fms)\n", err, float64(elapsed.Microseconds())/1000)
		os.Exit(1)
	}
	fmt.Printf("OK: %s delivered in %.1fms (%d bytes)\n", filepath.Base(path), float64(elapsed.Microseconds())/1000, len(data))
}

func runCorpus(addr, from, to, dir string) {
	files, err := filepath.Glob(filepath.Join(dir, "*.eml"))
	if err != nil {
		fmt.Printf("FAIL: glob %s: %v\n", dir, err)
		os.Exit(1)
	}
	if len(files) == 0 {
		fmt.Printf("FAIL: no .eml files found in %s\n", dir)
		os.Exit(1)
	}

	fmt.Printf("Injecting %d corpus files → %s\n", len(files), addr)

	var passed, failed int
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			fmt.Printf("  SKIP: %s: %v\n", filepath.Base(f), err)
			failed++
			continue
		}

		start := time.Now()
		err = smtp.SendMail(addr, nil, from, []string{to}, data)
		elapsed := time.Since(start)

		if err != nil {
			fmt.Printf("  FAIL: %s: %v (%.1fms)\n", filepath.Base(f), err, float64(elapsed.Microseconds())/1000)
			failed++
		} else {
			fmt.Printf("  OK:   %s (%.1fms, %d bytes)\n", filepath.Base(f), float64(elapsed.Microseconds())/1000, len(data))
			passed++
		}
	}
	fmt.Printf("\nResults: %d/%d passed\n", passed, passed+failed)
	if failed > 0 {
		os.Exit(1)
	}
}

func runLoad(addr, from, to string, count, concurrency int) {
	fmt.Printf("Load test: %d messages, %d concurrent → %s\n", count, concurrency, addr)

	latencies := make([]time.Duration, count)
	var succeeded, failed atomic.Int64
	var wg sync.WaitGroup

	work := make(chan int, count)
	for i := 0; i < count; i++ {
		work <- i
	}
	close(work)

	start := time.Now()

	for c := 0; c < concurrency; c++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for id := range work {
				msg := fmt.Sprintf(
					"From: load%d@example.com\r\nTo: %s\r\nSubject: Load test %d\r\nMessage-ID: <load-%d-%d@mxtest>\r\n\r\nLoad test body %d\r\n",
					id, to, id, id, time.Now().UnixNano(), id,
				)

				t := time.Now()
				err := smtp.SendMail(addr, nil, fmt.Sprintf("load%d@example.com", id), []string{to}, []byte(msg))
				latencies[id] = time.Since(t)

				if err != nil {
					failed.Add(1)
				} else {
					succeeded.Add(1)
				}
			}
		}()
	}

	wg.Wait()
	totalElapsed := time.Since(start)

	// Compute stats
	s := succeeded.Load()
	f := failed.Load()
	throughput := float64(s) / totalElapsed.Seconds()

	// Latency percentiles (only for successful messages)
	var successLatencies []time.Duration
	for i := 0; i < count; i++ {
		if latencies[i] > 0 {
			successLatencies = append(successLatencies, latencies[i])
		}
	}
	sort.Slice(successLatencies, func(i, j int) bool { return successLatencies[i] < successLatencies[j] })

	fmt.Printf("\n══════════════════════════════════════\n")
	fmt.Printf("  Results\n")
	fmt.Printf("══════════════════════════════════════\n")
	fmt.Printf("  Total:        %d messages\n", count)
	fmt.Printf("  Succeeded:    %d\n", s)
	fmt.Printf("  Failed:       %d\n", f)
	fmt.Printf("  Duration:     %s\n", totalElapsed.Round(time.Millisecond))
	fmt.Printf("  Throughput:   %.1f msg/sec\n", throughput)

	if len(successLatencies) > 0 {
		fmt.Printf("\n  Latency:\n")
		fmt.Printf("    Min:        %s\n", successLatencies[0].Round(100*time.Microsecond))
		fmt.Printf("    Median:     %s\n", percentile(successLatencies, 50).Round(100*time.Microsecond))
		fmt.Printf("    P95:        %s\n", percentile(successLatencies, 95).Round(100*time.Microsecond))
		fmt.Printf("    P99:        %s\n", percentile(successLatencies, 99).Round(100*time.Microsecond))
		fmt.Printf("    Max:        %s\n", successLatencies[len(successLatencies)-1].Round(100*time.Microsecond))
		fmt.Printf("    Mean:       %s\n", mean(successLatencies).Round(100*time.Microsecond))
	}
	fmt.Printf("══════════════════════════════════════\n")

	if f > 0 {
		os.Exit(1)
	}
}

func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil(p/100*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func mean(durations []time.Duration) time.Duration {
	if len(durations) == 0 {
		return 0
	}
	var total time.Duration
	for _, d := range durations {
		total += d
	}
	return total / time.Duration(len(durations))
}
