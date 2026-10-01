package main

import "fmt"

func main() {
	const N = 10000000
	flags := make([]byte, N+1)
	count := 0
	for i := 2; i <= N; i++ {
		if flags[i] == 0 {
			count++
			for j := i * i; j <= N; j += i {
				flags[j] = 1
			}
		}
	}
	fmt.Println(count)
}
