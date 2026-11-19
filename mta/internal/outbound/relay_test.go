package outbound_test

import (
	"io"
	"net"
	"net/smtp"
	"net/textproto"
	"strings"
	"testing"
	"time"

	"github.com/inbox2/mta/internal/outbound"
)

// A warm-up that started long ago: the IP is warmed and the relay has no caps.
var warmed = time.Now().AddDate(0, -3, 0)

// relayFixture: relay -> sender -> sink, all on loopback.
func relayFixture(t *testing.T, warmupStart time.Time) (addr string, sink *outbound.Sink) {
	t.Helper()
	sink, err := outbound.NewSink()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(sink.Close)
	logger := outbound.NewLoggerFromWriter(io.Discard)
	sender := outbound.NewSender("test.local", logger)
	sender.SetResolver(&staticResolver{host: "127.0.0.1"})
	sender.SetPort(sinkPort(t, sink))

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := outbound.NewRelayServer("relay.test", "pushleft", "s3cret", sender,
		outbound.NewThrottle(4, 0, time.Minute, warmupStart), logger)
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return ln.Addr().String(), sink
}

func relaySend(addr, password, from, to, body string) error {
	c, err := smtp.Dial(addr)
	if err != nil {
		return err
	}
	defer c.Close()
	if password != "" {
		// PlainAuth refuses non-TLS unless the host is localhost.
		if err := c.Auth(smtp.PlainAuth("", "pushleft", password, "127.0.0.1")); err != nil {
			return err
		}
	}
	if err := c.Mail(from); err != nil {
		return err
	}
	if err := c.Rcpt(to); err != nil {
		return err
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write([]byte(body)); err != nil {
		return err
	}
	return w.Close()
}

func smtpCode(err error) int {
	if e, ok := err.(*textproto.Error); ok {
		return e.Code
	}
	return 0
}

func TestRelay_PassesMessageThroughUnchanged(t *testing.T) {
	addr, sink := relayFixture(t, warmed)
	body := "DKIM-Signature: v=1; d=acme.com; s=pl; b=abc\r\nFrom: a@acme.com\r\nSubject: hi\r\n\r\nbody\r\n"
	from := "b+123@pl-bounces.acme.com"

	if err := relaySend(addr, "s3cret", from, "rcpt@example.com", body); err != nil {
		t.Fatalf("relay send: %v", err)
	}
	msgs := sink.Messages()
	if len(msgs) != 1 {
		t.Fatalf("sink got %d messages, want 1", len(msgs))
	}
	if string(msgs[0].Data) != body {
		t.Errorf("message changed in transit:\n got %q\nwant %q", msgs[0].Data, body)
	}
	if msgs[0].From != from {
		t.Errorf("envelope sender = %q, want %q", msgs[0].From, from)
	}
}

func TestRelay_RequiresAuth(t *testing.T) {
	addr, sink := relayFixture(t, warmed)
	if code := smtpCode(relaySend(addr, "", "a@acme.com", "rcpt@example.com", "x\r\n")); code != 530 {
		t.Errorf("no auth: code %d, want 530", code)
	}
	err := relaySend(addr, "wrong", "a@acme.com", "rcpt@example.com", "x\r\n")
	if smtpCode(err) != 535 || strings.Contains(err.Error(), "[remote") {
		t.Errorf("bad password: got %v, want an unmarked 535", err)
	}
	if sink.MessageCount() != 0 {
		t.Error("unauthenticated mail was relayed")
	}
}

func TestRelay_RemoteRejectComesBackAsIs(t *testing.T) {
	// A "remote MX" that rejects every recipient.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				tp := textproto.NewConn(conn)
				tp.PrintfLine("220 mx.test")
				for {
					line, err := tp.ReadLine()
					if err != nil {
						return
					}
					switch {
					case strings.HasPrefix(line, "RCPT"):
						tp.PrintfLine("550 5.1.1 no such user here")
					case strings.HasPrefix(line, "QUIT"):
						tp.PrintfLine("221 bye")
						return
					default:
						tp.PrintfLine("250 ok")
					}
				}
			}()
		}
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())

	logger := outbound.NewLoggerFromWriter(io.Discard)
	sender := outbound.NewSender("test.local", logger)
	sender.SetResolver(&staticResolver{host: "127.0.0.1"})
	sender.SetPort(port)
	rl, _ := net.Listen("tcp", "127.0.0.1:0")
	srv := outbound.NewRelayServer("relay.test", "pushleft", "s3cret", sender,
		outbound.NewThrottle(4, 0, time.Minute, warmed), logger)
	go srv.Serve(rl)
	defer srv.Close()

	err = relaySend(rl.Addr().String(), "s3cret", "a@pl-bounces.acme.com", "gone@example.com", "x\r\n")
	if smtpCode(err) != 550 || !strings.HasSuffix(err.Error(), "5.1.1 no such user here [remote 127.0.0.1]") {
		t.Errorf("got %v, want the remote's 550 5.1.1 no such user here, marked [remote 127.0.0.1]", err)
	}
}

func TestRelay_PerCustomerCapDuringWarmup(t *testing.T) {
	// Day 0 budget is 50, so one customer gets 12.
	addr, sink := relayFixture(t, time.Now().UTC().Truncate(24*time.Hour))
	for i := 0; i < 12; i++ {
		if err := relaySend(addr, "s3cret", "a@pl-bounces.acme.com", "rcpt@example.com", "x\r\n"); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
	}
	if code := smtpCode(relaySend(addr, "s3cret", "a@pl-bounces.acme.com", "rcpt@example.com", "x\r\n")); code != 451 {
		t.Errorf("over the customer cap: code %d, want 451", code)
	}
	if err := relaySend(addr, "s3cret", "a@pl-bounces.other.com", "rcpt@example.com", "x\r\n"); err != nil {
		t.Errorf("another customer should still send: %v", err)
	}
	if sink.MessageCount() != 13 {
		t.Errorf("sink got %d, want 13", sink.MessageCount())
	}
}

// A remote that takes the message and then never answers must not hold the
// sender past its deadline.
func TestSender_DeadlineBoundsASilentRemote(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		tp := textproto.NewConn(conn)
		tp.PrintfLine("220 mx.test")
		for {
			line, err := tp.ReadLine()
			if err != nil {
				return
			}
			if strings.HasPrefix(line, "DATA") {
				tp.PrintfLine("354 go ahead")
				io.Copy(io.Discard, conn) // swallow the message, say nothing
				return
			}
			tp.PrintfLine("250 ok")
		}
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	sender := outbound.NewSender("test.local", outbound.NewLoggerFromWriter(io.Discard))
	sender.SetResolver(&staticResolver{host: "127.0.0.1"})
	sender.SetPort(port)

	start := time.Now()
	result := sender.Send(&outbound.OutboundMessage{
		Envelope:   outbound.OutboundEnvelope{MailFrom: "a@acme.com", RcptTo: []string{"r@example.com"}},
		RFC5322B64: "eA0K",
		Deadline:   time.Now().Add(300 * time.Millisecond),
	})
	if result.Result != "transient_failure" {
		t.Errorf("result = %q, want transient_failure", result.Result)
	}
	if took := time.Since(start); took > 3*time.Second {
		t.Errorf("Send took %v with a 300ms deadline", took)
	}
}

func TestRelay_ClosedWithoutAWarmupStart(t *testing.T) {
	addr, sink := relayFixture(t, time.Time{})
	if code := smtpCode(relaySend(addr, "s3cret", "a@pl-bounces.acme.com", "rcpt@example.com", "x\r\n")); code != 451 {
		t.Errorf("no warm-up start: code %d, want 451", code)
	}
	if sink.MessageCount() != 0 {
		t.Error("mail was relayed with no warm-up start set")
	}
}
