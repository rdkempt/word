package main

import (
	"fmt"
	"io"
	"net/http"
)

func main() {
	c := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}}
	total := 0
	for i := 0; i < 200; i++ {
		r, err := c.Get("http://127.0.0.1:4491/p")
		if err != nil {
			panic(err)
		}
		b, _ := io.ReadAll(r.Body)
		r.Body.Close()
		total += len(b)
	}
	fmt.Println(total)
}
