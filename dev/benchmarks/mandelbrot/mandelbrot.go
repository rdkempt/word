package main

import "fmt"

func main() {
	const w, h, maxit = 200, 200, 500
	total := 0
	for py := 0; py < h; py++ {
		for px := 0; px < w; px++ {
			x0 := float64(px)*3.5/w - 2.5
			y0 := float64(py)*2.0/h - 1.0
			x, y := 0.0, 0.0
			it := 0
			for ; it < maxit; it++ {
				xx, yy := x*x, y*y
				if xx+yy > 4.0 {
					break
				}
				y = 2.0*x*y + y0
				x = xx - yy + x0
			}
			if it == maxit {
				total++
			}
		}
	}
	fmt.Println(total)
}
