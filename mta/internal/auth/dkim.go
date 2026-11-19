package auth

import (
	"bytes"

	"github.com/emersion/go-msgauth/dkim"
)

// DKIMResult holds the outcome of a DKIM verification.
type DKIMResult struct {
	Result   string // "pass", "fail", "none", "temperror", "permerror"
	Domain   string
	Selector string
}

// VerifyDKIM checks DKIM signatures on the raw message bytes.
// Must be called before any other reader consumes the message body.
func VerifyDKIM(rawMessage []byte) DKIMResult {
	verifications, err := dkim.Verify(bytes.NewReader(rawMessage))
	if err != nil {
		return DKIMResult{Result: "temperror"}
	}

	if len(verifications) == 0 {
		return DKIMResult{Result: "none"}
	}

	// Check each verification — pass if any signature is valid
	for _, v := range verifications {
		if v.Err == nil {
			return DKIMResult{
				Result:   "pass",
				Domain:   v.Domain,
				Selector: v.Identifier,
			}
		}
	}

	// All signatures failed — return info from the first one
	v := verifications[0]
	return DKIMResult{
		Result:   "fail",
		Domain:   v.Domain,
		Selector: v.Identifier,
	}
}
