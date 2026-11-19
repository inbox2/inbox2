package mailclient

import (
	"errors"
	"io"
	"log/slog"
	"time"

	"github.com/emersion/go-sasl"
	gosmtp "github.com/emersion/go-smtp"
)

// NewSubmissionServer builds the SMTP submission server. The caller owns the
// listener (implicit TLS in production). insecureAuth lets a client sign in
// without TLS and is for tests only.
func NewSubmissionServer(b *Backend, log *slog.Logger, domain string, insecureAuth bool) *gosmtp.Server {
	s := gosmtp.NewServer(&submissionBackend{b: b, log: log})
	s.Domain = domain
	s.MaxRecipients = 100
	s.MaxMessageBytes = 30 << 20
	s.ReadTimeout = 60 * time.Second
	s.WriteTimeout = 5 * time.Minute // DATA waits on the backend
	s.AllowInsecureAuth = insecureAuth
	return s
}

type submissionBackend struct {
	b   *Backend
	log *slog.Logger
}

func (b *submissionBackend) NewSession(c *gosmtp.Conn) (gosmtp.Session, error) {
	log := b.log.With("remote", c.Conn().RemoteAddr().String())
	log.Info("submission.connect")
	return &submitSession{b: b.b, log: log}, nil
}

type submitSession struct {
	b      *Backend
	log    *slog.Logger
	creds  Creds
	authed bool
	from   string
	to     []string
}

func smtpErr(code int, enhanced gosmtp.EnhancedCode, msg string) error {
	return &gosmtp.SMTPError{Code: code, EnhancedCode: enhanced, Message: msg}
}

func (s *submitSession) AuthMechanisms() []string { return []string{sasl.Plain, sasl.Login} }

func (s *submitSession) Auth(mech string) (sasl.Server, error) {
	if mech == sasl.Login {
		return &loginServer{auth: s.login}, nil
	}
	return sasl.NewPlainServer(func(_, username, password string) error {
		return s.login(username, password)
	}), nil
}

func (s *submitSession) login(username, password string) error {
	c := Creds{Login: username, Password: password}
	if _, err := s.b.Session(c); err != nil {
		s.log.Warn("submission.login_failed", "login", username, "error", err.Error())
		var refused *RefusedError
		switch {
		case errors.Is(err, ErrAuth):
			return smtpErr(535, gosmtp.EnhancedCode{5, 7, 8}, "Authentication failed")
		case errors.As(err, &refused):
			return smtpErr(535, gosmtp.EnhancedCode{5, 7, 8}, refused.Message)
		}
		return smtpErr(454, gosmtp.EnhancedCode{4, 7, 0}, "Temporary authentication failure")
	}
	s.creds, s.authed = c, true
	s.log.Info("submission.login", "login", username)
	return nil
}

func (s *submitSession) Mail(from string, _ *gosmtp.MailOptions) error {
	if !s.authed {
		return smtpErr(530, gosmtp.EnhancedCode{5, 7, 0}, "Authentication required")
	}
	s.from = from
	return nil
}

func (s *submitSession) Rcpt(to string, _ *gosmtp.RcptOptions) error {
	s.to = append(s.to, to)
	return nil
}

func (s *submitSession) Data(r io.Reader) error {
	raw, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	id, err := s.b.Submit(s.creds, s.from, s.to, raw)
	if err == nil {
		s.log.Info("submission.accepted", "login", s.creds.Login, "mail_from", s.from, "rcpts", len(s.to), "bytes", len(raw), "id", id)
		return nil
	}
	s.log.Warn("submission.refused", "login", s.creds.Login, "mail_from", s.from, "rcpts", len(s.to), "error", err.Error())
	var refused *RefusedError
	var status *StatusError
	switch {
	case errors.Is(err, ErrAuth): // the app password was revoked mid-session
		return smtpErr(535, gosmtp.EnhancedCode{5, 7, 8}, "Authentication failed")
	case errors.As(err, &refused):
		return smtpErr(550, gosmtp.EnhancedCode{5, 7, 1}, refused.Message)
	case errors.As(err, &status) && status.Status == 422:
		return smtpErr(554, gosmtp.EnhancedCode{5, 6, 0}, status.Message)
	}
	return smtpErr(451, gosmtp.EnhancedCode{4, 3, 0}, "Temporary server error, try again later")
}

func (s *submitSession) Reset()        { s.from, s.to = "", nil }
func (s *submitSession) Logout() error { return nil }

// loginServer is AUTH LOGIN (Outlook's default). go-sasl ships only the
// client half.
type loginServer struct {
	auth     func(username, password string) error
	username *string
}

func (l *loginServer) Next(response []byte) ([]byte, bool, error) {
	switch {
	case l.username == nil && response == nil:
		return []byte("Username:"), false, nil
	case l.username == nil:
		u := string(response)
		l.username = &u
		return []byte("Password:"), false, nil
	}
	return nil, true, l.auth(*l.username, string(response))
}
