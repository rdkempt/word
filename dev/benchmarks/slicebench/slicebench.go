package main

import "fmt"

func main() {
	n, w := 200000, 32
	s := make([]int64, n)
	for i := 0; i < n; i++ {
		s[i] = (int64(i) * 48271) % 251
	}
	var sum int64
	for r := 0; r < 8; r++ {
		for j := 0; j < n-w; j++ {
			t := make([]int64, w)
			copy(t, s[j:j+w])
			sum += t[0] + t[w-1]
		}
	}
	fmt.Println(sum)
}
