// Package outbound implements the SMTP outbound sender for delivering mail.
package outbound

import "time"

const (
	OutboundStreamName    = "MAIL_OUTBOUND"
	OutboundSubjectPrefix = "mail.outbound."
	StatusStreamName      = "MAIL_DELIVERY_STATUS"
	StatusSubjectPrefix   = "mail.delivery.status."
	ConsumerName          = "SMTP_OUTBOUND_SENDER"
	StatusConsumerName    = "RAILS_DELIVERY_STATUS"
	// DefaultMaxMsgSize must hold the base64-encoded RFC5322 message (×4/3) plus
	// JSON/envelope overhead for a 100MB message, so a large outbound message is
	// always publishable.
	DefaultMaxMsgSize     = 160 * 1024 * 1024
	DefaultStreamMaxAge   = 72 * time.Hour
	DefaultStreamMaxBytes = 10 * 1024 * 1024 * 1024 // 10GB
	DefaultWorkers        = 10
)

// OutboundMessage is the NATS payload published by Rails for the Go sender to deliver.
type OutboundMessage struct {
	Version           int              `json:"version"`
	DeliveryStatusID  int64            `json:"delivery_status_id"`
	DeliveryStatusKey string           `json:"delivery_status_key"`
	MessageKey        string           `json:"message_key"`
	Envelope          OutboundEnvelope `json:"envelope"`
	RFC5322B64        string           `json:"rfc5322_b64"`
	SealedMIME        *SealedMIME      `json:"sealed_mime,omitempty"`
	DKIM              DKIMConfig       `json:"dkim"`
	Channel           ChannelInfo      `json:"channel"`

	// Deadline, when set, bounds the whole Send: no connection outlives it and
	// no further MX host is tried after it. Set by the relay, never by Rails.
	Deadline time.Time `json:"-"`
}

// SealedMIME is the queued outbound MIME for an E2EE domain (docs/E2EE.md
// Phase I): Rails seals the composed RFC 5322 bytes to the MTA delivery key so
// the durable MAIL_OUTBOUND stream holds only ciphertext. The sender (which
// already holds DKIM private keys — a trusted key-holder by construction)
// decrypts in RAM at delivery time. AAD = the message key.
type SealedMIME struct {
	SealedDEK  string `json:"sealed_dek"`
	Nonce      string `json:"nonce"`
	Ciphertext string `json:"ciphertext"`
}

// OutboundEnvelope holds SMTP envelope addresses for outbound delivery.
type OutboundEnvelope struct {
	MailFrom string   `json:"mail_from"`
	RcptTo   []string `json:"rcpt_to"`
}

// DKIMConfig holds the DKIM signing parameters for the message.
type DKIMConfig struct {
	Domain        string `json:"domain"`
	Selector      string `json:"selector"`
	PrivateKeyPEM string `json:"private_key_pem"`
}

// ChannelInfo identifies which delivery channel to use.
type ChannelInfo struct {
	Kind              string `json:"kind"` // "builtin", "smtp_relay", "ses"
	DeliveryChannelID int64  `json:"delivery_channel_id"`
}

// DeliveryResult is published back to NATS after a delivery attempt.
type DeliveryResult struct {
	Version           int       `json:"version"`
	DeliveryStatusKey string    `json:"delivery_status_key"`
	MessageKey        string    `json:"message_key"`
	Result            string    `json:"result"` // "success", "transient_failure", "permanent_failure"
	SMTPCode          string    `json:"smtp_code"`
	EnhancedCode      string    `json:"enhanced_code"`
	ResponseMessage   string    `json:"response_message"`
	MXHost            string    `json:"mx_host"`
	TLSVersion        string    `json:"tls_version"`
	AttemptNumber     int       `json:"attempt_number"`
	DeliveredAt       time.Time `json:"delivered_at"`
}
