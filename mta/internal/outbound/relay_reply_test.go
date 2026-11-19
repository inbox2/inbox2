package outbound

import (
	"testing"

	gosmtp "github.com/emersion/go-smtp"
)

func TestRelayReply(t *testing.T) {
	cases := []struct {
		name string
		in   DeliveryResult
		code int
		msg  string
	}{
		{"remote 250 keeps its text", DeliveryResult{Result: "success", SMTPCode: "250", MXHost: "mx.example", ResponseMessage: "2.0.0 OK 123 gsmtp"},
			250, "2.0.0 OK 123 gsmtp [remote mx.example]"},
		{"remote 550", DeliveryResult{Result: "permanent_failure", SMTPCode: "550", MXHost: "mx.example", ResponseMessage: "550 5.1.1 no such user"},
			550, "5.1.1 no such user [remote mx.example]"},
		{"remote 421", DeliveryResult{Result: "transient_failure", SMTPCode: "421", MXHost: "mx.example", ResponseMessage: "421 4.7.0 try later"},
			421, "4.7.0 try later [remote mx.example]"},
		{"our own failure is an unmarked 451", DeliveryResult{Result: "transient_failure", MXHost: "mx.example", ResponseMessage: "connect: i/o timeout"},
			451, "not delivered: connect: i/o timeout"},
		{"no MX is an unmarked 451", DeliveryResult{Result: "transient_failure", ResponseMessage: "MX lookup: no such host"},
			451, "not delivered: MX lookup: no such host"},
	}
	for _, c := range cases {
		got, _ := relayReply(&c.in).(*gosmtp.SMTPError)
		if got == nil || got.Code != c.code || got.Message != c.msg {
			t.Errorf("%s: got %+v, want %d %q", c.name, got, c.code, c.msg)
		}
	}
}
