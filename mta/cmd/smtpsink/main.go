// Command smtpsink is a test SMTP server that accepts all mail and logs it.
//
// Usage:
//
//	smtpsink                    # Listen on :4587
//	smtpsink -addr :2525        # Listen on custom port
package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"

	gosmtp "github.com/emersion/go-smtp"
)

var messageCount atomic.Int64

func main() {
	addr := flag.String("addr", ":4587", "Listen address")
	flag.Parse()

	backend := &logBackend{}
	server := gosmtp.NewServer(backend)
	server.Domain = "sink.local"
	server.AllowInsecureAuth = true

	listener, err := net.Listen("tcp", *addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen %s: %v\n", *addr, err)
		os.Exit(1)
	}

	fmt.Printf("SMTP sink listening on %s (accepts all mail, delivers nowhere)\n", listener.Addr())

	go func() {
		if err := server.Serve(listener); err != nil {
			fmt.Fprintf(os.Stderr, "server error: %v\n", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	fmt.Printf("\nReceived %d messages total\n", messageCount.Load())
	server.Close()
}

type logBackend struct{}

func (b *logBackend) NewSession(conn *gosmtp.Conn) (gosmtp.Session, error) {
	return &logSession{}, nil
}

type logSession struct {
	from string
	to   []string
}

func (s *logSession) Mail(from string, opts *gosmtp.MailOptions) error {
	s.from = from
	return nil
}

func (s *logSession) Rcpt(to string, opts *gosmtp.RcptOptions) error {
	s.to = append(s.to, to)
	return nil
}

func (s *logSession) Data(r io.Reader) error {
	data, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	n := messageCount.Add(1)
	fmt.Printf("[%d] from=<%s> to=%v size=%d bytes\n", n, s.from, s.to, len(data))
	return nil
}

func (s *logSession) Reset() {
	s.from = ""
	s.to = nil
}

func (s *logSession) Logout() error {
	return nil
}
