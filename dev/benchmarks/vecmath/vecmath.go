package main

import "fmt"

func dist(x, y float64) float64 { return x*x + y*y }

func main() {
	const n = 3000000
	c := 0
	for i := 0; i < n; i++ {
		a := float64(i) * 0.5
		b := a + 1.5
		if dist(a, b) > 1000000.0 {
			c++
		}
	}
	fmt.Println(c)
}
