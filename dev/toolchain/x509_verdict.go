// x509_verdict.go: the question dev/toolchain/x509_verdict.w answers, put to
// Go's crypto/x509 instead.
//
// A dev and CI oracle only: Go is never needed to build or run word. Agreeing
// with openssl is one implementation's opinion, and openssl is the one a
// hand-written verifier is most likely to have been modelled on. Go's PKIX
// code shares no history with it, so a case all three agree on is one that
// three independent readings of RFC 5280 agree on, and a case where they don't
// is worth writing down, which dev/toolchain/test_x509_profile.sh does.
//
//	x509_verdict <host> <anchor.der> <leaf.der> [intermediate.der ...]
//
// Prints ACCEPTED or REJECTED, and the reason on stderr. Anything that isn't a
// clean acceptance is REJECTED, including a leaf or intermediate that doesn't
// parse (an anchor that doesn't parse exits 2). The word driver also answers
// REJECTED for a leaf that doesn't parse, so the comparison has two outcomes,
// not three. It leaves out an intermediate that doesn't parse, where this
// rejects.
package main

import (
	"crypto/x509"
	"fmt"
	"os"
)

func load(path string) (*x509.Certificate, error) {
	der, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return x509.ParseCertificate(der)
}

func reject(err error) {
	fmt.Fprintln(os.Stderr, err)
	fmt.Println("REJECTED")
	os.Exit(0)
}

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: x509_verdict <host> <anchor.der> <leaf.der> [intermediate.der ...]")
		os.Exit(2)
	}
	host := os.Args[1]

	anchor, err := load(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, "anchor:", err)
		os.Exit(2)
	}
	roots := x509.NewCertPool()
	roots.AddCert(anchor)

	leaf, err := load(os.Args[3])
	if err != nil {
		reject(err)
	}
	inter := x509.NewCertPool()
	for _, p := range os.Args[4:] {
		c, err := load(p)
		if err != nil {
			reject(err)
		}
		inter.AddCert(c)
	}

	// DNSName does the name check, KeyUsages the purpose check. Go applies the
	// purpose down the whole chain, not to the leaf alone, and so do word and
	// openssl -purpose sslserver.
	if _, err := leaf.Verify(x509.VerifyOptions{
		DNSName:       host,
		Roots:         roots,
		Intermediates: inter,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}); err != nil {
		reject(err)
	}
	fmt.Println("ACCEPTED")
}
