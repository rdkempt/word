package main

import (
	"fmt"
	"strconv"
)

func main() {
	const n = 500000
	m := make(map[string]int)
	for i := 0; i < n; i++ {
		m["k"+strconv.Itoa(i)] = i
	}
	sum := 0
	for j := 0; j < n; j++ {
		sum += m["k"+strconv.Itoa(j)]
	}
	fmt.Println(len(m), sum)
}
