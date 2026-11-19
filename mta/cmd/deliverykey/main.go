// Command deliverykey generates the MTA delivery keypair (docs/E2EE.md
// Phase I). The PRIVATE key goes to the Go SMTP sender (it decrypts sealed
// outbound MIME in RAM at delivery time); the PUBLIC key goes to Rails (it
// seals composed MIME for E2EE domains before queuing). Run once per
// environment and store both in the secret store:
//
//	cd mta && go run ./cmd/deliverykey
package main

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"

	"golang.org/x/crypto/nacl/box"
)

func main() {
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		fmt.Fprintln(os.Stderr, "deliverykey:", err)
		os.Exit(1)
	}
	fmt.Println("# Go SMTP sender (keep secret):")
	fmt.Printf("SMTP_DELIVERY_PRIVATE_KEY=%s\n", base64.StdEncoding.EncodeToString(priv[:]))
	fmt.Println("# Rails API:")
	fmt.Printf("INBOX2_MTA_DELIVERY_PUBLIC_KEY=%s\n", base64.StdEncoding.EncodeToString(pub[:]))
}
