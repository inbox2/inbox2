package dane

import (
	"testing"
)

func TestParseTLSA(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantErr  bool
		usage    uint8
		selector uint8
		matching uint8
	}{
		{
			name:     "valid DANE-EE SHA-256",
			input:    "3 1 1 abcdef0123456789",
			usage:    UsageDomainIssued,
			selector: 1,
			matching: 1,
		},
		{
			name:     "valid CA constraint",
			input:    "0 0 1 deadbeef",
			usage:    UsageCAConstraint,
			selector: 0,
			matching: 1,
		},
		{
			name:    "invalid format",
			input:   "invalid",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec, err := parseTLSA(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Error("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if rec.Usage != tt.usage {
				t.Errorf("usage = %d, want %d", rec.Usage, tt.usage)
			}
			if rec.Selector != tt.selector {
				t.Errorf("selector = %d, want %d", rec.Selector, tt.selector)
			}
			if rec.MatchingType != tt.matching {
				t.Errorf("matching = %d, want %d", rec.MatchingType, tt.matching)
			}
		})
	}
}

func TestMatchTLSANoRecords(t *testing.T) {
	result := VerifyCertificate(nil, nil)
	if !result.Verified {
		t.Error("expected Verified=true when no TLSA records (DANE not configured)")
	}
}
