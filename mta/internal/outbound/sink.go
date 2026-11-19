package outbound

import (
	"io"
	"net"
	"sync"

	gosmtp "github.com/emersion/go-smtp"
)

// SinkMessage holds a message received by the SMTP sink.
type SinkMessage struct {
	From string
	To   []string
	Data []byte
}

// Sink is a minimal SMTP server that accepts all mail and stores it in memory.
// Used for testing the outbound sender without delivering to real MTAs.
type Sink struct {
	server   *gosmtp.Server
	listener net.Listener
	mu       sync.Mutex
	messages []SinkMessage
}

// NewSink creates and starts an SMTP sink on a random port.
func NewSink() (*Sink, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}

	s := &Sink{listener: listener}
	backend := &sinkBackend{sink: s}
	s.server = gosmtp.NewServer(backend)
	s.server.Domain = "sink.test"
	s.server.AllowInsecureAuth = true

	go s.server.Serve(listener)
	return s, nil
}

// Addr returns the listener address (host:port).
func (s *Sink) Addr() string {
	return s.listener.Addr().String()
}

// Messages returns all received messages.
func (s *Sink) Messages() []SinkMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]SinkMessage, len(s.messages))
	copy(out, s.messages)
	return out
}

// MessageCount returns the number of received messages.
func (s *Sink) MessageCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.messages)
}

// Close stops the sink server.
func (s *Sink) Close() {
	s.server.Close()
}

func (s *Sink) addMessage(msg SinkMessage) {
	s.mu.Lock()
	s.messages = append(s.messages, msg)
	s.mu.Unlock()
}

// sinkBackend implements smtp.Backend for the sink.
type sinkBackend struct {
	sink *Sink
}

func (b *sinkBackend) NewSession(conn *gosmtp.Conn) (gosmtp.Session, error) {
	return &sinkSession{sink: b.sink}, nil
}

// sinkSession implements smtp.Session, accepting all mail.
type sinkSession struct {
	sink *Sink
	from string
	to   []string
}

func (s *sinkSession) Mail(from string, opts *gosmtp.MailOptions) error {
	s.from = from
	return nil
}

func (s *sinkSession) Rcpt(to string, opts *gosmtp.RcptOptions) error {
	s.to = append(s.to, to)
	return nil
}

func (s *sinkSession) Data(r io.Reader) error {
	data, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	s.sink.addMessage(SinkMessage{
		From: s.from,
		To:   s.to,
		Data: data,
	})
	return nil
}

func (s *sinkSession) Reset() {
	s.from = ""
	s.to = nil
}

func (s *sinkSession) Logout() error {
	return nil
}
