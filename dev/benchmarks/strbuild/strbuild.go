package main

import (
	"fmt"
	"strings"
)

func main() {
	n := 200000
	var b strings.Builder
	for i := 0; i < n; i++ {
		b.WriteString("ab")
	}
	s := b.String()
	sum := 0
	for j := 0; j < len(s); j++ {
		sum += int(s[j])
	}
	fmt.Println(len(s), sum)
}
