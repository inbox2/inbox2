package requiretls

import (
	"testing"
)

func TestCheckServerSupport(t *testing.T) {
	tests := []struct {
		name   string
		ehlo   string
		expect bool
	}{
		{
			name:   "server supports REQUIRETLS",
			ehlo:   "250-STARTTLS\n250-AUTH LOGIN\nREQUIRETLS\n250 HELP",
			expect: true,
		},
		{
			name:   "server does not support REQUIRETLS",
			ehlo:   "250-STARTTLS\n250-AUTH LOGIN\n250 HELP",
			expect: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := CheckServerSupport(tt.ehlo)
			if got != tt.expect {
				t.Errorf("CheckServerSupport() = %v, want %v", got, tt.expect)
			}
		})
	}
}

func TestParseHeader(t *testing.T) {
	tests := []struct {
		name    string
		headers map[string]string
		want    bool
	}{
		{
			name:    "TLS-Required: Yes",
			headers: map[string]string{HeaderField: "Yes"},
			want:    true,
		},
		{
			name:    "TLS-Required: No",
			headers: map[string]string{HeaderField: "No"},
			want:    false,
		},
		{
			name:    "no header",
			headers: map[string]string{},
			want:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			policy := ParseHeader(tt.headers)
			if policy.Required != tt.want {
				t.Errorf("ParseHeader().Required = %v, want %v", policy.Required, tt.want)
			}
		})
	}
}

func TestEnforceOrReject(t *testing.T) {
	tests := []struct {
		name        string
		policy      Policy
		tlsEst      bool
		tlsValid    bool
		wantDeliver bool
		wantErr     bool
	}{
		{
			name:        "not required, no TLS",
			policy:      Policy{Required: false},
			tlsEst:      false,
			wantDeliver: true,
		},
		{
			name:        "required, TLS valid",
			policy:      Policy{Required: true},
			tlsEst:      true,
			tlsValid:    true,
			wantDeliver: true,
		},
		{
			name:        "required, no TLS",
			policy:      Policy{Required: true},
			tlsEst:      false,
			wantDeliver: false,
			wantErr:     true,
		},
		{
			name:        "required, TLS invalid cert",
			policy:      Policy{Required: true},
			tlsEst:      true,
			tlsValid:    false,
			wantDeliver: false,
			wantErr:     true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			deliver, err := EnforceOrReject(tt.policy, tt.tlsEst, tt.tlsValid)
			if deliver != tt.wantDeliver {
				t.Errorf("deliver = %v, want %v", deliver, tt.wantDeliver)
			}
			if tt.wantErr && err == nil {
				t.Error("expected error, got nil")
			}
			if !tt.wantErr && err != nil {
				t.Errorf("unexpected error: %v", err)
			}
		})
	}
}
