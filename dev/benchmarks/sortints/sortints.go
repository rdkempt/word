package main

import (
	"fmt"
	"sort"
)

func main() {
	n := 50000
	a := make([]int64, n)
	var x int64 = 12345
	for i := 0; i < n; i++ {
		x = (x * 48271) % 2147483647
		a[i] = x
	}
	sort.Slice(a, func(i, j int) bool { return a[i] < a[j] })
	var sum int64 = 0
	for _, v := range a {
		sum += v
	}
	fmt.Println(a[0], a[n/2], a[n-1], sum)
}
