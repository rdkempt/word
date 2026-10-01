package main

import (
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
)

func main() {
	c := &http.Client{Transport: &http.Transport{
		DisableKeepAlives: true,
		TLSClientConfig:   &tls.Config{InsecureSkipVerify: true},
	}}
	total := 0
	for i := 0; i < 20; i++ {
		r, err := c.Get("https://127.0.0.1:4492/p")
		if err != nil {
			panic(err)
		}
		b, _ := io.ReadAll(r.Body)
		r.Body.Close()
		total += len(b)
	}
	fmt.Println(total)
}
