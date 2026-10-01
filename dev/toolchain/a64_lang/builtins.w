s = "hello world"
out(copy(s, 0, 5))
out(copy(s, 6))
out(copy(s))
out(copy(s, 0, 0))
out(len(copy(s, 11)))
out(find(s, "world"))
out(find(s, "o"))
out(find(s, "zzz"))
out(find(s, ""))
out(number("1234"))
out(number("-99"))
out(number("0"))
out(number(""))
out(number("12x"))
out(number("99999999999999999999999"))
out(number(7))
out(number("e5"))
out(number("-E5"))
out(number("e+5"))
out(number(".e5"))
out(number(".5"))
out(number("-.5e1"))
out(kind(7) == "number")
out(kind("7") == "number")
xs = text(7)
xs[0] = 5
xs[1] = 3
xs[2] = 9
xs[3] = 1
xs[4] = 7
xs[5] = 3
xs[6] = 0 - 4
out(sort(xs))
out(xs)
out(sort(text(0)))
out(sort("dcba"))
// sort keeps what it was given: an array comes back an array, which out() and
// `.` render as JSON, and text or bytes come back text. arm64 used to return
// every sorted array as text, which only an array subject could show.
arr = array(4)
arr[0] = 3
arr[1] = 1
arr[2] = 2
arr[3] = 0 - 5
out(sort(arr))
out("sorted: " . sort(arr))
out(kind(sort(arr)) . " " . kind(sort("ba")) . " " . kind(sort(bytes("0201"))))
out(arr)
one = array(1)
one[0] = "only"
out(sort(one))
out(kind(sort(array(0))))
b = bytes(5)
b[0] = 104
b[1] = 105
b[2] = 33
b[3] = 33
b[4] = 33
out(b)
out(copy(b, 0, 2))
out(len(copy(b, 1, 4)))
out(find(b, "i"))
ys = text(3)
ys[0] = 65
ys[1] = 66
ys[2] = 67
out(sort(ys))
out(copy(ys))
