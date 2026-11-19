package outbound

import (
	"testing"
	"time"
)

func TestWarmupBudget(t *testing.T) {
	start := time.Now().UTC().Truncate(24 * time.Hour)
	th := NewThrottle(0, 0, time.Minute, start)

	// Day 0 cap is warmupSchedule[0].
	for i := 0; i < warmupSchedule[0]; i++ {
		if !th.WarmupBudgetLeft(time.Now()) {
			t.Fatalf("budget exhausted early at %d", i)
		}
		th.CountSend(time.Now())
	}
	if th.WarmupBudgetLeft(time.Now()) {
		t.Fatal("budget should be exhausted at the day-0 cap")
	}

	// Past the schedule the cap lifts.
	old := NewThrottle(0, 0, time.Minute, time.Now().AddDate(0, 0, -len(warmupSchedule)-1))
	if !old.WarmupBudgetLeft(time.Now()) {
		t.Fatal("warmed-up IP should have no cap")
	}

	// Disabled warmup never gates.
	off := NewThrottle(0, 0, time.Minute, time.Time{})
	if !off.WarmupBudgetLeft(time.Now()) {
		t.Fatal("disabled warmup should never gate")
	}
}

func TestDomainConcurrency(t *testing.T) {
	th := NewThrottle(2, 0, time.Minute, time.Time{})

	if !th.AcquireDomain("gmail.com", time.Millisecond) || !th.AcquireDomain("gmail.com", time.Millisecond) {
		t.Fatal("slots below the cap should acquire")
	}
	if th.AcquireDomain("gmail.com", 10*time.Millisecond) {
		t.Fatal("third concurrent slot should time out")
	}
	// Other domains are independent.
	if !th.AcquireDomain("outlook.com", time.Millisecond) {
		t.Fatal("other domain should acquire")
	}
	// Release frees a blocked waiter.
	done := make(chan bool, 1)
	go func() { done <- th.AcquireDomain("gmail.com", 2*time.Second) }()
	th.ReleaseDomain("gmail.com")
	if !<-done {
		t.Fatal("waiter should acquire after release")
	}
}

func TestDomainRateWindow(t *testing.T) {
	th := NewThrottle(0, 2, time.Hour, time.Time{})

	if !th.AcquireDomain("gmail.com", time.Millisecond) {
		t.Fatal("first send should pass")
	}
	th.ReleaseDomain("gmail.com")
	if !th.AcquireDomain("gmail.com", time.Millisecond) {
		t.Fatal("second send should pass")
	}
	th.ReleaseDomain("gmail.com")
	if th.AcquireDomain("gmail.com", 10*time.Millisecond) {
		t.Fatal("third send in the window should time out")
	}
}

func TestThrottledResult(t *testing.T) {
	msg := &OutboundMessage{MessageKey: "msg_1", DeliveryStatusKey: "ds_1"}
	r := ThrottledResult(msg)
	if r.Result != "transient_failure" || r.DeliveryStatusKey != "ds_1" {
		t.Fatalf("unexpected result: %+v", r)
	}
}
